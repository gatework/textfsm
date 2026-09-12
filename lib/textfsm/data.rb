# frozen_string_literal: true

module TextFSM
  # Records contain nested lists and named captures. Every ownership boundary
  # copies these values; callers can request an immutable result snapshot.
  module Data
    def self.copy(value, immutable: false)
      result = case value
               when Array
                 value.map { |item| copy(item, immutable: immutable) }
               when Hash
                 value.to_h do |key, item|
                   [copy(key, immutable: immutable), copy(item, immutable: immutable)]
                 end
               else
                 value.dup
               end
      immutable ? result.freeze : result
    end
  end

  private_constant :Data
end
