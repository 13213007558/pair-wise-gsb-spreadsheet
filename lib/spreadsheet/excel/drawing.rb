module Spreadsheet
  module Excel
    class Reader
      module Drawing
        BSE = 0xF007
        SHAPE_CONTAINER = 0xF004
        SHAPE = 0xF00A
        OPTIONS = 0xF00B
        CLIENT_ANCHOR = 0xF010
        BLIP_PIB = 0x0104
        PIB_FLAGS = 0x3FFF
        BLIP_TYPES = {
          0xF01A => :emf,
          0xF01B => :wmf,
          0xF01C => :pict,
          0xF01D => :jpeg,
          0xF01E => :png,
          0xF01F => :dib,
          0xF029 => :tiff,
          0xF02A => :jpeg
        }.freeze
        EMBEDDED_IMAGE_TYPES = {
          jpeg: "image/jpeg",
          png: "image/png"
        }.freeze
        BSE_HEADER_SIZE = 36
        BITMAP_BLIP_HEADER_SIZE = 17
        LINKED_BLIP_HEADER_SIZE = 21
        LINKED_METAFILE_HEADER_SIZE = 36

        def read_drawing_group work
          @picture_store ||= []
          parse_office_art(work) do |record, _current_path|
            next unless record[:type] == BSE && record[:payload].bytesize >= BSE_HEADER_SIZE

            @picture_store << read_bse(record[:payload])
          end
        end

        def start_office_art_continuation context, work
          @office_art_continuation = {context: context, data: work.dup}
        end

        def append_office_art_continuation work
          state = @office_art_continuation
          state[:data] << work if state
        end

        def office_art_payload? work
          work.bytesize >= 8 && (work.unpack1("v") & 0x000F) == 0x0F
        end

        def finish_office_art_continuation worksheet = nil
          state = @office_art_continuation
          return unless state

          kind, target = state[:context]
          if kind == :drawinggroup
            read_drawing_group state[:data]
          else
            read_drawing(target || worksheet, state[:data])
          end
          @office_art_continuation = nil
        end

        def finish_office_art_record previous_op, op, worksheet = nil
          return previous_op if op == :continue
          return op if @office_art_continuation && peek_next_opcode == :continue

          finish_office_art_continuation worksheet
          op
        end

        def peek_next_opcode
          saved_pos = @pos
          tuple = get_next_chunk
          @pos = saved_pos
          tuple ? tuple[1] : nil
        end

        def read_drawing worksheet, work
          @worksheet_pictures ||= {}
          @worksheet_pictures[worksheet] ||= []
          shapes = []
          parse_office_art(work) do |record, _current_path|
            if record[:type] == SHAPE_CONTAINER && picture_shape?(record[:payload])
              shape = {shape_id: nil, pib: nil, anchor: nil}
              shape_records = child_atoms(record[:payload], SHAPE)
              shape_record = shape_records.find { |child| child[:version] == 2 } ||
                shape_records.first
              options = child_atoms(record[:payload], OPTIONS).first
              shape[:pib] = read_picture_index(options[:payload]) if options
              anchor = child_atoms(record[:payload], CLIENT_ANCHOR).first
              if anchor
                values = anchor[:payload].unpack("v9")
                shape[:anchor] = Image::Anchor.new(values[1..]) if values.size >= 9
              end
              shape[:shape_id] = shape_record[:payload].unpack1("V") if shape_record
              shapes << shape if shape[:pib] && shape[:anchor]
            end
          end
          shapes.each do |shape|
            image = image_for_shape(worksheet, shape)
            @worksheet_pictures[worksheet] << image
            worksheet.instance_variable_get(:@images) << image
          end
        end

        private

        def read_bse payload
          bt_win, bt_mac = payload.unpack("C2")
          bt = BLIP_TYPES.key?(bt_win & 0x7F) ? bt_win & 0x7F : bt_mac & 0x7F
          result = {type: BLIP_TYPES[bt] || :unknown, record_type: bt}
          parse_office_art(payload[BSE_HEADER_SIZE..]) do |record, _current_path|
            next unless blip_record?(record)

            read_blip(result, record)
          end
          result
        end

        def read_blip result, record
          blip_type = BLIP_TYPES.fetch(record[:type], :unknown)
          result[:type] = blip_type
          payload = record[:payload]
          result[:record_type] = record[:type]
          if record[:version] == 2
            result[:status] = :external
            result[:path] = read_linked_blip_path(payload, blip_type)
          elsif (blip_type == :jpeg || blip_type == :png) &&
            payload.bytesize < BITMAP_BLIP_HEADER_SIZE
            result[:status] = :truncated
            result[:data] = nil
          elsif blip_type == :jpeg || blip_type == :png
            result[:data] = payload[BITMAP_BLIP_HEADER_SIZE..]
          end
        end

        def read_picture_index payload
          count = payload[0, 2].unpack1("v") >> 4
          count.times do |index|
            opid, value = payload[index * 6, 6].unpack("vV")
            return value if (opid & PIB_FLAGS) == BLIP_PIB
          end
          nil
        end

        def read_linked_blip_path payload, type
          if type == :jpeg || type == :png
            path_size = payload.bytesize >= LINKED_BLIP_HEADER_SIZE ?
              payload[17, 4].unpack1("V") : nil
            path_size = nil unless path_size &&
              LINKED_BLIP_HEADER_SIZE + path_size <= payload.bytesize &&
              (path_size % 2).zero?
            path_size ||= [payload.bytesize - LINKED_BLIP_HEADER_SIZE, 0].max
            return decode_utf16le(payload[LINKED_BLIP_HEADER_SIZE, path_size].to_s)
          end
          decode_utf16le(payload[[payload.bytesize, LINKED_METAFILE_HEADER_SIZE].min..])
        end

        def decode_utf16le string
          while string.end_with? "\x00\x00".b
            string = string[0...-2]
          end
          string.force_encoding("UTF-16LE")
          string.encode("UTF-8", invalid: :replace, undef: :replace)
        end

        def image_for_shape worksheet, shape
          index = shape[:pib].to_i
          entry = @picture_store&.[](index - 1)
          common = {
            worksheet: worksheet,
            shape_id: shape.fetch(:shape_id),
            anchor: shape[:anchor]
          }
          unless shape[:pib]
            return Image.new(**common, status: :missing_reference,
              error: "shape does not contain a BLIP reference")
          end
          unless entry
            return Image.new(**common, status: :out_of_range,
              error: "BLIP reference #{shape[:pib]} is outside the drawing group picture store")
          end

          type = entry[:type]
          content_type = EMBEDDED_IMAGE_TYPES[type]
          if entry[:status] == :external
            Image.new(**common, status: :external, path: entry[:path],
              error: "linked image: #{entry[:path]}")
          elsif content_type && entry[:data]
            Image.new(**common, data: entry[:data], content_type: content_type)
          elsif type == :unknown
            Image.new(**common, status: :unknown_type,
              error: format("unknown BLIP type 0x%04x", entry[:record_type]))
          elsif entry[:status] == :truncated
            Image.new(**common, status: :truncated,
              error: "truncated #{type} BLIP record")
          else
            Image.new(**common, status: :unsupported_vector,
              content_type: nil, error: "#{type} images are not extracted")
          end
        end

        def blip_record? record
          BLIP_TYPES.key?(record[:type]) ||
            record[:type].between?(0xF020, 0xF028) ||
            record[:type].between?(0xF02B, 0xF02F)
        end

        def picture_shape? data
          child_atoms(data, OPTIONS).any? { |record| read_picture_index(record[:payload]) }
        end

        def child_atoms data, type
          records = []
          offset = 0
          while offset + 8 <= data.bytesize
            version_instance, record_type, size = data[offset, 8].unpack("v2V")
            payload = data[offset + 8, size].to_s
            is_container = (version_instance & 0x000F) == 0x0F
            if record_type == type && !is_container
              records << {
                type: record_type,
                version: version_instance & 0x000F,
                instance: version_instance >> 4,
                size: size,
                payload: payload
              }
            end
            offset += is_container ? 8 : 8 + size
          end
          records
        end

        def parse_office_art data, path = [], &block
          return enum_for(:parse_office_art, data, path) unless block_given?

          offset = 0
          while offset + 8 <= data.bytesize
            version_instance, type, size = data[offset, 8].unpack("v2V")
            payload = data[offset + 8, size].to_s
            record = {
              type: type,
              version: version_instance & 0x000F,
              instance: version_instance >> 4,
              size: size,
              payload: payload
            }
            current_path = path + [record]
            yield record, current_path
            if record[:version] == 0x0F
              parse_office_art(payload, current_path, &block)
            end
            offset += 8 + size
          end
        end

      end
    end
  end
end
