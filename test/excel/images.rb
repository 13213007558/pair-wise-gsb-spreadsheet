#!/usr/bin/env ruby

$LOAD_PATH << File.expand_path("../../lib", __dir__)

require "test/unit"
require "spreadsheet"

module Spreadsheet
  module Excel
    class TestImages < Test::Unit::TestCase
      def setup
        @path = File.expand_path("../data/test_embedded_images.xls", __dir__)
        @png = File.binread(File.expand_path("../data/images/shared.png", __dir__))
        @jpeg = File.binread(File.expand_path("../data/images/other.jpg", __dir__))
        @book = Spreadsheet.open(@path)
      end

      def test_reads_pictures_from_both_worksheets
        assert_equal %w[First Second], @book.worksheets.map(&:name)
        assert_equal 3, @book.images.size
        assert_equal 2, @book.worksheets[0].images.size
        assert_equal 1, @book.worksheets[1].images.size
      end

      def test_returns_original_png_and_jpeg_bytes
        first_png, jpeg, second_png = @book.images

        assert_equal :embedded, first_png.status
        assert_equal :png, first_png.content_type
        assert_equal @png, first_png.data

        assert_equal :embedded, jpeg.status
        assert_equal :jpeg, jpeg.content_type
        assert_equal @jpeg, jpeg.data

        assert_equal :embedded, second_png.status
        assert_equal @png, second_png.data
        assert_equal first_png.object_identifier, second_png.object_identifier
      end

      def test_keeps_separate_shape_positions_for_shared_picture
        first_png, _jpeg, second_png = @book.images

        assert_equal 1, first_png.object_identifier
        assert_equal 1, second_png.object_identifier
        assert_equal({
          from_row: 1, from_column: 20, from_x: 2, from_y: 9,
          to_row: 1, to_column: 130, to_x: 2, to_y: 72
        }, anchor_attributes(first_png))
        assert_equal({
          from_row: 4, from_column: 91, from_x: 5, from_y: 13,
          to_row: 4, to_column: 201, to_x: 5, to_y: 75
        }, anchor_attributes(second_png))
      end

      def test_keeps_jpeg_anchor_with_from_and_to_offsets
        jpeg = @book.worksheets[0].images[1]

        assert_equal 2, jpeg.object_identifier
        assert_equal({
          from_row: 3, from_column: 23, from_x: 8, from_y: 33,
          to_row: 3, to_column: 101, to_x: 8, to_y: 147
        }, anchor_attributes(jpeg))
      end

      def test_reassembles_officeart_records_from_continue
        path = File.expand_path("../data/test_embedded_images_continue.xls", __dir__)
        book = Spreadsheet.open(path)
        assert_equal [@png, @jpeg, @png], book.images.map(&:data)
        assert_equal [[1, 20, 2, 9], [3, 23, 8, 33], [4, 91, 5, 13]],
          book.images.map { |image| image.anchor[:from] }
        assert_equal [[1, 130, 2, 72], [3, 101, 8, 147], [4, 201, 5, 75]],
          book.images.map { |image| image.anchor[:to] }
      end

      def test_external_unknown_and_out_of_bounds_references
        reader = Reader.new
        external_image = Image.new
        unknown_image = Image.new
        missing_image = Image.new

        reader.send(:resolve_image_blip, external_image, 1,
          [OfficeArt::BlipEntry.new(0x85, nil, true)])
        reader.send(:resolve_image_blip, unknown_image, 1,
          [OfficeArt::BlipEntry.new(2, nil, false)])
        reader.send(:resolve_image_blip, missing_image, 99,
          [])

        assert external_image.external?
        assert_equal 0x85, external_image.blip_identifier
        assert_nil external_image.data

        assert unknown_image.unknown?
        assert_equal :emf, unknown_image.content_type
        assert_nil unknown_image.data

        assert missing_image.out_of_bounds?
        assert_equal 99, missing_image.blip_identifier
        assert_equal "BLIP #99 is not present", missing_image.error
      end

      private

      def anchor_attributes image
        %i[from_row from_column from_x from_y to_row to_column to_x to_y].each_with_object({}) do |key, attrs|
          attrs[key] = image.public_send(key)
        end
      end

      def escher_record type, body, instance = 0
        [instance, type, body.bytesize].pack("vvV") + body
      end

      def escher_group bse_type, blip_type, blip_body
        blip = escher_record(blip_type, blip_body, 0)
        bse_body = ("\0" * 36).b + blip
        bse = escher_record(0xf007, bse_body, bse_type)
        bstore = escher_record(0xf001, bse, 0x1f)
        escher_record(0xf000, bstore, 0x0f)
      end
    end
  end
end
