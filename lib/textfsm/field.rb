# frozen_string_literal: true

# Ruby port of Google TextFSM values. Copyright 2010 Google Inc.
# Modified in 2026. Licensed under Apache-2.0; see LICENSE.
require_relative "errors"
require_relative "options"
require_relative "pattern"

module TextFSM
  class Field
    attr_reader :parser, :name, :source, :capture_source, :option_names, :pattern
    attr_accessor :value

    def initialize(line, parser:, options: Options::BUILTINS)
      @parser = parser
      parse_declaration(line)
      @pattern = Pattern.new(@source)
      @capture_source = "(?P<#{@name}>#{@source[1..]}".freeze
      @options = @option_names.map do |name|
        options.fetch(name) { raise TemplateError, "Unknown option #{name.inspect}" }.new(self)
      end.freeze
      @options.each(&:after_initialize)
    end

    def option?(name)
      @option_names.include?(name)
    end

    def visible?
      @options.all?(&:visible?)
    end

    def empty?
      !@value || (@value.respond_to?(:empty?) && @value.empty?)
    end

    def assign(value)
      @value = value
      @options.each(&:after_assign)
    end

    def clear
      @value = nil
      @options.each(&:after_clear)
    end

    def reset
      @value = nil
      @options.each(&:after_reset)
    end

    def prepare_record
      @options.each(&:before_record)
    end

    def to_s
      ["Value", (@option_names.join(",") unless @option_names.empty?), @name, @source].compact.join(" ")
    end

    private

    def parse_declaration(line)
      # The template grammar splits on literal spaces, including empty fields.
      tokens = line.split(/ /, -1)
      raise TemplateError, "Expect at least 3 tokens in Value declaration" if tokens.length < 3

      if tokens[2].start_with?("(")
        @name = tokens[1].freeze
        @source = tokens[2..].join(" ").freeze
        @option_names = [].freeze
      else
        @name = tokens[2].freeze
        @source = tokens[3..].join(" ").freeze
        @option_names = tokens[1].split(",", -1).map(&:freeze).freeze
      end
      raise TemplateError, "Invalid Value name #{@name.inspect}" unless @name.match?(/\A[a-zA-Z_][a-zA-Z_0-9]*\z/) && @name.length <= 48
      raise TemplateError, "Duplicate option" if @option_names.uniq != @option_names
      return if @source.start_with?("(") && @source.end_with?(")")

      raise TemplateError, "Value #{@source.inspect} must be contained within a '()' pair"
    end
  end
end
