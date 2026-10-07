# frozen_string_literal: true

module TextFSM
  # Records contain nested lists and named captures. Every ownership boundary
  # copies these values; callers can request an immutable result snapshot.
  module Data
    def self.copy(value, immutable: false)
      # 只有整个值树都不可变时才共享，冻结外层容器并不代表成员已冻结。
      return value if immutable && immutable?(value)

      result = case value
               when Array
                 value.map { |item| copy(item, immutable: immutable) }
               when Hash
                 value.to_h do |key, item|
                   [copy(key, immutable: immutable), copy(item, immutable: immutable)]
                 end
               when Struct
                 value.dup.tap do |record|
                   value.each_pair { |name, item| record[name] = copy(item, immutable: immutable) }
                 end
               when String, Integer, Float, Rational, Complex, Symbol, NilClass, TrueClass, FalseClass
                 value.dup
               else
                 raise TypeError, "Unsupported record value type: #{value.class}"
               end
      immutable ? result.freeze : result
    end

    def self.immutable?(value)
      return false unless value.frozen?

      case value
      when Array
        value.instance_of?(Array) && value.all? { |item| immutable?(item) }
      when Hash
        value.instance_of?(Hash) && !value.compare_by_identity? && value.default.nil? && value.default_proc.nil? &&
          value.all? { |key, item| immutable?(key) && immutable?(item) }
      when Struct
        value.all? { |item| immutable?(item) }
      when String, Integer, Float, Rational, Complex, Symbol, NilClass, TrueClass, FalseClass
        true
      else
        false
      end
    end
    private_class_method :immutable?
  end

  private_constant :Data
end
