# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/textfsm/index_table"

class IndexTableTest < Minitest::Test
  Attribute = Struct.new(:text, :conversions) do
    def to_s
      self.conversions += 1
      text
    end
  end

  def test_attribute_values_are_converted_once_per_query_and_only_when_matched
    Dir.mktmpdir do |directory|
      path = File.join(directory, "index")
      File.write(path, "Template,Vendor\nfirst,VendorA\\Z\nsecond,VendorB\\Z\n")
      index = TextFSM::IndexTable.new(path, compile: ->(key, value) { value unless key == "Template" })
      value = Attribute.new("VendorB", 0)
      ignored = Object.new
      def ignored.to_s
        raise "Unused values must not be converted"
      end
      attributes = { Vendor: value, Unknown: ignored, Template: ignored }.freeze

      assert_equal "second", index.match(attributes).fetch("Template")
      assert_equal 1, value.conversions
      assert_same value, attributes[:Vendor]
      value.text = "VendorA"
      assert_equal "first", index.match(attributes).fetch("Template")
      assert_equal 2, value.conversions

      File.write(path, "Template,Vendor\nwildcard,\nsecond,VendorB\\Z\n")
      wildcard = TextFSM::IndexTable.new(path)
      assert_equal "wildcard", wildcard.match(Vendor: ignored).fetch("Template")
    end
  end

  def test_invalid_index_encoding_reports_the_file_and_line
    Dir.mktmpdir do |directory|
      path = File.join(directory, "index")
      ["Template,Vendor\nfirst,Vendor\xFF\n", "Template,Vendor\n# comment\xFF\n"].each do |source|
        File.binwrite(path, source)
        error = assert_raises(TextFSM::IndexError) { TextFSM::IndexTable.new(path) }
        assert_includes error.message, path
        assert_includes error.message, "UTF-8"
        assert_includes error.message, "2"
      end
    end
  end

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

  def test_repeated_patterns_keep_per_cell_callbacks_and_owned_sources
    Dir.mktmpdir do |directory|
      path = File.join(directory, "index")
      File.write(path, "Template,Vendor,Command\nfirst,A,show\nsecond,B,show\nthird,A,list\n")
      calls = []
      buffer = +""
      compile = lambda do |key, value|
        calls << [key, value]
        buffer.replace(value) unless key == "Template"
      end
      index = TextFSM::IndexTable.new(path, compile: compile)
      buffer.replace("changed")

      assert_equal index.flat_map(&:to_a), calls
      assert_equal "first", index.match(Vendor: "A", Command: "show").fetch("Template")
      assert_equal "second", index.match(Vendor: "B", Command: "show").fetch("Template")
      assert_equal "third", index.match(Vendor: "A", Command: "list").fetch("Template")
      assert_nil index.match(Vendor: "changed")
      changed = TextFSM::IndexTable.new(path, compile: ->(key, value) { "(?i:#{value})" unless key == "Template" })
      assert_equal "first", changed.match(Vendor: "a", Command: "SHOW").fetch("Template")
      assert_nil index.match(Vendor: "a", Command: "SHOW")
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

  def test_symbol_and_string_attributes_are_each_matched_without_coercing_unknown_values
    Dir.mktmpdir do |directory|
      path = File.join(directory, "index")
      File.write(path, "Template,Vendor\nfirst,VendorA\\Z\nsecond,VendorB\\Z\n")
      index = TextFSM::IndexTable.new(path)
      unknown = Object.new
      def unknown.to_s
        raise "Ignored attributes must not be converted"
      end

      assert_equal "first", index.match(Vendor: "VendorA", Unknown: unknown).fetch("Template")
      assert_nil index.match({ Vendor: "VendorA", "Vendor" => "VendorB" })
    end
  end
end
