require "spreadsheet/excel/error"

module Spreadsheet
  class Formula
    ##
    # Abstract Syntax Tree nodes for BIFF8 formulas.
    #
    # The AST is built by Spreadsheet::Formula::Parser from the RPN token
    # array stored in FORMULA, SHAREDFMLA, ARRAY or NAME records. It is used
    # for auditing only: no evaluation is performed.
    #
    # Every node responds to:
    # * #to_s       -- the formula text (without a leading '='). Parentheses
    #                  are added where needed to preserve operator precedence.
    # * #references -- the flattened list of Spreadsheet::Formula::Reference
    #                  dependencies of the subtree.
    # * #token_class -- the class of the ptg the node was parsed from
    #                  (:reference, :value or :array), nil for classless
    #                  tokens such as operators and constants.
    module AST
      ## Operator precedence levels (higher binds tighter), following Excel's
      ## rules, so that #to_s can add parentheses where they are required.
      PRECEDENCE = {
        comparison: 1,
        concat: 2,
        additive: 3,
        multiplicative: 4,
        power: 5,
        percent: 6,
        unary: 7,
        union: 8,
        intersection: 9,
        range: 10,
        atom: 100
      }.freeze

      ##
      # A dependency of a formula: a cell or area on this or another sheet, a
      # defined name, or an external (other-workbook) name. External
      # references keep the identity of their SUPBOOK (the +supbook+ index
      # into Workbook#supbooks); the external file itself is never opened.
      Reference = Struct.new(:type, :sheet, :sheet_last, :supbook,
        :name, :name_index,
        :first_row, :first_column, :last_row, :last_column,
        keyword_init: true)

      ## Base class for all nodes.
      class Node
        attr_accessor :token_class

        def precedence
          PRECEDENCE[:atom]
        end

        def references
          []
        end

        private

        ## Render +node+, adding parentheses if its binding is weaker than
        ## +prec+ (or equal when +equal+ is true, for the right-hand side of
        ## left-associative operators).
        def parenthesize node, prec, equal = false
          text = node.to_s
          if node.precedence < prec || (equal && node.precedence == prec)
            "(#{text})"
          else
            text
          end
        end
      end

      ## Numeric constant (ptgInt, ptgNum).
      class NumberLiteral < Node
        attr_reader :value

        def initialize value
          @value = value
        end

        def to_s
          if @value.is_a?(Integer) || (@value == @value.to_i && @value.abs < 1e15)
            @value.to_i.to_s
          else
            @value.to_s
          end
        end
      end

      ## String constant (ptgStr).
      class StringLiteral < Node
        attr_reader :value

        def initialize value
          @value = value
        end

        def to_s
          %("#{value.gsub('"', '""')}")
        end
      end

      ## Boolean constant (ptgBool).
      class BoolLiteral < Node
        attr_reader :value

        def initialize value
          @value = value
        end

        def to_s
          @value ? "TRUE" : "FALSE"
        end
      end

      ## Error constant (ptgErr, ptgRefErr, ptgAreaErr, ...).
      class ErrorLiteral < Node
        attr_reader :code

        def initialize code
          @code = code
        end

        def error
          Spreadsheet::Excel::Error.new @code
        end

        def to_s
          error.value
        end
      end

      ## A missing function argument (ptgMissArg), renders as empty text.
      class MissingArgument < Node
        def to_s
          ""
        end
      end

      ## Unary plus or minus (ptgUplus, ptgUminus).
      class UnaryOperator < Node
        SIGNS = {plus: "+", minus: "-"}.freeze
        attr_reader :operator, :operand

        def initialize operator, operand
          @operator = operator
          @operand = operand
        end

        def precedence
          PRECEDENCE[:unary]
        end

        def references
          @operand.references
        end

        def to_s
          "#{SIGNS[@operator]}#{parenthesize(@operand, precedence)}"
        end
      end

      ## Postfix percent operator (ptgPercent).
      class PercentOperator < Node
        attr_reader :operand

        def initialize operand
          @operand = operand
        end

        def precedence
          PRECEDENCE[:percent]
        end

        def references
          @operand.references
        end

        def to_s
          "#{parenthesize(@operand, precedence)}%"
        end
      end

      ## Binary operator, including the reference operators : (range),
      ## <space> (intersection) and , (union).
      class BinaryOperator < Node
        OPERATORS = {
          add: ["+", :additive],
          sub: ["-", :additive],
          mul: ["*", :multiplicative],
          div: ["/", :multiplicative],
          power: ["^", :power],
          concat: ["&", :concat],
          eq: ["=", :comparison],
          ne: ["<>", :comparison],
          lt: ["<", :comparison],
          le: ["<=", :comparison],
          gt: [">", :comparison],
          ge: [">=", :comparison],
          range: [":", :range],
          union: [",", :union],
          intersection: [" ", :intersection]
        }.freeze
        attr_reader :operator, :left, :right

        def initialize operator, left, right
          @operator = operator
          @left = left
          @right = right
        end

        def precedence
          PRECEDENCE[OPERATORS.fetch(@operator)[1]]
        end

        def references
          @left.references + @right.references
        end

        def to_s
          sign = OPERATORS.fetch(@operator)[0]
          "#{parenthesize(@left, precedence)}#{sign}#{parenthesize(@right, precedence, true)}"
        end
      end

      ## Explicit parentheses recorded by Excel (ptgParen).
      class Parenthesized < Node
        attr_reader :operand

        def initialize operand
          @operand = operand
        end

        def references
          @operand.references
        end

        def to_s
          "(#{@operand})"
        end
      end

      ## A function call (ptgFunc, ptgFuncVar, ptgAttr/Sum).
      class FunctionCall < Node
        attr_reader :name, :arguments, :function_index

        def initialize name, arguments, function_index = nil
          @name = name
          @arguments = arguments
          @function_index = function_index
        end

        def references
          @arguments.flat_map(&:references)
        end

        def to_s
          args = @arguments.map { |arg|
            ## a union or intersection passed as a single argument needs
            ## parentheses to not be mistaken for multiple arguments
            if arg.precedence <= PRECEDENCE[:intersection]
              "(#{arg})"
            else
              arg.to_s
            end
          }
          "#{display_name}(#{args.join(",")})"
        end

        private

        def display_name
          @name || "FUNC#{@function_index}"
        end
      end

      ## The sheet part of a 3-D reference. Internal references know their
      ## sheet name(s); external references keep the +supbook+ index (into
      ## Workbook#supbooks) and whatever sheet names the SUPBOOK record
      ## provided -- the external file itself is never opened.
      class SheetReference
        attr_reader :first, :last, :supbook

        def initialize first: nil, last: nil, supbook: nil
          @first = first
          @last = last
          @supbook = supbook
        end

        def external?
          !@supbook.nil?
        end

        def == other
          other.is_a?(SheetReference) &&
            first == other.first && last == other.last && supbook == other.supbook
        end
        alias_method :eql?, :==

        def hash
          [@first, @last, @supbook].hash
        end

        def to_s
          book = external? ? "[#{@supbook}]" : ""
          if @last && @last != @first
            "#{book}#{quote(@first)}:#{quote(@last)}"
          else
            "#{book}#{quote(@first)}"
          end
        end

        private

        def quote name
          return "#REF!" if name.nil?
          if /\A[A-Za-z_\\][A-Za-z0-9_.]*\z/.match?(name)
            name
          else
            "'#{name.gsub("'", "''")}'"
          end
        end
      end

      ## Shared behaviour of cell and area references.
      module ReferenceFormatting
        private

        def column_name column
          name = +""
          col = column
          loop do
            name.prepend((65 + col % 26).chr)
            col = col / 26 - 1
            break if col < 0
          end
          name
        end

        def cell_name row, column, row_relative, column_relative
          "#{column_relative ? "" : "$"}#{column_name(column)}" +            "#{row_relative ? "" : "$"}#{row + 1}"
        end

        def sheet_prefix
          @sheet ? "#{@sheet}!" : ""
        end
      end

      ## A single cell reference (ptgRef, ptgRefN, ptgRef3d).
      class CellReference < Node
        include ReferenceFormatting
        attr_reader :row, :column, :sheet

        def initialize row, column, row_relative: false, column_relative: false, sheet: nil
          @row = row
          @column = column
          @row_relative = row_relative
          @column_relative = column_relative
          @sheet = sheet
        end

        def row_relative?
          @row_relative
        end

        def column_relative?
          @column_relative
        end

        def references
          [Reference.new(type: :cell,
            sheet: @sheet&.first, sheet_last: @sheet&.last,
            supbook: @sheet&.supbook,
            first_row: @row, first_column: @column,
            last_row: @row, last_column: @column)]
        end

        def to_s
          "#{sheet_prefix}#{cell_name(@row, @column, @row_relative, @column_relative)}"
        end
      end

      ## A rectangular area reference (ptgArea, ptgAreaN, ptgArea3d).
      class AreaReference < Node
        include ReferenceFormatting
        attr_reader :first_row, :first_column, :last_row, :last_column, :sheet

        def initialize first_row, first_column, last_row, last_column,
          row_relative: false, column_relative: false, sheet: nil
          @first_row = first_row
          @first_column = first_column
          @last_row = last_row
          @last_column = last_column
          @row_relative = row_relative
          @column_relative = column_relative
          @sheet = sheet
        end

        def row_relative?
          @row_relative
        end

        def column_relative?
          @column_relative
        end

        def references
          [Reference.new(type: :area,
            sheet: @sheet&.first, sheet_last: @sheet&.last,
            supbook: @sheet&.supbook,
            first_row: @first_row, first_column: @first_column,
            last_row: @last_row, last_column: @last_column)]
        end

        def to_s
          first = cell_name(@first_row, @first_column, @row_relative, @column_relative)
          last = cell_name(@last_row, @last_column, @row_relative, @column_relative)
          "#{sheet_prefix}#{first}:#{last}"
        end
      end

      ## A defined name (ptgName). Keeps the 1-based +index+ into the
      ## workbook's NAME records; +name+ is nil if the workbook's NAME
      ## records were not read.
      class NameReference < Node
        attr_reader :index, :name

        def initialize index, name = nil
          @index = index
          @name = name
        end

        def references
          [Reference.new(type: :name, name: @name, name_index: @index)]
        end

        def to_s
          @name || "NAME#{@index}"
        end
      end

      ## An external (other-workbook) name (ptgNameX). Keeps the +supbook+
      ## index and the 1-based +index+ into the EXTERNNAME table; the
      ## external file itself is never opened.
      class ExternalNameReference < Node
        attr_reader :supbook, :index, :name

        def initialize supbook, index, name = nil
          @supbook = supbook
          @index = index
          @name = name
        end

        def references
          [Reference.new(type: :external_name, supbook: @supbook,
            name: @name, name_index: @index)]
        end

        def to_s
          "[#{@supbook}]#{@name || "NAME#{@index}"}"
        end
      end

      ## An array constant (ptgArray). +values+ are filled from the data
      ## appended after the token array when available, and are nil
      ## otherwise.
      class ArrayConstant < Node
        attr_accessor :values
        attr_reader :rows, :columns

        def initialize rows = nil, columns = nil, values = nil
          @rows = rows
          @columns = columns
          @values = values
        end

        def to_s
          if @values
            rows = @values.map { |row| row.map(&:to_s).join(",") }
            "{#{rows.join(";")}}"
          else
            "{...}"
          end
        end
      end

      ## Placeholder of an array or shared formula (ptgExp): points at the
      ## upper-left cell of the range that carries the actual token array.
      class FormulaAnchor < Node
        attr_reader :row, :column

        def initialize row, column
          @row = row
          @column = column
        end

        def to_s
          "EXP(#{@row},#{@column})"
        end
      end

      ## A token the parser does not know (or a known token whose data was
      ## truncated). Records the +offset+ within the token array, the token
      ## +id+ and the +raw+ bytes that could be attributed to it. Parsing
      ## stops at an unknown token: subsequent bytes are never reported as
      ## successfully parsed.
      class UnknownToken < Node
        attr_reader :offset, :id, :raw

        def initialize offset, id, raw
          @offset = offset
          @id = id
          @raw = raw
        end

        def to_s
          "<unknown ptg 0x#{@id.to_s(16)} @#{@offset}>"
        end
      end
    end
  end
end
