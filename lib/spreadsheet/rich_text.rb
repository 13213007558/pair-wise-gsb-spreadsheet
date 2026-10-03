module Spreadsheet
  ##
  # A shared string with font formatting runs.
  #
  # Run positions are UTF-16 code unit offsets, as required by the BIFF8 SST
  # record. Use #char_run / #char_runs for Ruby character offsets.
  class RichText < String
    Run = Struct.new(:start, :font_index, :font) do
      def key
        font ? font.key : font_index
      end

      def eql? other
        other.is_a?(self.class) && start == other.start && key == other.key
      end
      alias_method :==, :eql?

      def hash
        [start, key].hash
      end
    end

    attr_accessor :ext_data, :phonetic_data
    attr_reader :runs

    def initialize string = "", runs: [], ext_data: "", phonetic_data: ""
      super(string.to_s)
      @runs = normalize_runs(runs)
      @ext_data = ext_data || ""
      @phonetic_data = phonetic_data || ""
    end

    def add_run start, font = nil, font_index = nil
      index = start.to_i
      run = Run.new(index, font_index, font)
      @runs.delete_if { |item| item.start == index }
      @runs.push run
      normalize!
      self
    end

    def add_char_run start, font = nil, font_index = nil
      add_run utf16_offset(start), font, font_index
    end

    def char_run start
      run_at(utf16_offset(start))
    end

    def char_runs
      @runs.collect do |run|
        Run.new(utf16_char_offset(run.start), run.font_index, run.font)
      end
    end

    def run_at position
      selected = nil
      @runs.each do |run|
        break if run.start > position
        selected = run
      end
      selected
    end

    def runs= runs
      @runs = normalize_runs(runs)
    end

    ##
    # Replace Ruby-character range start...length with replacement.
    #
    # Runs beginning before the edited range keep their position. The run
    # active at the replacement start formats inserted text. Runs inside the
    # deleted range are removed unless their formatting continues after the
    # range; the first continuing suffix run is moved to the replacement end.
    def replace_text start, length, replacement = ""
      character_text = to_s
      start_char = normalize_char_offset(start)
      character_count = character_text.chars.to_a.length
      length = [length.to_i, character_count - start_char].min
      finish_char = start_char + length
      start_unit = utf16_offset(start_char)
      finish_unit = utf16_offset(finish_char)
      replacement_text = replacement.to_s
      replacement_units = replacement_text.encode("UTF-16LE").bytesize / 2
      characters = character_text.chars.to_a
      prefix = characters[0...start_char].join
      tail = finish_char >= characters.length ? "" : characters[finish_char..-1].join
      replacement = self.class.new(prefix + replacement_text + tail)
      replacement.phonetic_data = phonetic_data
      replacement.ext_data = ext_data
      replacement.runs = adjusted_runs(start_char, finish_char, start_unit,
        finish_unit, replacement_units)
      replace(replacement)
      @runs = replacement.runs
      @ext_data = replacement.ext_data
      @phonetic_data = replacement.phonetic_data
      self
    end

    def eql? other
      other.is_a?(RichText) && super && @runs == other.runs &&
        ext_data == other.ext_data && phonetic_data == other.phonetic_data
    end

    def hash
      [super, @runs, ext_data, phonetic_data].hash
    end

    def rich?
      !@runs.empty?
    end

    private

    def adjusted_runs start_char, finish_char, start_unit, finish_unit,
      replacement_units
      deleted = finish_char > start_char
      adjusted = []
      @runs.each do |run|
        next unless run.start < start_unit
        adjusted.push Run.new(run.start, run.font_index, run.font)
      end
      if deleted
        suffix_index = @runs.find_index { |run| run.start > start_unit }
        if replacement_units > 0
          active = @runs.find { |run| run.start == start_unit }
          if active
            adjusted.push Run.new(start_unit, active.font_index, active.font)
          end
        end
        if suffix_index
          suffix = @runs[suffix_index]
          suffix_start = replacement_units > 0 ? start_unit + replacement_units : start_unit
          adjusted.push Run.new(suffix_start,
            suffix.font_index, suffix.font)
        end
      else
        if start_unit > 0
          active = run_at(start_unit)
          if active && active.start < start_unit
            adjusted.push Run.new(start_unit, active.font_index, active.font)
          end
        end
        @runs.each do |run|
          next unless run.start >= start_unit
          adjusted.push Run.new(run.start + replacement_units,
            run.font_index, run.font)
        end
      end
      adjusted.reject { |run| run.start < 0 }
      result = []
      adjusted.each do |run|
        while result.any? && result.last.start >= run.start
          result.pop
        end
        result.push run
      end
      result
    end

    def normalize! 
      @runs = normalize_runs(@runs)
    end

    def normalize_char_offset offset
      if offset.is_a? Integer
        [[offset, 0].max, to_s.chars.to_a.length].min
      else
        chars.index(offset.to_s) || 0
      end
    end

    def normalize_runs runs
      result = runs.collect do |run|
        run.is_a?(Run) ? run : Run.new(run[0], run[1], run[2])
      end
      result.sort_by!(&:start)
      result.reject! { |run| run.start < 0 }
      result.reject!.with_index do |_run, index|
        index + 1 < result.size && result[index + 1].start == result[index].start
      end
      result
    end

    def utf16_char_offset unit
      prefix = encode("UTF-16LE").byteslice(0, unit * 2).to_s
      prefix.force_encoding("UTF-16LE").encode("UTF-8").chars.length
    end

    def utf16_offset offset
      chars.to_a[0...offset.to_i].join.encode("UTF-16LE").bytesize / 2
    end
  end
end
