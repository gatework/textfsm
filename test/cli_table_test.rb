# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/textfsm/cli_table"

class CliTableTest < Minitest::Test
  DIRECTORY = File.join(__dir__, "fixtures/upstream")
  INPUT = "a b c\nd e f\n"

  def setup
    @table = TextFSM::CliTable.new(index: "default_index", template_dir: DIRECTORY)
  end

  def test_selection_and_command_completion
    @table.parse(INPUT, attributes: { "Vendor" => "VendorB", "Command" => "sh vers" })
    assert_equal %w[Col1 Col2 Col3], @table.header
    assert_equal [%w[a b c]], @table.to_a
    @table.parse(INPUT, attributes: { Vendor: "VendorA", Command: "show interfaces" })
    assert_equal [%w[d e f]], @table.to_a
  end

  def test_multiple_templates_merge_by_key
    assert_same @table, @table.parse(INPUT, attributes: { Vendor: "VendorA", Command: "sh ver" })
    assert_equal %w[Col1 Col2 Col3 Col4], @table.header
    assert_equal [%w[a b c b], %w[d e f e]], @table.to_a
    assert_equal ["Col1"], @table.keys
    assert_equal [{ "Col1" => "a", "Col2" => "b", "Col3" => "c", "Col4" => "b" },
                  { "Col1" => "d", "Col2" => "e", "Col3" => "f", "Col4" => "e" }], @table.to_hashes
  end

  def test_explicit_templates_and_reverse_column_order
    @table.parse(INPUT, templates: "clitable_templateB:clitable_templateA")
    assert_equal %w[Col1 Col4 Col2 Col3], @table.header
    assert_equal [%w[a b b c], %w[d e e f]], @table.to_a
  end

  def test_nonmutating_merge_preserves_cli_metadata_and_original_table
    @table.parse(INPUT, templates: "clitable_templateB")
    other = TextFSM::Table.new(["EXTRA"], [["one"], ["two"]])
    merged = @table.merge(other)

    assert_instance_of TextFSM::CliTable, merged
    assert_same @table.index, merged.index
    assert_equal @table.input, merged.input
    assert_equal @table.template_dir, merged.template_dir
    assert_equal @table.keys, merged.keys
    assert_equal %w[Col1 Col4 EXTRA], merged.header
    merged.keys += ["EXTRA"]
    merged.sort! { |left, right| right <=> left }
    assert_equal [%w[a b], %w[d e]], @table.rows
    assert_equal ["Col1"], @table.keys
  end

  def test_missing_match_and_missing_template_preserve_previous_table
    @table.parse(INPUT, templates: "clitable_templateB")
    before = @table.to_hashes
    assert_raises(TextFSM::IndexError) do
      @table.parse(INPUT, attributes: { Vendor: "Unknown" })
    end
    assert_raises(Errno::ENOENT) do
      @table.parse(INPUT, templates: "clitable_templateA:missing")
    end
    assert_equal before, @table.to_hashes
  end

  def test_missing_template_column
    assert_raises(TextFSM::IndexError) do
      TextFSM::CliTable.new(index: "nondefault_index", template_dir: DIRECTORY)
    end
  end

  def test_no_index_and_empty_templates
    table = TextFSM::CliTable.new(template_dir: DIRECTORY)
    assert_raises(TextFSM::IndexError) do
      table.parse(INPUT)
    end
    ["", [], "clitable_templateA:"].each do |templates|
      assert_raises(ArgumentError) do
        table.parse(INPUT, templates: templates)
      end
    end
    assert_equal [%w[a b], %w[d e]], table.parse(INPUT, templates: ["clitable_templateB"]).to_a
  end

  def test_index_matching_is_prefix_based_and_ignores_unknown_attributes
    index = @table.index
    assert_equal index[0], index.match("Hostname" => "abc", "Extra" => "ignored")
    assert_equal index[1], index.match("Vendor" => "VendorB", "Command" => "show version extra")
    assert_nil index.match("Vendor" => "PrefixVendorB")
  end

  def test_add_keys_sort_and_iteration
    @table.parse(INPUT, templates: "clitable_templateA")
    @table.keys += ["Col3"]
    assert_equal %w[Col1 Col3], @table.keys
    assert_equal %w[a c], @table.key_for(@table[0])
    @table.sort! { |left, right| @table.key_for(right) <=> @table.key_for(left) }
    assert_equal %w[d a], @table.map(&:first)
    assert_raises(KeyError) do
      @table.keys += ["missing"]
    end
  end

  def test_key_merge_uses_first_match_and_preserves_left_rows
    left = TextFSM::Table.new(%w[ID X], [%w[a one], %w[b two], %w[c three]])
    right = TextFSM::Table.new(%w[ID Y], [%w[b B], %w[a A], %w[b duplicate], %w[d D]])
    left.merge!(right, keys: ["ID"])
    assert_equal [%w[a one A], %w[b two B], ["c", "three", ""]], left.to_a
  end

  def test_merge_without_keys_uses_position
    left = TextFSM::Table.new(["X"], [["a"], ["b"]])
    right = TextFSM::Table.new(["Y"], [["one"]])
    left.merge!(right)
    assert_equal [["a", "one"], ["b", ""]], left.to_a
  end

  def test_sort_without_keys_compares_field_values_numerically
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "numbers"), "Value N (\\d+)\n\nStart\n  ^${N} -> Record\n")
      table = TextFSM::CliTable.new(template_dir: dir)
      table.parse("10\n2\n1\n", templates: "numbers")
      table.sort_by! { |row| row.first.to_i }
      assert_equal [["1"], ["2"], ["10"]], table.to_a
      assert_empty table.key_for(table[2])
      table.sort_by! { |row| -row.first.to_i }
      assert_equal [["10"], ["2"], ["1"]], table.to_a
    end
  end

  def test_failed_parsing_and_index_reload_preserve_all_previous_state
    @table.parse(INPUT, templates: "clitable_templateB")
    before = [@table.header, @table.rows, @table.keys, @table.input, @table.index]
    Dir.mktmpdir do |directory|
      template = File.join(directory, "error")
      File.write(template, "Value X (.*)\n\nStart\n  ^.* -> Error\n")
      failing = TextFSM::CliTable.new(template_dir: directory)
      assert_raises(TextFSM::ParseError) do
        failing.parse("anything", templates: "error")
      end
      assert_empty failing.rows
      assert_nil failing.input
    end
    assert_raises(TextFSM::IndexError) do
      @table.load_index("nondefault_index")
    end
    assert_raises(Errno::ENOENT) do
      @table.parse("different", templates: "clitable_templateA:missing")
    end
    assert_equal before, [@table.header, @table.rows, @table.keys, @table.input, @table.index]
  end

  def test_template_types_are_validated_without_overwriting_rows
    @table.parse(INPUT, templates: "clitable_templateB")
    before = @table.rows
    [false, 1, {}, [nil], [1]].each do |templates|
      assert_raises(ArgumentError) do
        @table.parse(INPUT, templates: templates)
      end
      assert_same before, @table.rows
    end
  end
end
