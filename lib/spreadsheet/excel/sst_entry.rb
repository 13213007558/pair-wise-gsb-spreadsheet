require "spreadsheet/rich_text"

module Spreadsheet
  module Excel
    ##
    # Shared String Table Entry
    class SstEntry
      attr_accessor :chars, :flags, :wide, :wide_continuation_without_flag,
        :richtext, :phonetic,
        :raw_runs, :phonetic_data, :ext_data, :content, :suffix_size
      attr_writer :extended

      def initialize opts = {}
        @chars = opts[:chars]
        @flags = opts[:flags]
        @wide = opts[:wide]
        @richtext = opts[:richtext] || 0
        @phonetic = opts[:phonetic] || 0
        @raw_runs = ""
        @phonetic_data = ""
        @ext_data = ""
        @content = opts[:content]
        @suffix_size = 0
        @extended = false
      end

      def extended?
        @extended || (@flags && (@flags & 0x04) == 0x04)
      end
    end
  end
end
