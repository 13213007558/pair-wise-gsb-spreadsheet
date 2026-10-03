#!/usr/bin/env ruby
# TestRichText -- Spreadsheet -- 03.10.2026

$: << File.expand_path("../lib", File.dirname(__FILE__))

require "test/unit"
require "spreadsheet"

module Spreadsheet
  class TestRichText < Test::Unit::TestCase
    def setup
      @font1 = Font.new "Arial"
      @font2 = Font.new "Courier"
      @font2.italic = true
      @font3 = Font.new "Times"
    end

    def runs *pairs
      pairs.each_slice(2).map { |pos, font| RichText::Run.new pos, font }
    end

    def test_behaves_like_a_string
      rt = RichText.new "hello"
      assert_kind_of String, rt
      assert_equal "hello", rt
      assert_equal "hello", rt.to_s
      assert_equal false, rt.rich?
      assert_equal [], rt.runs
      assert_nil rt.ext_data
    end

    def test_rich?
      assert_equal true, RichText.new("a", runs: runs(0, @font1)).rich?
      assert_equal true, RichText.new("a", ext_data: "xy").rich?
      assert_equal false, RichText.new("a").rich?
    end

    def test_utf16_length_counts_surrogate_pairs_as_two
      rt = RichText.new "a😀b"
      assert_equal 3, rt.length
      assert_equal 4, rt.utf16_length
      assert_equal 0, RichText.new("").utf16_length
    end

    def test_utf16_position
      rt = RichText.new "a😀b"
      assert_equal 0, rt.utf16_position(0)
      assert_equal 1, rt.utf16_position(1)
      assert_equal 3, rt.utf16_position(2)
      assert_equal 4, rt.utf16_position(3)
    end

    def test_ruby_position
      rt = RichText.new "a😀b"
      assert_equal 0, rt.ruby_position(0)
      assert_equal 1, rt.ruby_position(1)
      ## position 2 points into the second half of the surrogate pair
      assert_equal 1, rt.ruby_position(2)
      assert_equal 2, rt.ruby_position(3)
      assert_equal 3, rt.ruby_position(4)
    end

    def test_runs_by_char
      rt = RichText.new "a😀bc", runs: runs(0, @font1, 3, @font2)
      assert_equal [[0, @font1], [2, @font2]], rt.runs_by_char
    end

    def test_replace_text_appends_keeps_runs
      rt = RichText.new "hello", runs: runs(0, @font1, 2, @font2)
      rt.replace_text "hello world"
      assert_equal "hello world", rt
      assert_equal [0, 2], rt.runs.map(&:position)
    end

    def test_replace_text_shifts_suffix_runs
      rt = RichText.new "abcdef", runs: runs(0, @font1, 2, @font2, 4, @font3)
      rt.replace_text "abXYZcdef"
      assert_equal [0, 5, 7], rt.runs.map(&:position)
      assert_equal [@font1, @font2, @font3], rt.runs.map(&:font)
    end

    def test_replace_text_drops_runs_in_replaced_region
      rt = RichText.new "abcdef", runs: runs(0, @font1, 2, @font2, 3, @font3, 5, @font1)
      rt.replace_text "abf"
      assert_equal [0, 2], rt.runs.map(&:position)
      assert_equal [@font1, @font2], rt.runs.map(&:font)
    end

    def test_replace_text_inserts_run_at_zero
      rt = RichText.new "abc", runs: runs(1, @font1, 2, @font2)
      rt.replace_text "zbc"
      assert_equal [0, 1, 2], rt.runs.map(&:position)
      assert_equal @font1, rt.runs.first.font
    end

    def test_replace_text_full_replacement_keeps_single_run
      rt = RichText.new "abc", runs: runs(0, @font1, 1, @font2)
      rt.replace_text "xy"
      assert_equal [0], rt.runs.map(&:position)
      assert_equal @font1, rt.runs.first.font
    end

    def test_replace_text_with_non_bmp_characters
      rt = RichText.new "a😀c", runs: runs(0, @font1, 3, @font2)
      rt.replace_text "a😀😀c"
      assert_equal [0, 5], rt.runs.map(&:position)
      rt.replace_text "bc"
      ## the run on the trailing 'c' follows it to its new position
      assert_equal [0, 1], rt.runs.map(&:position)
      assert_equal [@font1, @font2], rt.runs.map(&:font)
    end

    def test_replace_text_drops_runs_beyond_new_end
      rt = RichText.new "aaaa", runs: runs(0, @font1, 3, @font2)
      rt.replace_text "bb"
      assert_equal [0], rt.runs.map(&:position)
    end

    def test_plain_string_assignment_does_not_touch_runs
      rt = RichText.new "abc", runs: runs(0, @font1, 2, @font2)
      rt.replace "xy"
      assert_equal [0, 2], rt.runs.map(&:position)
    end

    def test_eql_and_hash_for_deduplication
      a = RichText.new "text", runs: runs(0, @font1)
      b = RichText.new "text", runs: runs(0, @font2)
      c = RichText.new "text", runs: runs(0, @font1)
      d = RichText.new "text", runs: runs(0, @font1, 2, @font1)
      e = RichText.new "text", ext_data: "x"
      assert a.eql?(c)
      assert_equal a.hash, c.hash
      assert !a.eql?(b)
      assert !a.eql?(d)
      assert !a.eql?(e)
      assert !a.eql?("text")
      assert !a.eql?(RichText.new("text"))
      ## with keys normalized to RichText (as the SST writer does via
      ## RichText.coerce), deduplication is format-aware
      hash = {}
      [a, b, c, RichText.new("text")].each_with_index do |key, idx|
        hash[key] = idx
      end
      assert_equal 3, hash.size
      assert_equal 2, hash[a]
      assert_equal 1, hash[b]
      assert_equal 3, hash[RichText.new("text")]
    end

    def test_plain_richtext_eqls_plain_string
      rt = RichText.new "plain"
      assert rt.eql?("plain")
      assert_equal "plain".hash, rt.hash
      hash = {"plain" => 1}
      hash[rt] = 2
      assert_equal 1, hash.size
    end

    def test_dup_copies_runs_and_ext_data
      rt = RichText.new "abc", runs: runs(0, @font1), ext_data: "xy"
      copy = rt.dup
      assert_equal rt.runs, copy.runs
      assert_not_same rt.runs, copy.runs
      assert_equal "xy", copy.ext_data
    end
  end
end
