# frozen_string_literal: true

# Ruby port of Google TextFSM CLI tables. Copyright 2022 Google Inc.
# Modified in 2026. Licensed under Apache-2.0; see LICENSE.
require_relative "parser"
require_relative "index_table"
require_relative "table"

module TextFSM
  class CliTable < Table
    attr_reader :index, :template_dir, :input, :keys

    def initialize(index: nil, template_dir: ".")
      super()
      @template_dir = File.path(template_dir).dup.freeze
      @keys = [].freeze
      load_index(index) if index
    end

    def load_index(path)
      candidate = IndexTable.new(
        File.join(@template_dir, path),
        transform: ->(key, value) { key == "Command" ? expand_command(value) : value },
        compile: ->(key, value) { key == "Template" ? nil : value }
      )
      raise IndexError, "Index must contain a Template column" unless candidate.header.include?("Template")

      @index = candidate
      self
    end

    def parse(text, attributes: {}, templates: nil)
      names = template_names(templates.nil? ? find_templates(attributes) : templates)
      text = text.read if text.respond_to?(:read)
      raise ArgumentError, "text must be a String or readable IO" unless text.is_a?(String)

      keys = []
      table = names.reduce(nil) do |result, name|
        parser = Parser.from_file(File.join(@template_dir, name))
        keys = parser.fields_with_option("Key") if keys.empty?
        parsed = Table.new(parser.header, parser.parse(text))
        result ? result.merge!(parsed, keys: keys) : parsed
      end
      # Replace the result only after every template and merge succeeds.
      input = text.dup.freeze
      keys = Data.copy(keys, immutable: true)
      @input = input
      @header = table.header
      @rows = table.rows
      @keys = keys
      self
    end

    def keys=(columns)
      missing = columns - @header
      raise KeyError, "Unknown key columns: #{missing.join(', ')}" unless missing.empty?

      @keys = Data.copy(columns.uniq, immutable: true)
    end

    def key_for(row)
      row.values_at(*@keys.map { |key| @header.index(key) })
    end

    private

    def find_templates(attributes)
      raise IndexError, "Provide templates or load an index" unless @index

      row = @index.match(attributes)
      raise IndexError, "No template found for attributes: #{attributes.inspect}" unless row

      row.fetch("Template")
    end

    def template_names(templates)
      raise ArgumentError, "templates must be a String or an Array of names" unless templates.is_a?(String) || templates.is_a?(Array)

      names = templates.is_a?(Array) ? templates : templates.split(":", -1)
      raise ArgumentError, "Template list cannot be empty" if names.empty? || names.any? { |name| !name.is_a?(String) || name.strip.empty? }

      names.map(&:strip)
    end

    def expand_command(command)
      command.gsub(/\[\[(.+?)\]\]/) do
        word = Regexp.last_match(1)
        "(#{word.each_char.to_a.join('(')}#{')?' * word.length}"
      end
    end
  end
end
