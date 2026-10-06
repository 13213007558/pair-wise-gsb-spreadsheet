require "spreadsheet/encodings"
require "spreadsheet/excel/error"
require "spreadsheet/formula/ast"
require "spreadsheet/formula/functions"

module Spreadsheet
  class Formula
    ##
    # Parses a BIFF8 RPN token array (the "formula data" of a FORMULA,
    # SHRFMLA, ARRAY or NAME record) into an abstract syntax tree.
    #
    # The parser understands the common ptg operators, functions, constants,
    # error values and 2D/3D references. Token classes (reference/value/
    # array) are preserved on the resulting nodes. Shared formulas (ptgExp)
    # are expanded per owning cell by re-parsing the shared token array with
    # the cell's own coordinates, so relative references resolve correctly.
    # Defined names and external workbook references keep their identity;
    # external files are never read. Unknown tokens stop parsing and are
    # returned as Ast::Unknown nodes carrying their offset and raw bytes.
    class Parser
      include Spreadsheet::Encodings

      PTG_CLASSES = {0x20 => :reference, 0x40 => :value, 0x60 => :array}.freeze

      BINARY_OPERATORS = {
        0x03 => :add, 0x04 => :sub, 0x05 => :mul, 0x06 => :div,
        0x07 => :power, 0x08 => :concat, 0x09 => :lt, 0x0a => :le,
        0x0b => :eq, 0x0c => :ge, 0x0d => :gt, 0x0e => :ne,
        0x0f => :isect, 0x10 => :union, 0x11 => :range
      }.freeze

      UNARY_OPERATORS = {0x12 => :plus, 0x13 => :minus, 0x14 => :percent}.freeze

      ##
      # Raised when the token array is structurally invalid (truncated token
      # data or an operand stack underflow). Caught by #parse and turned
      # into an Ast::Unknown node.
      class StructuralError < StandardError; end

      ##
      # Context options:
      # * :sheets          - Array of worksheet names of the workbook
      # * :names           - Array of defined names (Strings), 0-based; the
      #                      ptgName index is 1-based
      # * :externsheets    - Array of [supbook, first_sheet, last_sheet]
      # * :supbooks        - Array of Hashes {type:, url:, sheets:}
      # * :shared          - Hash mapping [row, column] of a shared formula
      #                      anchor to its token array
      def initialize opts = {}
        @context = opts
        @sheets = opts[:sheets] || []
        @names = opts[:names] || []
        @externsheets = opts[:externsheets] || []
        @supbooks = opts[:supbooks] || []
        @shared = opts[:shared] || {}
        @shared_resolver = opts[:shared_resolver]
      end

      ##
      # Parse +tokens+ (a binary String of RPN tokens) into an Ast node.
      # +row+ and +column+ are the 0-based coordinates of the cell owning
      # the formula; they are used to resolve relative references.
      def parse tokens, row: nil, column: nil
        @tokens = tokens
        @pos = 0
        @row = row
        @column = column
        if shared_formula? tokens
          srow, scol = tokens.unpack("xvv")
          return expand_shared srow, scol, tokens
        end
        stack = []
        while @pos < @tokens.bytesize
          offset = @pos
          ptg = read_u8
          node = dispatch ptg, stack
          return Ast::Unknown.new(ptg: ptg, offset: offset, bytes: @tokens[offset..]) if node == :unknown
          stack.push node if node
        end
        if stack.size == 1
          stack.first
        else
          Ast::Unknown.new(ptg: nil, offset: @pos, bytes: "")
        end
      rescue StructuralError
        Ast::Unknown.new(ptg: ptg, offset: offset || @pos, bytes: @tokens[(offset || @pos)..])
      end

      private

      def shared_formula? tokens
        tokens.bytesize == 5 && tokens.getbyte(0) == 0x01
      end

      ##
      # Expand a ptgExp indirection: parse the shared token array belonging
      # to the anchor cell [srow, scol] in the context of the current cell.
      def expand_shared srow, scol, original
        tokens = @shared[[srow, scol]]
        tokens ||= @shared_resolver.call(srow, scol) if @shared_resolver
        if tokens
          self.class.new(@context).parse tokens, row: @row, column: @column
        else
          Ast::Unknown.new(ptg: 0x01, offset: 0, bytes: original)
        end
      end

      def dispatch ptg, stack
        case ptg
        when 0x01 # ptgExp is only valid as the sole token of a formula
          :unknown
        when 0x02 # ptgTbl
          read_bytes 4
          nil
        when 0x03..0x11
          binary stack, BINARY_OPERATORS.fetch(ptg)
        when 0x12..0x14
          unary stack, UNARY_OPERATORS.fetch(ptg)
        when 0x15 # ptgParen: precedence is already encoded in the RPN
          nil
        when 0x16
          Ast::MissingArg.new
        when 0x17
          parse_string
        when 0x19
          parse_attr stack
        when 0x1c
          Ast::Constant.new Spreadsheet::Excel::Error.new(read_u8)
        when 0x1d
          Ast::Constant.new(read_u8 != 0)
        when 0x1e
          Ast::Constant.new(read_u16)
        when 0x1f
          Ast::Constant.new(read_double)
        else
          if ptg > 0x7f
            :unknown
          else
            dispatch_operand ptg, stack
          end
        end
      end

      def dispatch_operand ptg, stack
        klass = PTG_CLASSES[ptg & 0x60]
        return :unknown unless klass
        case (ptg & 0x1f) | 0x20
        when 0x20 # ptgArray: inline array constant, 7 reserved bytes
          Ast::InlineArray.new read_bytes(7), ptg_class: klass
        when 0x21 # ptgFunc
          parse_func klass, stack
        when 0x22 # ptgFuncVar
          parse_funcvar klass, stack
        when 0x23 # ptgName
          parse_name klass
        when 0x24 # ptgRef
          parse_ref klass
        when 0x25 # ptgArea
          parse_area klass
        when 0x26 # ptgMemArea
          read_bytes 4
          nil
        when 0x27 # ptgMemErr
          read_bytes 4
          error = Spreadsheet::Excel::Error.new(read_u8)
          read_bytes 2
          Ast::Constant.new error, ptg_class: klass
        when 0x28 # ptgMemNoMem
          read_bytes 6
          nil
        when 0x29 # ptgMemFunc
          read_bytes 2
          nil
        when 0x2a # ptgRefErr
          read_bytes 4
          Ast::Constant.new Spreadsheet::Excel::Error.new(0x17), ptg_class: klass
        when 0x2b # ptgAreaErr
          read_bytes 8
          Ast::Constant.new Spreadsheet::Excel::Error.new(0x17), ptg_class: klass
        when 0x2c # ptgRefN
          parse_refn klass
        when 0x2d # ptgAreaN
          parse_arean klass
        when 0x2e # ptgMemAreaN
          read_bytes 4
          nil
        when 0x2f # ptgMemNoMemN
          read_bytes 6
          nil
        when 0x39 # ptgNameX
          parse_namex klass
        when 0x3a # ptgRef3d
          parse_ref3d klass
        when 0x3b # ptgArea3d
          parse_area3d klass
        when 0x3c # ptgRefErr3d
          read_bytes 6
          Ast::Constant.new Spreadsheet::Excel::Error.new(0x17), ptg_class: klass
        when 0x3d # ptgAreaErr3d
          read_bytes 10
          Ast::Constant.new Spreadsheet::Excel::Error.new(0x17), ptg_class: klass
        else
          :unknown
        end
      end

      def binary stack, operator
        right = stack.pop || raise(StructuralError)
        left = stack.pop || raise(StructuralError)
        Ast::Binary.new operator, left, right
      end

      def unary stack, operator
        operand = stack.pop || raise(StructuralError)
        Ast::Unary.new operator, operand
      end

      def parse_string
        cch = read_u8
        flags = read_u8
        wide = (flags & 0x01) > 0
        raw = read_bytes cch * (wide ? 2 : 1)
        raw = widen(raw) unless wide
        Ast::Constant.new client(raw, "UTF-16LE")
      end

      def parse_attr stack
        flags = read_u8
        data = read_u16
        if (flags & 0x02) > 0 # ptgAttrChoose: skip the jump table
          read_bytes (data + 1) * 2
          nil
        elsif (flags & 0x10) > 0 # ptgAttrSum: optimized SUM
          operand = stack.pop || raise(StructuralError)
          Ast::Funcall.new "SUM", [operand]
        else
          # volatile, optimized IF and space tokens are transparent
          nil
        end
      end

      def parse_func klass, stack
        id = read_u16
        entry = Functions[id]
        return :unknown unless entry && entry[1] == entry[2]
        Ast::Funcall.new entry[0], pop_arguments(stack, entry[1]), id: id, ptg_class: klass
      end

      def parse_funcvar klass, stack
        cparams = read_u8
        id = read_u16
        entry = Functions[id]
        name = entry ? entry[0] : "FUNC##{id}"
        Ast::Funcall.new name, pop_arguments(stack, cparams), id: id, ptg_class: klass
      end

      def parse_name klass
        index = read_u16
        read_bytes 2
        Ast::Name.new index: index, name: @names[index - 1], ptg_class: klass
      end

      def parse_namex klass
        ixti = read_u16
        index = read_u16
        read_bytes 2
        Ast::Name.new index: index, external: external_identity(ixti), ptg_class: klass
      end

      def parse_ref klass
        rw = read_u16
        col, col_rel, row_rel = read_column_flags
        Ast::Ref.new row: rw, column: col,
          row_relative: row_rel, column_relative: col_rel, ptg_class: klass
      end

      def parse_refn klass
        rw_word = read_u16
        col_word = read_u16
        col_rel = (col_word & 0x4000) > 0
        row_rel = (col_word & 0x8000) > 0
        rw = row_rel ? @row.to_i + signed16(rw_word) : rw_word
        col = col_rel ? @column.to_i + relative_column(col_word) : col_word & 0x3fff
        Ast::Ref.new row: rw, column: col,
          row_relative: row_rel, column_relative: col_rel, ptg_class: klass
      end

      def parse_area klass
        first_row = read_u16
        last_row = read_u16
        first_col, first_col_rel, first_row_rel = read_column_flags
        last_col, last_col_rel, last_row_rel = read_column_flags
        Ast::Area.new first_row: first_row, last_row: last_row,
          first_column: first_col, last_column: last_col,
          first_row_relative: first_row_rel, last_row_relative: last_row_rel,
          first_column_relative: first_col_rel, last_column_relative: last_col_rel,
          ptg_class: klass
      end

      def parse_arean klass
        first_word = read_u16
        last_word = read_u16
        first_col_word = read_u16
        last_col_word = read_u16
        first_col_rel = (first_col_word & 0x4000) > 0
        first_row_rel = (first_col_word & 0x8000) > 0
        last_col_rel = (last_col_word & 0x4000) > 0
        last_row_rel = (last_col_word & 0x8000) > 0
        first_row = first_row_rel ? @row.to_i + signed16(first_word) : first_word
        last_row = last_row_rel ? @row.to_i + signed16(last_word) : last_word
        first_col = first_col_rel ? @column.to_i + relative_column(first_col_word) : first_col_word & 0x3fff
        last_col = last_col_rel ? @column.to_i + relative_column(last_col_word) : last_col_word & 0x3fff
        Ast::Area.new first_row: first_row, last_row: last_row,
          first_column: first_col, last_column: last_col,
          first_row_relative: first_row_rel, last_row_relative: last_row_rel,
          first_column_relative: first_col_rel, last_column_relative: last_col_rel,
          ptg_class: klass
      end

      def parse_ref3d klass
        ixti = read_u16
        rw = read_u16
        col, col_rel, row_rel = read_column_flags
        sheets, external = resolve_3d ixti
        Ast::Ref.new row: rw, column: col,
          row_relative: row_rel, column_relative: col_rel,
          sheets: sheets, external: external, ptg_class: klass
      end

      def parse_area3d klass
        ixti = read_u16
        first_row = read_u16
        last_row = read_u16
        first_col, first_col_rel, first_row_rel = read_column_flags
        last_col, last_col_rel, last_row_rel = read_column_flags
        sheets, external = resolve_3d ixti
        Ast::Area.new first_row: first_row, last_row: last_row,
          first_column: first_col, last_column: last_col,
          first_row_relative: first_row_rel, last_row_relative: last_row_rel,
          first_column_relative: first_col_rel, last_column_relative: last_col_rel,
          sheets: sheets, external: external, ptg_class: klass
      end

      ##
      # Resolve an EXTERNSHEET index to [sheet_names, external_identity].
      # Internal references resolve to worksheet names of this workbook;
      # external references keep their SUPBOOK/EXTERNSHEET identity without
      # touching the external file.
      def resolve_3d ixti
        entry = @externsheets[ixti]
        return [[], {ixti: ixti}] unless entry
        supbook_index, first, last = entry
        supbook = @supbooks[supbook_index]
        if supbook.nil?
          [[], {supbook: supbook_index, first: first, last: last}]
        elsif supbook[:type] == :internal
          [sheet_span(@sheets, first, last), nil]
        else
          external = {supbook: supbook_index, first: first, last: last}
          external[:url] = supbook[:url] if supbook[:url]
          [sheet_span(supbook[:sheets] || [], first, last), external]
        end
      end

      def external_identity ixti
        entry = @externsheets[ixti]
        return {ixti: ixti} unless entry
        supbook_index, first, last = entry
        supbook = @supbooks[supbook_index]
        identity = {supbook: supbook_index, first: first, last: last}
        identity[:url] = supbook[:url] if supbook && supbook[:url]
        identity
      end

      def sheet_span names, first, last
        return [] if first == 0xffff || last == 0xffff || first > last
        (first..last).map { |idx| names[idx] }.compact
      end

      def pop_arguments stack, count
        raise StructuralError if stack.size < count
        stack.pop count
      end

      ##
      # Read a column word (ColRelU): 14 column bits, bit 14 = column is
      # relative, bit 15 = row is relative.
      def read_column_flags
        word = read_u16
        [word & 0x3fff, (word & 0x4000) > 0, (word & 0x8000) > 0]
      end

      ##
      # The relative column offset of ptgRefN/ptgAreaN is stored as a signed
      # 8-bit value in the low byte of the column word. (If a writer ever
      # uses the upper bits, fall back to a signed 14-bit interpretation.)
      def relative_column col_word
        raw = col_word & 0x3fff
        if (raw & 0x3f00) > 0
          raw >= 0x2000 ? raw - 0x4000 : raw
        else
          raw >= 0x80 ? raw - 0x100 : raw
        end
      end

      def signed16 word
        word >= 0x8000 ? word - 0x10000 : word
      end

      ##
      # Insert null bytes into a compressed (8-bit) Unicode string
      def widen string
        data = +""
        string.each_byte { |byte| data << byte.chr << 0.chr }
        data
      end

      def read_u8
        byte = @tokens.getbyte @pos
        raise StructuralError unless byte
        @pos += 1
        byte
      end

      def read_u16
        read_bytes(2).unpack1 "v"
      end

      def read_double
        read_bytes(8).unpack1 "E"
      end

      def read_bytes count
        raise StructuralError if @pos + count > @tokens.bytesize
        bytes = @tokens[@pos, count]
        @pos += count
        bytes
      end
    end
  end
end
