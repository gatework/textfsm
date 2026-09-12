# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/textfsm/index_table"

class IndexTableTest < Minitest::Test
  def test_header_only_index_is_an_empty_enumerable
    Dir.mktmpdir do |directory|
      path = File.join(directory, "index")
      File.write(path, "Template,Vendor\n")
      index = TextFSM::IndexTable.new(path)

      assert_empty index
      assert_equal 0, index.each.size
      assert_empty index.to_a
      assert_nil index.match(Vendor: "anything")
      assert_equal %w[Template Vendor], index.header
    end
  end

  def test_transform_and_compile_keep_independent_immutable_values
    Dir.mktmpdir do |directory|
      path = File.join(directory, "index")
      File.write(path, "Template,Vendor\nchosen,vendor\n")
      transformed = []
      index = TextFSM::IndexTable.new(
        path,
        transform: lambda do |_key, value|
          value.upcase.tap do |result|
            transformed << result
          end
        end,
        compile: ->(key, value) { value.downcase unless key == "Template" }
      )
      transformed.each(&:clear)

      assert_equal [{ "Template" => "CHOSEN", "Vendor" => "VENDOR" }], index.to_a
      assert_same index[0], index.match(Vendor: "vendor")
      assert_nil index.match(Vendor: "VENDOR")
      refute index.empty?
      assert_same(index, index.each do |row|
        assert_equal "CHOSEN", row.fetch("Template")
      end)
      assert_raises(FrozenError) do
        index.header.first.replace("changed")
      end
    end
  end

  def test_index_validation_and_wildcards
    Dir.mktmpdir do |dir|
      path = File.join(dir, "index")
      File.write(path, "# no header\n\n")
      assert_raises(TextFSM::IndexError) do
        TextFSM::IndexTable.new(path)
      end
      File.write(path, "Template,Template\na,b\n")
      assert_raises(TextFSM::IndexError) do
        TextFSM::IndexTable.new(path)
      end
      File.write(path, "Template,Vendor\na,\nmalformed\n")
      index = TextFSM::IndexTable.new(path)
      assert_equal 1, index.size
      assert_equal index[0], index.match(Vendor: "anything")
    end
  end

  def test_index_rows_are_immutable_and_match_returns_a_row_or_nil
    Dir.mktmpdir do |directory|
      path = File.join(directory, "index")
      File.write(path, "Template,Vendor\nfirst,VendorA\nsecond,VendorB\n")
      index = TextFSM::IndexTable.new(path)
      match = index.match(Vendor: "VendorB")
      assert_equal "VendorB", match.fetch("Vendor")
      assert_raises(FrozenError) do
        match["Vendor"].replace("other")
      end
      assert_raises(FrozenError) do
        match["Template"] = "missing"
      end
      assert_same match, index.match(Vendor: "VendorB")
      assert_nil index.match(Vendor: "missing")
      assert_equal index.size, index.each.size
    end
  end

  def test_index_preserves_hash_characters_in_patterns
    Dir.mktmpdir do |directory|
      path = File.join(directory, "index")
      File.write(path, "Template,Command\na,show # detail\n  # comment\n")
      index = TextFSM::IndexTable.new(path)
      assert_nil index.match(Command: "show other")
      assert_equal "a", index.match(Command: "show # detail").fetch("Template")
    end
  end
end
