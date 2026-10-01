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

    # Keep left rows, add new columns, and use the first matching right row.
    # Without keys, align by position. Missing matches receive empty values.
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
      rows = @rows.each_with_index.map do |row, index|
        right = keys.empty? ? other[index] : lookup[row.values_at(*left_keys)]
        extra = right ? Data.copy(right.values_at(*right_columns), immutable: true) : Array.new(columns.size, "")
        # Existing cells are immutable; only incoming values need an owned copy.
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
  end
end
