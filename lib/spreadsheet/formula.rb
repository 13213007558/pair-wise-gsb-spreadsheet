require "spreadsheet/formula/ast"
require "spreadsheet/formula/parser"

module Spreadsheet
  ##
  # Formula implementation. You may access the last calculated #value, other
  # attributes are needed for writing the Formula back into modified Excel
  # Files.
  #
  # For BIFF8 workbooks the RPN token array of the formula can be inspected
  # through #ast (an abstract syntax tree, see Spreadsheet::Formula::Ast),
  # #dependencies (the cells, ranges and defined names the formula refers
  # to) and #to_s (the formula as text). This is a read-only view: no
  # calculation is performed.
  class Formula
    attr_accessor :data, :value, :shared

    ##
    # Internal: parsing context assigned by the Excel reader. A Hash with
    # the keys :tokens (the RPN token array), :row, :column and :worksheet.
    attr_accessor :parse_context

    ##
    # The formula as an abstract syntax tree (a Spreadsheet::Formula::Ast
    # node), or nil if no BIFF8 token data is available. Shared formulas are
    # expanded in the context of the cell owning this Formula, so relative
    # references resolve to the correct cells.
    def ast
      unless defined? @ast
        @ast = @parse_context && Formula.parse_cell(@parse_context)
      end
      @ast
    end

    ##
    # The cells, ranges and defined names this formula depends on, as an
    # Array of Spreadsheet::Formula::Ast::Dependency. Empty if the formula
    # could not be parsed.
    def dependencies
      node = ast
      node ? node.dependencies.uniq : []
    end

    ##
    # The formula as text, e.g. "=SUM(Sheet2!A1:B2)*2". Parentheses are
    # inserted as needed to preserve operator precedence. Returns an empty
    # String if the formula could not be parsed.
    def to_s
      node = ast
      node ? "=#{node}" : ""
    end

    ##
    # Internal: parse the BIFF8 token array of a formula cell. See
    # Spreadsheet::Formula::Parser for the available context options.
    def self.parse_cell context
      worksheet = context[:worksheet]
      workbook = worksheet && worksheet.workbook
      opts = {}
      if workbook
        opts[:sheets] = workbook.worksheets.collect(&:name)
        opts[:names] = workbook.defined_names.collect { |entry| entry[:name] }
        opts[:externsheets] = workbook.externsheets
        opts[:supbooks] = workbook.supbooks
      end
      if worksheet
        opts[:shared] = worksheet.shared_formulas
        opts[:shared_resolver] = lambda { |row, column|
          ## make sure the row block containing the anchor has been read
          worksheet.row row
          worksheet.shared_formulas[[row, column]]
        }
      end
      Parser.new(opts).parse context[:tokens],
        row: context[:row], column: context[:column]
    end
  end
end
