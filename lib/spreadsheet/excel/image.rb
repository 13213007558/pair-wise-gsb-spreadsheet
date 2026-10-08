module Spreadsheet
  module Excel
    # Embedded or referenced picture found in an Excel worksheet.
    class Image
      STATUSES = [:embedded, :external, :unknown, :out_of_bounds].freeze
      FORMATS = {
        2 => :emf,
        3 => :wmf,
        4 => :pict,
        5 => :jpeg,
        6 => :png,
        7 => :dib,
        11 => :tiff,
        12 => :jpeg,
        13 => :emf,
        14 => :png,
        15 => :tiff
      }.freeze
      EXTERNAL_BIT = 0x80

      attr_accessor :worksheet, :object_identifier, :data,
        :from_row, :from_column, :from_x, :from_y,
        :to_row, :to_column, :to_x, :to_y
      attr_reader :blip_identifier, :status, :content_type, :error
      alias blip_id blip_identifier

      def initialize attributes = {}
        attributes.each do |key, value|
          public_send("#{key}=", value) if respond_to?("#{key}=", true)
        end
      end

      def blip_id=(value)
        @blip_identifier = value
        @blip_type = value && (value & ~EXTERNAL_BIT)
        @content_type = FORMATS[@blip_type]
      end

      def anchor
        {
          from: [from_row, from_column, from_x, from_y],
          to: [to_row, to_column, to_x, to_y]
        }
      end

      def external?
        status == :external
      end

      def embedded?
        status == :embedded
      end

      def mark status, error = nil
        @status = status if STATUSES.include?(status)
        @error = error
        self
      end

      def out_of_bounds?
        status == :out_of_bounds
      end

      def unknown?
        status == :unknown
      end

      def worksheet_name
        worksheet.is_a?(Spreadsheet::Worksheet) ? worksheet.name : worksheet
      end
    end
  end
end
