# frozen_string_literal: true

# Ruby port of Google TextFSM index matching. Copyright 2022 Google Inc.
# Modified in 2026. Licensed under Apache-2.0; see LICENSE.
require_relative "errors"
require_relative "pattern"
require_relative "data"

module TextFSM
  class IndexTable
    include Enumerable

    # 转换结果仅属于当前查询；通配条件或未使用的属性不会触发转换。
    Attribute = Struct.new(:name, :value) do
      def text
        @text ||= value.to_s
      end
    end
    private_constant :Attribute

    attr_reader :header

    def initialize(path, transform: nil, compile: nil)
      @header, @rows = Data.copy(read_table(path, transform), immutable: true)
      @patterns = @rows.map do |row|
        row.to_h do |key, value|
          value = compile.call(key, value) if compile
          [key, value.nil? || value.empty? ? nil : Pattern.new(value)]
        end.freeze
      end.freeze
      freeze
    rescue TemplateError => e
      raise IndexError, "#{path}: #{e.message}"
    end

    def each(&)
      return enum_for(__method__) { size } unless block_given?

      @rows.each(&)
      self
    end

    def size
      @rows.size
    end

    def empty?
      @rows.empty?
    end

    def [](index)
      @rows[index]
    end

    # Empty cells are wildcards. Attributes absent from the index are ignored.
    def match(attributes)
      attributes = attributes.filter_map do |key, value|
        name = key.to_s
        Attribute.new(name, value) if @header.include?(name)
      end
      index = @patterns.index do |patterns|
        attributes.all? do |attribute|
          pattern = patterns[attribute.name]
          pattern.nil? || pattern.match?(attribute.text)
        end
      end
      @rows[index] if index
    end

    private

    def read_table(path, transform)
      lines = File.foreach(path, encoding: "UTF-8")
      header = nil
      rows = []
      lines.with_index(1) do |raw, line_number|
        raise IndexError, "#{path}: Invalid UTF-8 at line #{line_number}" unless raw.valid_encoding?

        line = raw.strip
        next if line.empty? || line.start_with?("#")

        line = line.split("#", 2).first.rstrip unless header

        fields = line.split(",", -1).map(&:strip)
        unless header
          header = fields
          raise IndexError, "Duplicate index header" unless header.uniq == header

          next
        end
        next unless fields.size == header.size

        row = header.zip(fields).to_h
        row = row.to_h { |key, value| [key, transform.call(key, value)] } if transform
        rows << row
      end
      raise IndexError, "Missing index header" unless header

      [header, rows]
    end
  end
end
