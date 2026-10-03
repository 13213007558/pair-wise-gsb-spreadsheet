require "test/unit"
require "spreadsheet"

module Spreadsheet
  module Excel
    class SstTest < Test::Unit::TestCase
      def test_cross_continue_rich_text_extended_data_and_non_bmp_boundary
        workbook = Spreadsheet::Excel::Workbook.new
        parser = SstParser.new(workbook)
        first_record = [1, 1].pack("V2")
        first_record << [8215, 0x0c, 3].pack("vCv")
        first_record << "A" * 8210
        parser.start first_record

        parser.continue [1].pack("C") + "\x3d\xd8".b
        parser.continue "\x00\xde".b
        runs = [[8209, 4], [8210, 5], [8212, 6]].collect do |start, font|
          [start, font].pack("v2")
        end.join
        ext = [8].pack("V") + "EXT-DATA"
        parser.continue [0].pack("C") + "BBB"
        parser.continue runs.byteslice(0, 5)
        parser.continue runs.byteslice(5, 7)
        parser.continue ext.byteslice(0, 3)
        parser.continue ext.byteslice(3, 5)
        parser.continue ext.byteslice(8..-1).to_s

        entry = workbook.sst.first
        value = entry.content
        assert_instance_of RichText, value
        assert_equal(("A" * 8210) + "😀BBB", value)
        assert_equal [8209, 8210, 8212], value.runs.map(&:start)
        assert_equal [3, 4, 5], value.runs.map(&:font_index)
        assert_equal [8209, 8210, 8211], value.char_runs.map(&:start)
        assert_equal ext, value.ext_data
      end

      def test_rich_text_editing_adjusts_code_unit_and_character_positions
        value = RichText.new("ab😀cd", runs: [
          RichText::Run.new(0, 0, nil),
          RichText::Run.new(1, 1, nil),
          RichText::Run.new(3, 2, nil)
        ])
        value.replace_text(2, 1, "X")
        assert_equal "abXcd", value
        assert_equal [0, 1, 3], value.runs.map(&:start)

        value.replace_text(2, 1, "")
        assert_equal "abcd", value
        assert_equal [0, 1, 2], value.runs.map(&:start)
      end

      def test_writes_and_reads_rich_text_across_continue_boundaries
        book = Spreadsheet::Workbook.new
        sheet = book.create_worksheet
        regular = book.default_format.font
        bold = Font.new("Arial", weight: :bold)
        book.add_font bold
        text = ("A" * 8210) + "😀BBB"
        ext = [8].pack("V") + "EXT-DATA"
        value = RichText.new(text,
          runs: [
            RichText::Run.new(8209, 0, regular),
            RichText::Run.new(8210, 1, bold),
            RichText::Run.new(8212, 0, regular)
          ],
          ext_data: ext)
        other = RichText.new("same",
          runs: [RichText::Run.new(0, 1, bold)],
          ext_data: ext)
        plain = RichText.new("same", ext_data: ext)
        sheet.row(0).concat [value, other, plain]

        io = StringIO.new("".dup)
        book.write io
        io.rewind
        read_book = Spreadsheet.open io
        read_value = read_book.worksheet(0).row(0)[0]
        assert_instance_of RichText, read_value
        assert_equal text, read_value
        assert_equal [8209, 8210, 8212], read_value.runs.map(&:start)
        assert_equal [400, 700, 400],
          read_value.runs.map { |run| run.font.weight }
        assert_equal ext, read_value.ext_data
        assert_equal 3, read_book.sst.size
      end
    end
  end
end
