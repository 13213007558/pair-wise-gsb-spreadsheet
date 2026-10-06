#!/usr/bin/env ruby

# TestFormula -- spreadsheet -- BIFF8 formula AST and dependency parsing

$: << File.expand_path("../lib", File.dirname(__FILE__))

require "test/unit"
require "spreadsheet"

module Spreadsheet
  class TestFormulaParser < Test::Unit::TestCase
    Parser = Spreadsheet::Formula::Parser
    Ast = Spreadsheet::Formula::Ast
    Dep = Ast::Dependency

    CONTEXT = {
      sheets: ["Sheet1", "Sheet2", "Sheet3"],
      names: ["MyName"],
      externsheets: [[0, 0, 0], [0, 1, 1], [0, 0, 2], [1, 0, 0]],
      supbooks: [
        {type: :internal},
        {type: :external, url: "file:///tmp/other.xls", sheets: ["ExtSheet"]}
      ]
    }.freeze

    def tokens hex
      [hex.delete(" ")].pack "H*"
    end

    def parse hex, context = CONTEXT, row: 0, column: 0
      Parser.new(context).parse tokens(hex), row: row, column: column
    end

    def test_constants
      assert_equal "5", parse("1e 0500").to_s
      assert_equal "2.5", parse("1f 0000000000000440").to_s
      assert_equal '"abc"', parse("17 0300 616263").to_s
      assert_equal "TRUE", parse("1d 01").to_s
      assert_equal "FALSE", parse("1d 00").to_s
      assert_equal "#N/A!", parse("1c 2a").to_s
      assert_equal "#DIV/0!", parse("1c 07").to_s
      assert_equal 5, parse("1e 0500").value
      assert_equal 2.5, parse("1f 0000000000000440").value
      assert_equal "abc", parse("17 0300 616263").value
      assert_equal true, parse("1d 01").value
      assert_instance_of Spreadsheet::Excel::Error, parse("1c 2a").value
    end

    def test_wide_string_constant
      assert_equal "ab", parse("17 0201 61006200").value
    end

    def test_binary_operators
      assert_equal "1+2", parse("1e 0100 1e 0200 03").to_s
      assert_equal "1-2", parse("1e 0100 1e 0200 04").to_s
      assert_equal "1*2", parse("1e 0100 1e 0200 05").to_s
      assert_equal "1/2", parse("1e 0100 1e 0200 06").to_s
      assert_equal "1^2", parse("1e 0100 1e 0200 07").to_s
      assert_equal "1&2", parse("1e 0100 1e 0200 08").to_s
      assert_equal "1<2", parse("1e 0100 1e 0200 09").to_s
      assert_equal "1<=2", parse("1e 0100 1e 0200 0a").to_s
      assert_equal "1=2", parse("1e 0100 1e 0200 0b").to_s
      assert_equal "1>=2", parse("1e 0100 1e 0200 0c").to_s
      assert_equal "1>2", parse("1e 0100 1e 0200 0d").to_s
      assert_equal "1<>2", parse("1e 0100 1e 0200 0e").to_s
    end

    def test_precedence_parentheses
      # multiplication binds tighter than addition: no parentheses needed
      assert_equal "1+2*3", parse("1e 0100 1e 0200 1e 0300 05 03").to_s
      # addition below multiplication: parentheses must be kept
      assert_equal "(1+2)*3", parse("1e 0100 1e 0200 03 1e 0300 05").to_s
      assert_equal "1*(2+3)", parse("1e 0100 1e 0200 1e 0300 03 05").to_s
      # left associative operators
      assert_equal "10-2-3", parse("1e 0a00 1e 0200 04 1e 0300 04").to_s
      assert_equal "10-(2-3)", parse("1e 0a00 1e 0200 1e 0300 04 04").to_s
      assert_equal "10/(2/3)", parse("1e 0a00 1e 0200 1e 0300 06 06").to_s
      # power is right associative
      assert_equal "2^3^4", parse("1e 0200 1e 0300 1e 0400 07 07").to_s
      assert_equal "(2^3)^4", parse("1e 0200 1e 0300 07 1e 0400 07").to_s
      # concatenation binds tighter than comparison
      assert_equal "1&2=3", parse("1e 0100 1e 0200 08 1e 0300 0b").to_s
      assert_equal "1&(2=3)", parse("1e 0100 1e 0200 1e 0300 0b 08").to_s
    end

    def test_unary_operators
      # unary minus binds tighter than power in Excel
      assert_equal "-A1^2", parse("44 0000 00c0 13 1e 0200 07").to_s
      assert_equal "-(A1+B1)", parse("44 0000 00c0 44 0000 01c0 03 13").to_s
      assert_equal "-(-A1)", parse("44 0000 00c0 13 13").to_s
      assert_equal "+A1", parse("44 0000 00c0 12").to_s
      assert_equal "A1%", parse("44 0000 00c0 14").to_s
      assert_equal "(A1+B1)%", parse("44 0000 00c0 44 0000 01c0 03 14").to_s
    end

    def test_ptg_class_is_preserved
      assert_equal :reference, parse("24 0000 0000").ptg_class
      assert_equal :value, parse("44 0000 0000").ptg_class
      assert_equal :array, parse("64 0000 0000").ptg_class
      assert_equal :value, parse("45 0000 0100 00c0 01c0").ptg_class
      assert_nil parse("1e 0100 1e 0200 03").ptg_class
    end

    def test_cell_references
      assert_equal "$A$1", parse("44 0000 0000").to_s
      assert_equal "A1", parse("44 0000 00c0").to_s
      assert_equal "A$1", parse("44 0000 0040").to_s
      assert_equal "$A1", parse("44 0000 0080").to_s
      assert_equal "$BC$27", parse("44 1a00 3600").to_s
      ref = parse "44 1a00 3600"
      assert_equal 26, ref.row
      assert_equal 54, ref.column
      assert_equal false, ref.row_relative?
      assert_equal false, ref.column_relative?
    end

    def test_area_references
      assert_equal "A1:B2", parse("45 0000 0100 00c0 01c0").to_s
      assert_equal "$A$1:$B$2", parse("45 0000 0100 0000 0100").to_s
      area = parse "45 0000 0100 00c0 01c0"
      assert_equal 0, area.first_row
      assert_equal 1, area.last_row
      assert_equal 0, area.first_column
      assert_equal 1, area.last_column
    end

    def test_3d_references
      assert_equal "Sheet2!A1", parse("5a 0100 0000 00c0").to_s
      assert_equal "Sheet1:Sheet3!A1:B2", parse("5b 0200 0000 0100 00c0 01c0").to_s
      assert_equal ["Sheet2"], parse("5a 0100 0000 00c0").sheets
      assert_equal ["Sheet1", "Sheet2", "Sheet3"],
        parse("5b 0200 0000 0100 00c0 01c0").sheets
    end

    def test_3d_dependencies
      deps = parse("5b 0200 0000 0100 00c0 01c0").dependencies
      assert_equal 1, deps.size
      dep = deps.first
      assert_equal ["Sheet1", "Sheet2", "Sheet3"], dep.sheets
      assert_equal 0, dep.first_row
      assert_equal 1, dep.last_row
      assert_equal 0, dep.first_column
      assert_equal 1, dep.last_column
      assert_nil dep.external
    end

    def test_external_reference_keeps_identity
      ref = parse "5a 0300 0500 02c0"
      assert_equal ["ExtSheet"], ref.sheets
      assert_equal 1, ref.external[:supbook]
      assert_equal "file:///tmp/other.xls", ref.external[:url]
      assert_equal "[1]ExtSheet!C6", ref.to_s
      dep = ref.dependencies.first
      assert_equal 1, dep.external[:supbook]
      assert_equal 5, dep.first_row
      assert_equal 2, dep.first_column
    end

    def test_defined_names
      name = parse "43 0100 0000"
      assert_equal "MyName", name.to_s
      assert_equal "MyName", name.name
      assert_equal 1, name.index
      dep = name.dependencies.first
      assert_equal "MyName", dep.name
      assert_equal 1, dep.name_index
      # unknown name index keeps its numeric identity
      assert_equal "NAME#9", parse("43 0900 0000").to_s
    end

    def test_external_name_keeps_identity
      name = parse "59 0300 0200 0000"
      assert_equal "[1]!NAME#2", name.to_s
      assert_equal 1, name.external[:supbook]
      assert_equal "file:///tmp/other.xls", name.external[:url]
    end

    def test_functions
      assert_equal "SUM(1,2)", parse("1e 0100 1e 0200 42 02 0400").to_s
      assert_equal "PI()", parse("21 1300").to_s
      assert_equal "IF(1,2,3)", parse("1e 0100 1e 0200 1e 0300 42 03 0100").to_s
      call = parse "1e 0100 1e 0200 42 02 0400"
      assert_equal "SUM", call.name
      assert_equal 4, call.id
      assert_equal 2, call.arguments.size
      # unknown function id with known arity from the token
      assert_equal "FUNC#999(1)", parse("1e 0100 42 01 e703").to_s
    end

    def test_attr_sum_and_transparent_tokens
      assert_equal "SUM(A1:A10)", parse("25 0000 0900 00c0 00c0 19 1000 00").to_s
      # ptgAttr space is transparent
      assert_equal "1+2", parse("1e 0100 19 400000 1e 0200 03").to_s
      # ptgParen is transparent
      assert_equal "1+2", parse("1e 0100 1e 0200 03 15").to_s
      # ptgMemArea is transparent
      assert_equal "1+2", parse("1e 0100 26 0000 0000 1e 0200 03").to_s
    end

    def test_missing_argument
      assert_equal "IF(1,)", parse("1e 0100 16 42 02 0100").to_s
    end

    def test_inline_array
      node = parse "20 00000000000000"
      assert_instance_of Ast::InlineArray, node
      assert_equal "{...}", node.to_s
      assert_equal :reference, node.ptg_class
    end

    def test_unknown_token_stops_parsing
      raw = tokens "1e 0100 77 1e 0200 03"
      node = Parser.new(CONTEXT).parse raw, row: 0, column: 0
      assert_instance_of Ast::Unknown, node
      assert_equal 0x77, node.ptg
      assert_equal 3, node.offset
      assert_equal raw[3..], node.bytes
      assert_match(/0x77/, node.to_s)
      assert_equal [], node.dependencies
    end

    def test_truncated_token_is_unknown
      node = parse "1e 0100 1f 0200"
      assert_instance_of Ast::Unknown, node
      assert_equal 3, node.offset
    end

    def test_unknown_function_with_fixed_arity_is_unknown
      node = parse "21 e703"
      assert_instance_of Ast::Unknown, node
      assert_equal 0x21, node.ptg
    end

    def test_shared_formula_expansion_per_cell
      # shared formula "=<cell one column to the left>*2" anchored at row 2, col 1
      context = CONTEXT.merge shared: {[2, 1] => tokens("4c 0000 ffc0 1e 0200 05")}
      parser = Parser.new context
      top = parser.parse tokens("01 0200 0100"), row: 2, column: 1
      assert_equal "A3*2", top.to_s
      assert_equal [Dep.new(first_row: 2, last_row: 2, first_column: 0, last_column: 0)],
        top.dependencies
      # the same shared tokens expand differently for another cell
      bottom = parser.parse tokens("01 0200 0100"), row: 5, column: 1
      assert_equal "A6*2", bottom.to_s
      assert_equal [Dep.new(first_row: 5, last_row: 5, first_column: 0, last_column: 0)],
        bottom.dependencies
    end

    def test_shared_formula_missing_anchor_is_unknown
      node = parse "01 0200 0100"
      assert_instance_of Ast::Unknown, node
      assert_equal 0x01, node.ptg
    end

    def test_formula_without_parse_context
      formula = Spreadsheet::Formula.new
      assert_nil formula.ast
      assert_equal [], formula.dependencies
      assert_equal "", formula.to_s
    end
  end

  class TestFormulaIntegration < Test::Unit::TestCase
    Dep = Spreadsheet::Formula::Ast::Dependency

    def setup
      @data = File.expand_path "data", File.dirname(__FILE__)
      @book = Spreadsheet.open File.join(@data, "test_formula_ast.xls")
      @sheet = @book.worksheet 0
    end

    def teardown
      Spreadsheet.client_encoding = "UTF-8"
    end

    def test_shared_formula_expands_per_cell
      # B1:B10 all share the same token array "=<left neighbor>*2"
      10.times do |idx|
        formula = @sheet[idx, 1]
        assert_instance_of Spreadsheet::Formula, formula
        assert_equal true, formula.shared
        assert_equal "A#{idx + 1}*2", formula.ast.to_s
        expected = [Dep.new(first_row: idx, last_row: idx,
          first_column: 0, last_column: 0)]
        assert_equal expected, formula.dependencies,
          "dependencies of B#{idx + 1} differ"
      end
      # every cell resolves to a *different* dependency
      deps = 10.times.map { |idx| @sheet[idx, 1].dependencies.first }
      assert_equal 10, deps.uniq.size
    end

    def test_area_dependency
      formula = @sheet[0, 2]
      assert_equal "SUM(A1:A10)", formula.ast.to_s
      assert_equal [Dep.new(first_row: 0, last_row: 9,
        first_column: 0, last_column: 0)], formula.dependencies
    end

    def test_cross_sheet_area_dependency
      formula = @sheet[0, 3]
      assert_equal "SUM(Other!A1:B2)", formula.ast.to_s
      assert_equal [Dep.new(sheets: ["Other"], first_row: 0, last_row: 1,
        first_column: 0, last_column: 1)], formula.dependencies
    end

    def test_absolute_and_relative_references
      formula = @sheet[0, 4]
      assert_equal "$A$1+B$1", formula.ast.to_s
      assert_equal [Dep.new(first_row: 0, last_row: 0, first_column: 0, last_column: 0),
        Dep.new(first_row: 0, last_row: 0, first_column: 1, last_column: 1)],
        formula.dependencies
    end

    def test_3d_single_reference
      formula = @sheet[0, 5]
      assert_equal "Other!A2+A2", formula.ast.to_s
      assert_equal [Dep.new(sheets: ["Other"], first_row: 1, last_row: 1,
        first_column: 0, last_column: 0),
        Dep.new(first_row: 1, last_row: 1, first_column: 0, last_column: 0)],
        formula.dependencies
    end

    def test_defined_name_dependency
      formula = @sheet[0, 6]
      assert_equal "MyRate+1", formula.ast.to_s
      assert_equal [Dep.new(name: "MyRate", name_index: 1)], formula.dependencies
      assert_equal "MyRate", @book.defined_names.first[:name]
    end

    def test_multi_sheet_area_dependency
      formula = @sheet[0, 7]
      assert_equal "SUM(Data:Other!A1)", formula.ast.to_s
      assert_equal [Dep.new(sheets: ["Data", "Other"], first_row: 0, last_row: 0,
        first_column: 0, last_column: 0)], formula.dependencies
    end

    def test_external_workbook_reference_keeps_identity
      formula = @sheet[0, 8]
      assert_equal "[1]!A1", formula.ast.to_s
      deps = formula.dependencies
      assert_equal 1, deps.size
      external = deps.first.external
      assert_equal 1, external[:supbook]
      assert_match(/ext_source.xls/, external[:url])
      assert_equal [], deps.first.sheets
      assert_equal 0, deps.first.first_row
      assert_equal 0, deps.first.first_column
    end

    def test_precedence_parentheses
      formula = @sheet[0, 9]
      assert_equal "(A1+A2)*A3", formula.ast.to_s
      assert_equal [Dep.new(first_row: 0, last_row: 0, first_column: 0, last_column: 0),
        Dep.new(first_row: 1, last_row: 1, first_column: 0, last_column: 0),
        Dep.new(first_row: 2, last_row: 2, first_column: 0, last_column: 0)],
        formula.dependencies
    end

    def test_formula_text_includes_equals_sign
      assert_equal "=SUM(A1:A10)", @sheet[0, 2].to_s
    end

    def test_shared_formula_string_constant
      book = Spreadsheet.open File.join(@data, "test_formula.xls")
      sheet = book.worksheet 0
      formula = sheet[1, 2]
      assert_equal "5026", formula.value
      assert_equal '"5026"', formula.ast.to_s
      assert_equal [], formula.dependencies
    end

    def test_shared_formula_resolves_across_row_blocks
      # the anchor of this shared formula lives in a different row block
      # than the cell itself; parsing must trigger reading that block
      book = Spreadsheet.open File.join(@data, "test_formula.xls")
      sheet = book.worksheet 0
      formula = sheet[100, 2]
      assert_equal '"5026"', formula.ast.to_s
    end
  end
end
