module Spreadsheet
  module Excel
    class SstParser
      include Spreadsheet::Encodings

      attr_reader :entries

      def initialize workbook
        @workbook = workbook
        @entries = []
        reset_state
      end

      def continue data
        parse data.to_s, true
      end

      def start data
        @total, @count = data.unpack("V2")
        parse data[8..-1].to_s, false
      end

      private

      def consume data, pos, bytes
        chunk = data.byteslice(pos, bytes).to_s
        [chunk, pos + bytes]
      end

      def complete_entry
        runs = @runs_count.times.map do |index|
          position, font_record = @raw_runs.byteslice(index * 4, 4).unpack("v2")
          font_index = font_record > 3 ? font_record - 1 : font_record
          RichText::Run.new(position, font_index, @workbook.font(font_index))
        end
        text = client(@text, "UTF-16LE")
        value = if @runs_count.positive? || @ext_data.bytesize.positive?
          RichText.new(text, runs: runs, ext_data: @ext_data)
        else
          text
        end
        entry = SstEntry.new(
          chars: @chars,
          flags: @options,
          wide: @wide,
          richtext: @runs_count,
          content: value
        )
        entry.raw_runs = @raw_runs
        entry.ext_data = @ext_data
        entry.extended = @ext_data.bytesize.positive?
        @entries << entry
        @workbook.add_shared_string entry
      end

      def parse data, record_continuation
        pos = 0
        while pos < data.bytesize
          start_entry if @state.nil?
          case @state
          when :header then
            pos = parse_header(data, pos)
            next
          when :text then
            pos = parse_text(data, pos, record_continuation && pos.zero?)
          when :suffix then
            pos = parse_suffix(data, pos)
          when :ext_data then
            pos = parse_ext_data(data, pos)
          end
          if @state == :done
            complete_entry
            reset_state
          end
        end
        @wide_without_flag = false
      end

      def parse_ext_data data, pos
        bytes = [data.bytesize - pos, @ext_remaining].min
        @ext_data << data.byteslice(pos, bytes).to_s
        @ext_remaining -= bytes
        @state = :done if @ext_remaining.zero?
        pos + bytes
      end

      def parse_header data, pos
        if @header.bytesize < 3
          chunk, pos = consume(data, pos, 3 - @header.bytesize)
          @header << chunk
        end
        return pos if @header.bytesize < 3
        @chars, @options = @header.unpack("vC")
        @wide = (@options & 1) == 1
        @extended = ((@options >> 2) & 1) == 1
        rich = ((@options >> 3) & 1) == 1
        if rich && @header.bytesize < 5
          chunk, pos = consume(data, pos, 5 - @header.bytesize)
          @header << chunk
        end
        return pos if rich && @header.bytesize < 5
        @runs_count = rich ? @header.byteslice(3, 2).unpack1("v") : 0
        @suffix_remaining = @runs_count * 4 + (@extended ? 4 : 0)
        @remaining = @chars
        @text = "".b
        @raw_runs = "".b
        @ext_data = "".b
        @state = @chars.zero? && @suffix_remaining.zero? ? :done : :text
        pos
      end

      def parse_suffix data, pos
        if data.bytesize - pos == 0
          return pos unless @suffix_remaining.zero?
        end
        if @suffix_remaining.positive? && @suffix_remaining == 4 &&
            @extended && data.bytesize - pos >= 4
          declared, = data.byteslice(pos, 4).unpack("V")
          if declared > 8224
            @state = :done
            @suffix_remaining = 0
            @extended = false
            return pos
          end
        end
        bytes = [data.bytesize - pos, @suffix_remaining].min
        @suffix_buffer << data.byteslice(pos, bytes).to_s
        @suffix_remaining -= bytes
        pos += bytes
        return pos unless @suffix_remaining.zero?
        runs_bytes = @runs_count * 4
        @raw_runs = @suffix_buffer.byteslice(0, runs_bytes).to_s
        if @extended
          declared = @suffix_buffer.byteslice(runs_bytes, 4).unpack1("V")
          if declared.zero?
            @ext_data = @suffix_buffer.byteslice(runs_bytes, 4).to_s
            @state = :done
          elsif declared <= 8224
            @ext_data = @suffix_buffer.byteslice(runs_bytes, 4).to_s
            @ext_remaining = declared
            @state = :ext_data
          else
            @extended = false
            @suffix_remaining = 0
            @runs_count = 0
            @state = :done
          end
        else
          @state = :done
        end
        pos
      end

      def parse_text data, pos, record_start
        if record_start && @remaining.positive?
          unless @wide_without_flag
            @wide = (data.getbyte(pos) & 1) == 1
            pos += 1
          end
          @wide_without_flag = false
        end
        unit_size = @wide ? 2 : 1
        units = [(data.bytesize - pos) / unit_size, @remaining].min
        if units.zero?
          if @remaining.zero?
            @suffix_buffer = "".b
            @state = :suffix
            @suffix_remaining = @runs_count * 4 + (@extended ? 4 : 0)
            @state = :done if @suffix_remaining.zero?
          end
          return pos
        else
          part = data.byteslice(pos, units * unit_size).to_s
          part = widen(part) unless @wide
          @text << part
          @remaining -= units
          pos += units * unit_size
          if @remaining.positive? && @wide
            last_unit = part.byteslice(-2, 2).unpack1("v")
            @wide_without_flag = (0xd800..0xdbff).cover?(last_unit)
          end
        end
        return pos unless @remaining.zero?
        @suffix_buffer = "".b
        @state = :suffix
        @suffix_remaining = @runs_count * 4 + (@extended ? 4 : 0)
        @state = :done if @suffix_remaining.zero?
        pos
      end

      def reset_state
        @state = nil
        @wide_without_flag = false
      end

      def start_entry
        @header = "".b
        @state = :header
        @wide_without_flag = false
      end

      def high_surrogate_at_end?
        unit = @text.byteslice(-2, 2).unpack1("v")
        (0xd800..0xdbff).cover?(unit)
      end

      def widen data
        result = "".b
        data.each_byte { |byte| result << byte.chr.b << "\x00".b }
        result
      end
    end
  end
end
