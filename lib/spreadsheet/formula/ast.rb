require "spreadsheet/excel/error"

module Spreadsheet
  class Formula
    ##
    # Abstract Syntax Tree nodes for BIFF8 formulas, produced by
    # Spreadsheet::Formula::Parser. Nodes know how to render themselves back
    # to formula text (with parentheses preserving operator precedence) and
    # how to enumerate the cell, range and name references they depend on.
    module Ast
      PRECEDENCE_COMPARISON = 10
      PRECEDENCE_CONCAT = 20
      PRECEDENCE_ADDITIVE = 30
      PRECEDENCE_MULTIPLICATIVE = 40
      PRECEDENCE_POWER = 50
      PRECEDENCE_PERCENT = 60
      PRECEDENCE_UNARY = 70
      PRECEDENCE_REFERENCE = 80
      PRECEDENCE_ATOM = 90

      ##
      # A single dependency of a formula: a cell or range on one or more
      # sheets, an external reference, or a defined name. Two Dependencies
      # are equal if all their attributes are equal.
      class Dependency
        attr_reader :sheets, :external, :name, :name_index,
          :first_row, :last_row, :first_column, :last_column

        def initialize sheets: [], external: nil, name: nil, name_index: nil,
          first_row: nil, last_row: nil, first_column: nil, last_column: nil
          @sheets = sheets.freeze
          @external = external
          @name = name
          @name_index = name_index
          @first_row = first_row
          @last_row = last_row
          @first_column = first_column
          @last_column = last_column
        end

        def == other
          other.is_a?(Dependency) &&
            sheets == other.sheets &&
            external == other.external &&
            name == other.name &&
            name_index == other.name_index &&
            first_row == other.first_row &&
            last_row == other.last_row &&
            first_column == other.first_column &&
            last_column == other.last_column
        end
        alias_method :eql?, :==

        def hash
          [sheets, external, name, name_index,
            first_row, last_row, first_column, last_column].hash
        end

        def to_s
          if name || name_index
            label = name || "NAME##{name_index}"
            external ? "[#{external[:supbook]}]!#{label}" : label
          else
            first = "#{Ast.column_name(first_column)}#{first_row + 1}"
            last = "#{Ast.column_name(last_column)}#{last_row + 1}"
            body = (first == last) ? first : "#{first}:#{last}"
            "#{Ast.sheet_prefix(sheets, external)}#{body}"
          end
        end

        def inspect
          "#<#{self.class.name} #{self}>"
        end
      end

      ##
      # Base class for all AST nodes. +ptg_class+ records the token class of
      # the token that produced the node (:reference, :value or :array) and
      # is nil for operators and other classless tokens.
      class Node
        attr_reader :ptg_class

        def initialize ptg_class: nil
          @ptg_class = ptg_class
        end

        def dependencies
          []
        end

        def precedence
          PRECEDENCE_ATOM
        end
      end

      ##
      # A literal constant: number, string, boolean or error value.
      class Constant < Node
        attr_reader :value

        def initialize value, ptg_class: nil
          super(ptg_class: ptg_class)
          @value = value
        end

        def to_s
          case @value
          when Spreadsheet::Excel::Error then @value.value
          when String then @value.gsub('"', '""').inspect
          when true then "TRUE"
          when false then "FALSE"
          when Float
            if @value.finite? && @value == @value.truncate && @value.abs < 1e15
              @value.truncate.to_s
            else
              @value.to_s
            end
          else
            @value.to_s
          end
        end
      end

      ##
      # A missing argument in a function call (ptgMissArg).
      class MissingArg < Node
        def to_s
          ""
        end
      end

      ##
      # An inline array constant (ptgArray). The constant values are stored
      # after the token array and are not decoded; +data+ holds the raw
      # reserved bytes of the token.
      class InlineArray < Node
        attr_reader :data

        def initialize data, ptg_class: nil
          super(ptg_class: ptg_class)
          @data = data
        end

        def to_s
          "{...}"
        end
      end

      ##
      # A single cell reference, optionally on one or more other sheets
      # (3D reference) or in an external workbook.
      class Ref < Node
        attr_reader :row, :column, :sheets, :external

        def initialize row:, column:, row_relative: false, column_relative: false,
          sheets: [], external: nil, ptg_class: nil
          super(ptg_class: ptg_class)
          @row = row
          @column = column
          @row_relative = row_relative
          @column_relative = column_relative
          @sheets = sheets
          @external = external
        end

        def row_relative?
          @row_relative
        end

        def column_relative?
          @column_relative
        end

        def dependencies
          [Dependency.new(sheets: @sheets, external: @external,
            first_row: @row, last_row: @row,
            first_column: @column, last_column: @column)]
        end

        def to_s
          col = @column_relative ? Ast.column_name(@column) : "$#{Ast.column_name(@column)}"
          row = @row_relative ? (@row + 1).to_s : "$#{@row + 1}"
          "#{Ast.sheet_prefix(@sheets, @external)}#{col}#{row}"
        end
      end

      ##
      # A rectangular range of cells, optionally 3D or external.
      class Area < Node
        attr_reader :first_row, :last_row, :first_column, :last_column,
          :sheets, :external

        def initialize first_row:, last_row:, first_column:, last_column:,
          first_row_relative: false, last_row_relative: false,
          first_column_relative: false, last_column_relative: false,
          sheets: [], external: nil, ptg_class: nil
          super(ptg_class: ptg_class)
          @first_row = first_row
          @last_row = last_row
          @first_column = first_column
          @last_column = last_column
          @first_row_relative = first_row_relative
          @last_row_relative = last_row_relative
          @first_column_relative = first_column_relative
          @last_column_relative = last_column_relative
          @sheets = sheets
          @external = external
        end

        def dependencies
          [Dependency.new(sheets: @sheets, external: @external,
            first_row: @first_row, last_row: @last_row,
            first_column: @first_column, last_column: @last_column)]
        end

        def to_s
          first = corner(@first_row, @first_column,
            @first_row_relative, @first_column_relative)
          last = corner(@last_row, @last_column,
            @last_row_relative, @last_column_relative)
          body = (first == last) ? first : "#{first}:#{last}"
          "#{Ast.sheet_prefix(@sheets, @external)}#{body}"
        end

        private

        def corner row, column, row_relative, column_relative
          col = column_relative ? Ast.column_name(column) : "$#{Ast.column_name(column)}"
          rw = row_relative ? (row + 1).to_s : "$#{row + 1}"
          "#{col}#{rw}"
        end
      end

      ##
      # A reference to a defined name (ptgName) or to a name defined in an
      # external workbook (ptgNameX). The identity of the name (its index
      # and, for external names, the EXTERNSHEET index) is always preserved;
      # external workbooks are never resolved.
      class Name < Node
        attr_reader :index, :name, :external

        def initialize index:, name: nil, external: nil, ptg_class: nil
          super(ptg_class: ptg_class)
          @index = index
          @name = name
          @external = external
        end

        def dependencies
          [Dependency.new(name: @name, name_index: @index, external: @external)]
        end

        def to_s
          label = @name || "NAME##{@index}"
          @external ? "[#{@external[:supbook]}]!#{label}" : label
        end
      end

      ##
      # A unary operator: :plus, :minus (prefix) or :percent (postfix).
      class Unary < Node
        attr_reader :operator, :operand

        def initialize operator, operand
          super()
          @operator = operator
          @operand = operand
        end

        def precedence
          (@operator == :percent) ? PRECEDENCE_PERCENT : PRECEDENCE_UNARY
        end

        def dependencies
          @operand.dependencies
        end

        def to_s
          text = @operand.to_s
          text = "(#{text})" if @operand.precedence <= precedence
          case @operator
          when :percent then "#{text}%"
          when :minus then "-#{text}"
          else "+#{text}"
          end
        end
      end

      ##
      # A binary operator: arithmetic, comparison, concatenation and the
      # reference operators :range, :isect and :union.
      class Binary < Node
        OPERATORS = {
          add: "+", sub: "-", mul: "*", div: "/", power: "^", concat: "&",
          lt: "<", le: "<=", eq: "=", ge: ">=", gt: ">", ne: "<>",
          range: ":", isect: " ", union: ","
        }
        PRECEDENCES = {
          range: PRECEDENCE_REFERENCE, isect: PRECEDENCE_REFERENCE,
          union: PRECEDENCE_REFERENCE,
          power: PRECEDENCE_POWER,
          mul: PRECEDENCE_MULTIPLICATIVE, div: PRECEDENCE_MULTIPLICATIVE,
          add: PRECEDENCE_ADDITIVE, sub: PRECEDENCE_ADDITIVE,
          concat: PRECEDENCE_CONCAT,
          lt: PRECEDENCE_COMPARISON, le: PRECEDENCE_COMPARISON,
          eq: PRECEDENCE_COMPARISON, ge: PRECEDENCE_COMPARISON,
          gt: PRECEDENCE_COMPARISON, ne: PRECEDENCE_COMPARISON
        }
        # Operators for which a right operand of equal precedence does not
        # change the meaning when parentheses are dropped.
        ASSOCIATIVE = [:add, :mul, :range, :isect, :union].freeze
        RIGHT_ASSOCIATIVE = [:power].freeze

        attr_reader :operator, :left, :right

        def initialize operator, left, right
          super()
          @operator = operator
          @left = left
          @right = right
        end

        def precedence
          PRECEDENCES.fetch @operator, PRECEDENCE_ATOM
        end

        def dependencies
          @left.dependencies + @right.dependencies
        end

        def to_s
          "#{operand_to_s(@left, true)}#{OPERATORS[@operator]}#{operand_to_s(@right, false)}"
        end

        private

        def operand_to_s node, is_left
          text = node.to_s
          if needs_parentheses? node, is_left
            "(#{text})"
          else
            text
          end
        end

        def needs_parentheses? node, is_left
          return false if node.precedence > precedence
          return true if node.precedence < precedence
          if is_left
            RIGHT_ASSOCIATIVE.include? @operator
          else
            !ASSOCIATIVE.include?(@operator) && !RIGHT_ASSOCIATIVE.include?(@operator)
          end
        end
      end

      ##
      # A function call. +id+ is the BIFF8 function index (nil for calls
      # synthesized from ptgAttrSum), +name+ the canonical function name.
      class Funcall < Node
        attr_reader :id, :name, :arguments

        def initialize name, arguments, id: nil, ptg_class: nil
          super(ptg_class: ptg_class)
          @id = id
          @name = name
          @arguments = arguments
        end

        def dependencies
          @arguments.flat_map(&:dependencies)
        end

        def to_s
          "#{@name}(#{@arguments.map(&:to_s).join(",")})"
        end
      end

      ##
      # A token the parser does not understand. Parsing stops at this point:
      # +offset+ is the byte offset of the token within the token array and
      # +bytes+ contains the raw, unparsed remainder of the token array
      # (starting with the unknown token itself). Subsequent bytes are never
      # mistaken for successfully parsed tokens.
      class Unknown < Node
        attr_reader :ptg, :offset, :bytes

        def initialize ptg:, offset:, bytes:
          super()
          @ptg = ptg
          @offset = offset
          @bytes = bytes
        end

        def to_s
          if @ptg
            format("<unknown token 0x%02x at offset %d>", @ptg, @offset)
          else
            format("<unparseable formula at offset %d>", @offset)
          end
        end
      end

      ##
      # Convert a 0-based column index to Excel column letters (0 -> "A").
      def self.column_name idx
        name = +""
        i = idx.to_i
        loop do
          name.prepend((65 + i % 26).chr)
          i = i / 26 - 1
          break if i < 0
        end
        name
      end

      ##
      # Quote a sheet name for formula text if it contains characters that
      # require quoting.
      def self.quote_sheet name
        if /\A[A-Za-z_][A-Za-z0-9_.]*\z/.match?(name)
          name
        else
          "'#{name.gsub("'", "''")}'"
        end
      end

      ##
      # The "Sheet1!" / "Sheet1:Sheet3!" / "[1]Sheet1!" prefix for 3D and
      # external references.
      def self.sheet_prefix sheets, external
        span =
          if sheets.size > 1
            "#{quote_sheet(sheets.first)}:#{quote_sheet(sheets.last)}!"
          elsif sheets.size == 1
            "#{quote_sheet(sheets.first)}!"
          else
            ""
          end
        external ? "[#{external[:supbook]}]#{span.empty? ? "!" : span}" : span
      end
    end
  end
end
