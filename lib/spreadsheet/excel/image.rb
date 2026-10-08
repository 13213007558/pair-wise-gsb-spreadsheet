module Spreadsheet
  module Excel
    class Image
      attr_reader :worksheet, :shape_id, :anchor, :data, :path, :content_type,
        :status, :error

      def initialize worksheet:, shape_id:, anchor:, data: nil, content_type: nil,
        path: nil, status: :embedded, error: nil
        @worksheet = worksheet
        @shape_id = shape_id
        @anchor = anchor
        @data = data
        @path = path
        @content_type = content_type
        @status = status
        @error = error
      end

      def embedded?
        status == :embedded
      end

      def external?
        status == :external
      end

      def unknown_type?
        status == :unknown_type
      end

      def unsupported_vector?
        status == :unsupported_vector
      end

      def out_of_range?
        status == :out_of_range
      end

      alias_method :object_identifier, :shape_id

      def truncated?
        status == :truncated
      end

      class Anchor
        attr_reader :from_row, :from_column, :from_row_offset, :from_column_offset,
          :to_row, :to_column, :to_row_offset, :to_column_offset

        def initialize values
          @from_row, @from_column, @from_row_offset, @from_column_offset,
            @to_row, @to_column, @to_row_offset, @to_column_offset = values
        end

        def to_a
          [
            @from_row, @from_column, @from_row_offset, @from_column_offset,
            @to_row, @to_column, @to_row_offset, @to_column_offset
          ]
        end
      end
    end
  end
end
