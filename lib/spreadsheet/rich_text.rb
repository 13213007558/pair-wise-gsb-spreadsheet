module Spreadsheet
  ##
  # A String with Rich-Text formatting runs and (optional) extended data,
  # as stored in the Shared String Table of a Biff8 Workbook.
  #
  # A RichText behaves like a plain String in almost all respects, so code
  # that is not interested in formatting does not need to change. In
  # addition it carries:
  #
  # * #runs     - an Array of Run structs describing font changes within the
  #               text. Run positions are counted in UTF-16 code units,
  #               exactly as they are stored in the file. This differs from
  #               Ruby character indices whenever the text contains
  #               characters outside the Basic Multilingual Plane (which are
  #               stored as surrogate pairs, i.e. two UTF-16 code units).
  #               Use #ruby_position and #utf16_position to convert between
  #               the two, or #runs_by_char to get runs keyed by Ruby
  #               character index.
  # * #ext_data - the raw bytes of the Asian phonetic settings block
  #               (ExtRst). Spreadsheet does not interpret this data; it is
  #               preserved verbatim and written back unchanged.
  #
  # Two RichTexts with equal text but different runs or ext_data are
  # considered different Shared Strings: they are never merged into a
  # single SST entry when a Workbook is written.
  class RichText < String
    ##
    # A single formatting run: starting at +position+ (a UTF-16 code unit
    # offset into the text), the given +font+ applies until the next run
    # starts. +font+ is usually a Spreadsheet::Font; when writing, an
    # Integer is also accepted and used as the raw Biff font index.
    Run = Struct.new :position, :font

    attr_accessor :runs, :ext_data

    ##
    # Coerce a String into a RichText. Returns _string_ unchanged if it
    # already is a RichText. Used to normalize Shared String keys so that
    # deduplication always compares text, runs and extended data.
    def self.coerce string
      string.is_a?(self) ? string : new(string)
    end

    def initialize text = "", runs: [], ext_data: nil
      super text
      @runs = runs
      @ext_data = ext_data
    end

    def initialize_copy other
      super
      @runs = other.runs.dup
      @ext_data = other.ext_data&.dup
    end

    ##
    # Does this String carry Rich-Text information (formatting runs or
    # extended data)?
    def rich?
      !runs.empty? || !ext_data.nil?
    end

    ##
    # The length of the text in UTF-16 code units. Characters outside the
    # Basic Multilingual Plane count as two code units.
    def utf16_length
      each_codepoint.sum { |cp| (cp > 0xffff) ? 2 : 1 }
    end

    ##
    # Convert a Ruby character index into a UTF-16 code unit position.
    def utf16_position ruby_index
      pos = 0
      each_codepoint.with_index do |cp, idx|
        return pos if idx >= ruby_index
        pos += (cp > 0xffff) ? 2 : 1
      end
      pos
    end

    ##
    # Convert a UTF-16 code unit position (as used in Run#position) into a
    # Ruby character index. A position pointing at the second half of a
    # surrogate pair resolves to the index of the whole character.
    def ruby_position utf16_pos
      pos = 0
      each_codepoint.with_index do |cp, idx|
        pos += (cp > 0xffff) ? 2 : 1
        return idx if pos > utf16_pos
      end
      length
    end

    ##
    # The formatting runs keyed by Ruby character index instead of UTF-16
    # code unit position. Returns an Array of [char_index, font] pairs.
    def runs_by_char
      runs.map { |run| [ruby_position(run.position), run.font] }
    end

    ##
    # Replace the text and adjust the formatting runs according to the
    # following rules (all positions in UTF-16 code units):
    #
    # * Runs at or after the start of the common suffix are shifted by the
    #   change in text length (a run exactly at an insertion point moves
    #   along with the text that follows it).
    # * Runs at or before the end of the common prefix of old and new text
    #   keep their position.
    # * Runs inside the replaced region are removed.
    # * Runs that would end up at or beyond the end of the new text are
    #   removed, as are duplicate positions (the first run wins).
    # * If the text had runs and no run remains at position 0, a run is
    #   inserted at position 0 using the font of the first removed run, or
    #   that of the first remaining run if none was removed.
    #
    # Assigning to the String itself (e.g. via #replace or #[]=) does _not_
    # adjust runs; use #replace_text to get the behavior described above.
    def replace_text new_text
      old_units = utf16_length
      new_units = new_text.each_codepoint.sum { |cp| (cp > 0xffff) ? 2 : 1 }
      old_cps = each_codepoint.to_a
      new_cps = new_text.each_codepoint.to_a
      prefix = 0
      idx = 0
      while idx < old_cps.size && idx < new_cps.size &&
          old_cps[idx] == new_cps[idx]
        prefix += (old_cps[idx] > 0xffff) ? 2 : 1
        idx += 1
      end
      suffix = 0
      idx = 0
      while idx < old_cps.size && idx < new_cps.size &&
          old_cps[-1 - idx] == new_cps[-1 - idx]
        width = (old_cps[-1 - idx] > 0xffff) ? 2 : 1
        break if prefix + suffix + width > [old_units, new_units].min
        suffix += width
        idx += 1
      end
      delta = new_units - old_units
      suffix_start = old_units - suffix
      dropped_font = nil
      adjusted = []
      runs.each do |run|
        if run.position >= suffix_start
          pos = run.position + delta
          adjusted << Run.new(pos, run.font) if pos < new_units
        elsif run.position <= prefix
          adjusted << Run.new(run.position, run.font)
        else
          dropped_font ||= run.font
        end
      end
      seen = {}
      adjusted = adjusted.select do |run|
        !seen[run.position] && (seen[run.position] = true)
      end
      if !runs.empty? && adjusted.none? { |run| run.position == 0 }
        font = dropped_font || (adjusted.first && adjusted.first.font)
        adjusted.unshift Run.new(0, font)
      end
      replace new_text
      @runs = adjusted
      self
    end

    ##
    # RichTexts are deduplicated in the Shared String Table by their text,
    # their formatting runs and their extended data: two entries with equal
    # text but different formatting are stored as separate SST entries.
    # Note that == and eql? are asymmetric with plain Strings:
    # "text" == RichText("text") is true, RichText("text") == "text" is
    # only true if the RichText carries no formatting.
    def == other
      if rich? || (other.is_a?(RichText) && other.rich?)
        other.is_a?(RichText) && super &&
          runs_signature == other.runs_signature &&
          ext_data == other.ext_data
      else
        super
      end
    end

    def hash
      rich? ? [to_s, runs_signature, ext_data].hash : super
    end

    def eql? other
      if rich? || (other.is_a?(RichText) && other.rich?)
        other.is_a?(RichText) && self == other &&
          runs_signature == other.runs_signature &&
          ext_data == other.ext_data
      else
        super
      end
    end

    protected

    def runs_signature
      runs.map { |run| [run.position, font_key(run.font)] }
    end

    def font_key font
      font.respond_to?(:key) ? font.key : font
    end
  end
end
