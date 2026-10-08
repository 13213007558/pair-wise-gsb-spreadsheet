module Spreadsheet
  module Excel
    # Minimal Microsoft OfficeArt (Escher) reader for worksheet pictures.
    class OfficeArt
      CONTAINER_VERSION = 0x0f
      RECORD_DGG_CONTAINER = 0xf000
      RECORD_BSTORE_CONTAINER = 0xf001
      RECORD_BSE = 0xf007
      RECORD_SP_CONTAINER = 0xf004
      RECORD_SP = 0xf009
      RECORD_OPT = 0xf00b
      RECORD_CLIENT_ANCHOR = 0xf010
      PROPERTY_BLIP = 0x01bf
      PROPERTY_BLIP_COMPAT = 0x0104
      OBJECT_PICTURE = 0x08

      BlipEntry = Struct.new(:type, :data, :external) do
        def external?
          external
        end
      end

      def blips data
        each_record(data) do |type, body, _version|
          next unless type == RECORD_DGG_CONTAINER
          return parse_blip_store(body)
        end
        []
      end

      def pictures data
        shapes = []
        picture_containers(data).each do |body|
          shape = parse_picture_shape(body)
          shapes << shape if shape
        end
        shapes
      end

      def client_anchor body
        return nil unless body && body.size >= 18
        _flags, row_from, col_from, x_from, y_from,
          row_to, col_to, x_to, y_to = body.unpack("v9")
        {
          from_row: row_from,
          from_column: col_from,
          from_x: x_from,
          from_y: y_from,
          to_row: row_to,
          to_column: col_to,
          to_x: x_to,
          to_y: y_to
        }
      end

      private

      def picture_containers data
        result = []
        collect_picture_containers(data, 0, result)
        result
      end

      def collect_picture_containers data, depth, result
        return if depth > 12
        each_record(data) do |type, body, version|
          next unless container?(version)
          picture = direct_picture?(body)
          result << body if type == RECORD_SP_CONTAINER && picture && (depth.zero? || depth >= 2)
          collect_picture_containers(body, depth + 1, result)
        end
      end

      def direct_picture? data
        each_record(data) { |type, _body, version| return true if type == 0xf00a && version == 0x04b2 }
        false
      end

      def container? version
        (version & 0x000f) == CONTAINER_VERSION
      end

      def each_record data
        offset = 0
        while data && offset + 8 <= data.size
          version, type, size = data[offset, 8].unpack("v2V")
          body = data[offset + 8, size]
          break unless body
          yield type, body, version, offset
          offset += 8 + size
        end
      end

      def extract_blip_data bse_type, blip_record_type, body
        return [:external, nil] if bse_type & Image::EXTERNAL_BIT != 0 || (0xf020..0xf029).include?(blip_record_type)

        case blip_record_type
        when 0xf01e, 0xf025
          signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].pack("C8")
          index = body.index(signature)
          index ? [:embedded, body[index..]] : [:unknown, nil]
        when 0xf01d, 0xf024
          index = body.index([0xff, 0xd8, 0xff].pack("C3"))
          if index
            finish = body.rindex([0xff, 0xd9].pack("C2"))
            [:embedded, body[index..(finish ? finish + 1 : -1)]]
          else
            [:unknown, nil]
          end
        else
          [:unknown, nil]
        end
      end

      def parse_blip_store group_body
        entries = []
        each_record(group_body) do |type, body, version|
          next unless type == RECORD_BSTORE_CONTAINER && container?(version)
          each_record(body) do |child_type, child_body, _child_version|
            next unless child_type == RECORD_BSE
            entries << parse_bse(child_body)
          end
        end
        entries
      end

      def parse_bse body
        blip_type = body.getbyte(0)
        external = (blip_type & Image::EXTERNAL_BIT) != 0
        nested_type, nested_body = first_blip_record(body[36..] || "")
        status, data = if nested_body
          extract_blip_data(blip_type, nested_type, nested_body)
        else
          [:unknown, nil]
        end
        BlipEntry.new(blip_type, data, external || status == :external)
      end

      def first_blip_record data
        each_record(data) do |type, body, _version|
          return [type, body] if (0xf018..0xf029).include?(type)
        end
        nil
      end

      def parse_picture_shape body
        options = nil
        anchor = nil
        picture_shape = false
        walk(body) do |type, record_body, version|
          picture_shape = true if type == 0xf00a
          options = [version, record_body] if type == RECORD_OPT
          anchor = client_anchor(record_body) if type == RECORD_CLIENT_ANCHOR && record_body.size >= 18
        end
        blip = options && property_blip(options[1])
        return nil unless picture_shape && (blip || anchor)
        {blip_index: blip && blip[:index],
          blip_fallback_index: blip && blip[:fallback_index],
          anchor: anchor}
      end

      def property_blip body
        offset = 0
        result = nil
        while offset + 6 <= body.size
          raw_opid, value = body[offset, 6].unpack("vV")
          opid = raw_opid & 0x3fff
          complex = raw_opid & 0x8000 != 0
          low, high = body[offset + 2, 4].unpack("v2") unless complex
          if opid == PROPERTY_BLIP
            result ||= {}
            result[:index] = low.zero? && high.positive? ? high : low
          elsif opid == PROPERTY_BLIP_COMPAT
            result ||= {}
            result[:fallback_index] = value
          end
          break if complex
          offset += 6
        end
        result
      end

      def walk data, depth = 0
        return if depth > 12
        each_record(data) do |type, body, version|
          yield type, body, version
          walk(body, depth + 1) { |*args| yield(*args) } if container?(version)
        end
      end
    end
  end
end
