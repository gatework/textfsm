# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/textfsm/table"

class TableTest < Minitest::Test
  def test_constructor_copies_nested_values_and_header_strings
    header = [+"PERSON"]
    rows = [[[{ "name" => +"Alice" }]]]
    table = TextFSM::Table.new(header, rows)
    header.first.replace("changed")
    rows[0][0][0]["name"].replace("changed")

    assert_equal ["PERSON"], table.header
    assert_equal [[[{ "name" => "Alice" }]]], table.to_a
  end

  def test_exports_do_not_mutate_nested_table_values
    table = TextFSM::Table.new(["PERSON"], [[[{ "name" => "Alice" }]]])
    table.to_a[0][0][0]["name"] = "changed"
    table.to_hashes[0]["PERSON"] << { "name" => "Bob" }

    assert_equal [[[{ "name" => "Alice" }]]], table.to_a
  end

  def test_merge_copies_nested_values_from_the_right_table
    left = TextFSM::Table.new(["ID"], [["1"]])
    right = TextFSM::Table.new(["PERSON"], [[[{ "name" => "Alice" }]]])
    left.merge!(right)
    right.to_a[0][0][0]["name"] = "changed"

    assert_equal [["1", [{ "name" => "Alice" }]]], left.to_a
  end

  def test_merge_returns_an_independent_table_and_preserves_both_inputs
    left = TextFSM::Table.new(["ID"], [["2"], ["1"]])
    right = TextFSM::Table.new(%w[ID PERSON], [["1", [{ "name" => "Alice" }]], ["2", [{ "name" => "Bob" }]]])
    merged = left.merge(right, keys: ["ID"])

    assert_instance_of TextFSM::Table, merged
    refute_same left, merged
    assert_equal [["2", [{ "name" => "Bob" }]], ["1", [{ "name" => "Alice" }]]], merged.rows
    merged.sort!
    merged.to_a[0][1][0]["name"].replace("changed")

    assert_equal ["ID"], left.header
    assert_equal [["2"], ["1"]], left.rows
    assert_equal [["1", [{ "name" => "Alice" }]], ["2", [{ "name" => "Bob" }]]], right.rows
    assert_equal right.rows, merged.rows
  end

  def test_merge_without_new_columns_still_returns_a_new_object
    table = TextFSM::Table.new(["ID"], [["2"], ["1"]])
    merged = table.merge(table)
    refute_same table, merged
    assert_equal table.rows, merged.rows
    merged.sort!
    assert_equal [["2"], ["1"]], table.rows
  end

  def test_enumeration_and_indexing_expose_immutable_rows
    table = TextFSM::Table.new(["X"], [["a"]])
    assert_equal 1, table.each.size
    assert_same(table, table.each do |row|
      assert_equal ["a"], row
    end)
    assert_raises(FrozenError) do
      table[0][0].replace("changed")
    end
    assert_raises(FrozenError) do
      table.rows << ["changed"]
    end
    refute table.empty?
  end

  def test_sorting_uses_ruby_comparators_and_preserves_rows_when_comparison_fails
    table = TextFSM::Table.new(["X"], [["10"], ["unknown"], ["2"]])
    assert_same table, table.sort!
    assert_equal [["10"], ["2"], ["unknown"]], table.to_a
    assert_same(table, table.sort_by!.each do |row|
      row[0] == "unknown" ? Float::INFINITY : row[0].to_i
    end)
    assert_equal [["2"], ["10"], ["unknown"]], table.to_a
    before = table.rows
    assert_raises(ArgumentError) do
      table.sort_by! { |row| Float(row[0], exception: false) || row[0] }
    end
    assert_same before, table.rows
  end

  def test_invalid_shapes_and_merge_keys_fail_before_mutation
    ["a", { "X" => "a" }, nil].each do |row|
      assert_raises(ArgumentError) do
        TextFSM::Table.new(["X"], [row])
      end
    end
    assert_raises(ArgumentError) do
      TextFSM::Table.new("X", [["a"]])
    end
    assert_raises(ArgumentError) do
      TextFSM::Table.new(["X"], {})
    end
    assert_raises(ArgumentError) do
      TextFSM::Table.new(%w[X X], [[1, 2]])
    end
    assert_raises(ArgumentError) do
      TextFSM::Table.new(["X"], [[1, 2]])
    end
    left = TextFSM::Table.new(["X"], [["one"]])
    right = TextFSM::Table.new(["Y"], [["two"]])
    assert_raises(KeyError) do
      left.merge!(right, keys: ["X"])
    end
    assert_equal ["X"], left.header
    assert_equal [["one"]], left.rows
    assert_same left, left.merge!(left)
  end
end
