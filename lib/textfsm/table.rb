# frozen_string_literal: true

require_relative "data"

module TextFSM
  class Table
    include Enumerable

    attr_reader :header, :rows

    def initialize(header = [], rows = [])
      raise ArgumentError, "Header and rows must be Arrays" unless header.is_a?(Array) && rows.is_a?(Array) && rows.all?(Array)
      raise ArgumentError, "Duplicate table columns" unless header.uniq == header
      raise ArgumentError, "Rows must have one value per column" unless rows.all? { |row| row.size == header.size }

      @header = Data.copy(header, immutable: true)
      @rows = Data.copy(rows, immutable: true)
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

    def to_a
      Data.copy(@rows)
    end

    def to_hashes
      to_a.map { |row| @header.zip(row).to_h }
    end

    def to_s
      ([@header] + @rows).map { |row| "#{row.join(', ')}\n" }.join
    end

    # 保留左表行，添加新列，并使用首条匹配的右表行。
    # 无键时按位置合并；缺少匹配时填入空值。
    def merge(other, keys: [])
      dup.merge!(other, keys: keys)
    end

    def merge!(other, keys: [])
      missing = (keys - @header) | (keys - other.header)
      raise KeyError, "Unknown key columns: #{missing.join(', ')}" unless missing.empty?

      columns = other.header - @header
      return self if columns.empty?

      right_columns = columns.map { |column| other.header.index(column) }
      left_keys = keys.map { |key| @header.index(key) }
      right_keys = keys.map { |key| other.header.index(key) }
      lookup = {}
      unless keys.empty?
        other.each do |row|
          lookup[row.values_at(*right_keys)] ||= row
        end
      end
      # 同一右行可能匹配多个左行；新增单元格的冻结快照只需准备一次。
      additions = {}.compare_by_identity unless keys.empty?
      rows = @rows.each_with_index.map do |row, index|
        right = keys.empty? ? other[index] : lookup[row.values_at(*left_keys)]
        extra = additional_values(right, right_columns, additions)
        # 已有单元格不可变，只需为新增值取得独立快照。
        (row + extra).freeze
      end
      header = (@header + Data.copy(columns, immutable: true)).freeze
      @header = header
      @rows = rows.freeze
      self
    end

    def sort!(&)
      @rows = @rows.sort(&).freeze
      self
    end

    def sort_by!(&)
      return enum_for(__method__) { size } unless block_given?

      @rows = @rows.sort_by(&).freeze
      self
    end

    private

    def additional_values(row, columns, cache)
      return Array.new(columns.size, "") unless row
      return cache[row] if cache&.key?(row)

      values = Data.copy(row.values_at(*columns), immutable: true)
      cache[row] = values if cache
      values
    end
  end
end
