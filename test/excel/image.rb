#!/usr/bin/env ruby

$LOAD_PATH.unshift File.expand_path("../../lib", File.dirname(__FILE__))

require "test/unit"
require "spreadsheet"
require "digest"

module Spreadsheet
  module Excel
    class TestImage < Test::Unit::TestCase
      DATA = File.expand_path File.join("..", "data"), File.dirname(__FILE__)
      XLS = File.join DATA, "test_image_drawing.xls"
      PNG = File.join DATA, "test_image_drawing.png"
      JPEG = File.join DATA, "test_image_drawing.jpg"

      def test_reads_shared_png_and_jpeg_from_two_worksheets
        book = Spreadsheet.open XLS
        images = book.images

        assert_equal 3, images.size
        assert_equal ["Pictures", "Pictures", "More"], images.map { |image|
          image.worksheet.name
        }
        assert_equal [1025, 1026, 2049], images.map(&:shape_id)
        assert_equal [1025, 1026, 2049], images.map(&:object_identifier)
        assert_equal ["image/png", "image/png", "image/jpeg"],
          images.map(&:content_type)
        assert(images.all?(&:embedded?))
      end

      def test_returns_exact_original_image_bytes
        book = Spreadsheet.open XLS
        images = book.images

        assert_equal Digest::SHA256.file(PNG).digest,
          Digest::SHA256.digest(images[0].data)
        assert_equal Digest::SHA256.file(PNG).digest,
          Digest::SHA256.digest(images[1].data)
        assert_equal Digest::SHA256.file(JPEG).digest,
          Digest::SHA256.digest(images[2].data)
      end

      def test_preserves_shape_anchors_and_offsets
        book = Spreadsheet.open XLS
        first, second, third = book.images

        assert_equal [4, 39, 5, 11, 4, 1023, 5, 255], first.anchor.to_a
        assert_equal [1, 20, 2, 9, 1, 83, 2, 46], second.anchor.to_a
        assert_equal [0, 0, 1, 0, 1, 1023, 2, 255], third.anchor.to_a
      end

      def test_images_can_be_read_per_worksheet
        book = Spreadsheet.open XLS

        assert_equal 2, book.worksheet(0).images.size
        assert_equal 1, book.worksheet(1).images.size
        assert_same book.images.last, book.worksheet(1).images.first
      end

      def test_reads_officeart_container_split_across_continue
        book = Spreadsheet.open File.join(DATA, "test_image_drawing_continue.xls")
        images = book.images

        assert_equal 3, images.size
        assert_equal Digest::SHA256.file(PNG).digest,
          Digest::SHA256.digest(images[0].data)
        assert_equal Digest::SHA256.file(JPEG).digest,
          Digest::SHA256.digest(images.last.data)
      end

      def test_external_bitmap_blip_returns_linked_path
        reader = drawing_reader
        bse = bse_record(0x0005, linked_bitmap_blip("C:/pictures/photo.jpg"))
        image = image_for_bse(reader, bse)

        assert_predicate image, :external?
        assert_equal "C:/pictures/photo.jpg", image.path
        assert_nil image.data
        assert_match(/linked image/, image.error)
      end

      def test_unknown_blip_type_is_reported
        reader = drawing_reader
        blip = escher_record(0x000F020, "unknown payload")
        image = image_for_bse(reader, bse_record(0x0020, blip))

        assert_predicate image, :unknown_type?
        assert_match(/unknown BLIP type 0xf020/, image.error)
      end

      def test_vector_blip_type_is_not_extracted
        reader = drawing_reader
        blip = escher_record(0x000F01B, "\x00" * 80)
        image = image_for_bse(reader, bse_record(0x0002, blip))

        assert_predicate image, :unsupported_vector?
        assert_equal :wmf, reader.instance_variable_get(:@picture_store).first[:type]
      end

      def test_external_vector_blip_is_reported_as_linked
        reader = drawing_reader
        path = "C:/pictures/drawing.wmf".encode("UTF-16LE").b
        blip = escher_record(0x002F01B, "\x00" * 36 + path)
        image = image_for_bse(reader, bse_record(0x0002, blip))

        assert_predicate image, :external?
        assert_equal "C:/pictures/drawing.wmf", image.path
      end

      def test_out_of_range_shape_reference_is_reported
        worksheet = Spreadsheet::Worksheet.new(name: "Sheet")
        reader = drawing_reader
        shape = {
          shape_id: 7,
          pib: 99,
          anchor: Spreadsheet::Excel::Image::Anchor.new([1, 2, 3, 4, 5, 6, 7, 8])
        }
        image = reader.send(:image_for_shape, worksheet, shape)

        assert_predicate image, :out_of_range?
        assert(worksheet.equal?(image.worksheet))
        assert_equal 7, image.shape_id
        assert_equal [1, 2, 3, 4, 5, 6, 7, 8], image.anchor.to_a
      end

      private

      def drawing_reader
        Spreadsheet::Excel::Reader.new
      end

      def image_for_bse reader, bse
        worksheet = Spreadsheet::Worksheet.new(name: "Sheet")
        reader.instance_variable_set(:@picture_store, [reader.send(:read_bse, bse)])
        shape = {
          shape_id: 7,
          pib: 1,
          anchor: Spreadsheet::Excel::Image::Anchor.new([1, 2, 3, 4, 5, 6, 7, 8])
        }
        reader.send(:image_for_shape, worksheet, shape)
      end

      def bse_record type, blip
        header = [type, type, 0].pack("CCv") + "\x00" * 32
        header + blip
      end

      def linked_bitmap_blip path
        utf16 = path.encode("UTF-16LE").b
        marker = "\x6e".b
        payload = ("\x00".b * 16) + marker + [utf16.bytesize].pack("V") + utf16
        escher_record(0x1D2F01D, payload)
      end

      def escher_record type, payload
        payload = payload.b
        version_instance = type >> 16
        record_type = type & 0xFFFF
        [version_instance, record_type, payload.bytesize].pack("v2V") + payload
      end
    end
  end
end
