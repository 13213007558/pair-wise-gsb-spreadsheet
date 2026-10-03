require "spreadsheet/encodings"
require "spreadsheet/rich_text"

module Spreadsheet
  module Excel
    ##
    # Shared String Table Entry
    #
    # The raw data of an SST entry may be scattered over several SST/CONTINUE
    # records: the character data may be split (and each continuation may
    # switch between compressed and uncompressed representation), and the
    # Rich-Text formatting runs and the Asian phonetic extension data may be
    # split as well. To reflect this, an entry collects a list of typed
    # chunks ([type, offset, length, wide]) into the Workbook stream and
    # assembles its content, formatting runs and extended data lazily from
    # those chunks.
    class SstEntry
      include Spreadsheet::Encodings

      attr_accessor :chars, :phonetic, :richtext, :flags, :wide,
        :runs_count, :ext_size

      def initialize opts = {}
        @content = nil
        @rich_text = nil
        @runs = nil
        @ext_data = nil
        @offset = opts[:offset]
        @ole = opts[:ole]
        @reader = opts[:reader]
        @workbook = opts[:workbook]
        @runs_count = 0
        @ext_size = 0
        @chunks = []
      end

      ##
      # Register a chunk of this entry's data.
      # _type_ is one of :chars, :runs or :ext. _wide_ only matters for
      # :chars chunks and tells whether the chunk stores uncompressed
      # (16-bit) characters.
      def add_chunk type, offset, length, wide = 0
        @chunks.push [type, offset, length, wide]
      end

      ##
      # Access the contents of this Shared String
      def content
        @content || assemble_content
      end

      ##
      # Does this entry carry Rich-Text formatting runs or Asian phonetic
      # extension data?
      def rich?
        @richtext.to_i > 0 || @phonetic.to_i > 0
      end

      ##
      # The Rich-Text formatting runs of this entry as an Array of
      # [position, font_index] pairs, where position is a UTF-16 code unit
      # offset and font_index the raw Biff font index.
      def run_data
        @run_data ||= begin
          data = assemble :runs
          data.unpack("v*").each_slice(2).to_a
        end
      end

      ##
      # The raw bytes of the Asian phonetic settings block (ExtRst), or nil
      # if this entry does not contain extended data. The data is not
      # interpreted and preserved verbatim.
      def ext_data
        if @phonetic.to_i > 0
          @ext_data ||= assemble(:ext)
        end
      end

      ##
      # The formatting runs of this entry as an Array of RichText::Run
      # structs with resolved Spreadsheet::Font objects (where possible).
      def runs
        @runs ||= run_data.map do |position, font_index|
          RichText::Run.new position, resolve_font(font_index)
        end
      end

      ##
      # This Shared String as an editable Spreadsheet::RichText.
      def rich_text
        @rich_text || assemble_rich_text
      end

      private

      def assemble_content
        data = "".dup
        @chunks.each do |type, offset, length, wide|
          next unless type == :chars
          chunk = @ole[offset, length]
          chunk = widen(chunk) if wide == 0
          data << chunk
        end
        content = client data, "UTF-16LE"
        @content = content if @reader.memoize?
        content
      end

      def assemble_rich_text
        rich = RichText.new content
        rich.runs = runs
        rich.ext_data = ext_data
        @rich_text = rich if @reader.memoize?
        rich
      end

      def assemble type
        data = "".dup
        @chunks.each do |chunk_type, offset, length, _|
          data << @ole[offset, length] if chunk_type == type
        end
        data
      end

      ##
      # Insert null-characters into a compressed UTF-16 string
      def widen data
        data.unpack("C*").pack("v*")
      end

      def resolve_font font_index
        return font_index unless @workbook
        ## this appears to be undocumented: the first 4 fonts seem to be
        ## accessed with a 0-based index, but all subsequent font indices
        ## are 1-based. (see also Reader#read_xf)
        idx = (font_index > 3) ? font_index - 1 : font_index
        @workbook.font(idx) || font_index
      end
    end
  end
end
