# frozen_string_literal: true

# Ruby port of Google TextFSM parser. Copyright 2010 Google Inc.
# Modified in 2026. Licensed under Apache-2.0; see LICENSE.
require_relative "field"
require_relative "rule"
require_relative "data"

module TextFSM
  class Parser
    LINE_SEPARATOR = /\r\n|[\n\r\v\f\x1c-\x1e\u0085\u2028\u2029]/
    private_constant :LINE_SEPARATOR

    attr_reader :header, :states, :current_state

    def initialize(template, options: {})
      @states = {}
      @fields = {}
      @option_types = Options::BUILTINS.merge(options.transform_keys(&:to_s)).freeze
      @option_types.each_value do |type|
        raise ArgumentError, "options must inherit from TextFSM::Options::Base" unless type.is_a?(Class) && type < Options::Base
      end
      parse_template(read_template(template))
      @fields.freeze
      @states.each_value(&:freeze)
      @states.freeze
      @output_fields = @fields.each_value.select(&:visible?).freeze
      @header = @output_fields.map(&:name).freeze
      reset
    end

    def self.from_file(path, **options)
      new(File.read(path, encoding: "UTF-8"), **options)
    end

    def state_names
      @states.keys
    end

    def rows
      @rows.dup.freeze
    end

    def to_a
      Data.copy(@rows)
    end

    def to_hashes
      to_a.map { |row| @header.zip(row).to_h }
    end

    def reset
      @current_state = "Start"
      @rows = []
      @fields.each_value(&:reset)
      self
    end

    # Calls accumulate state until reset. Chunks must end on a line boundary;
    # eof: false defers the implicit final Record. Results are frozen snapshots.
    def parse(text, eof: true)
      consume_input(text, eof: eof)
      rows
    end

    def parse_hashes(text, eof: true)
      consume_input(text, eof: eof)
      to_hashes
    end

    def fields_with_option(name)
      name = name.to_s
      raise ArgumentError, "Unknown option #{name.inspect}" unless @option_types.key?(name)

      @fields.each_value.filter_map { |field| field.name if field.option?(name) }
    end

    # Option callbacks use the same visible-column mapping as record output.
    def fill_up(field)
      column = @output_fields.index(field)
      return unless column

      (@rows.length - 1).downto(0) do |index|
        row = @rows[index]
        value = row[column]
        break if value && !(value.respond_to?(:empty?) && value.empty?)

        # Records are immutable so earlier snapshots can safely share them.
        replacement = row.dup
        replacement[column] = Data.copy(field.value, immutable: true)
        @rows[index] = replacement.freeze
      end
    end

    def to_s
      output = "#{@fields.values.join("\n")}\n"
      @states.each do |state, rules|
        output << "\n#{state}\n"
        rules.each do |rule|
          output << "#{rule}\n"
        end
      end
      output
    end

    private

    def terminal?
      @current_state == "End" || @current_state == "EOF"
    end

    def consume_input(text, eof:)
      return if terminal?

      text = text.read if text.respond_to?(:read)
      raise ArgumentError, "text must be a String or readable IO" unless text.is_a?(String)

      # StringScanner advances by bytes, including for multibyte input, without
      # allocating all lines or repeatedly finding character offsets.
      scanner = StringScanner.new(text)
      while (line = scanner.scan_until(LINE_SEPARATOR))
        process_line(line.byteslice(0, line.bytesize - scanner.matched_size))
        break if terminal?
      end
      process_line(scanner.rest) unless terminal? || scanner.eos?
      append_record if eof && @current_state != "End" && !@states.key?("EOF")
    end

    def read_template(template)
      template = template.read if template.respond_to?(:read)
      raise TemplateError, "Template must be a String or readable IO" unless template.is_a?(String)

      template
    end

    def parse_template(template)
      reading_fields = true
      state = nil
      template.each_line.with_index(1) do |raw, line_number|
        line = raw.rstrip
        next if line.lstrip.start_with?("#")

        if line.empty?
          reading_fields = false
          state = nil
        elsif reading_fields
          parse_field(line, line_number)
        elsif state.nil?
          state = parse_state(line, line_number)
        else
          raise TemplateError, "Missing whitespace or '^' before rule. Line: #{line_number}." unless line.start_with?(" ^", "  ^", "\t^")

          @states.fetch(state) << Rule.new(line, line_number: line_number, fields: @fields)
        end
      end
      validate_states
    end

    def parse_field(line, line_number)
      unless line.start_with?("Value ")
        message = @fields.empty? ? "No Value definitions found" : "Expected blank line after last Value entry"
        raise TemplateError, message
      end
      field = Field.new(line, parser: self, options: @option_types)
      raise TemplateError, "Duplicate Value #{field.name.inspect}" if @fields.key?(field.name)

      @fields[field.name] = field
    rescue TemplateError => e
      raise TemplateError, "#{e.message}. Line: #{line_number}."
    end

    def parse_state(line, line_number)
      if !line.match?(/\A[\p{L}\p{N}_]+\z/) || line.length > 48 || Rule::OPERATIONS.include?(line)
        raise TemplateError, "Invalid state name #{line.inspect}. Line: #{line_number}."
      end
      raise TemplateError, "Duplicate state #{line.inspect}. Line: #{line_number}." if @states.key?(line)

      @states[line.freeze] = []
      line
    end

    def validate_states
      raise TemplateError, "Missing state 'Start'." unless @states.key?("Start")

      %w[End EOF].each do |state|
        raise TemplateError, "Non-empty '#{state}' state." if @states.key?(state) && !@states[state].empty?
      end
      @states.delete("End")
      @states.each do |state, rules|
        rules.each do |rule|
          next if rule.line_action == :error || rule.next_state.nil? || %w[End EOF].include?(rule.next_state)
          next if @states.key?(rule.next_state)

          raise TemplateError, "State #{rule.next_state.inspect} not found, referenced in #{state.inspect}. Line: #{rule.line_number}."
        end
      end
    end

    def process_line(line)
      @states.fetch(@current_state).each do |rule|
        match = rule.pattern.match(line)
        next unless match

        rule.pattern.named_captures(match).each do |name, value|
          @fields[name]&.assign(value)
        end
        case rule.record_action
        when :record
          append_record
        when :clear
          @fields.each_value(&:clear)
        when :clear_all
          @fields.each_value(&:reset)
        end
        if rule.line_action == :error
          message = rule.error_message ? "Error: #{rule.error_message}" : "State Error raised"
          raise ParseError, "#{message}. Rule Line: #{rule.line_number}. Input Line: #{line}."
        end
        next if rule.line_action == :continue

        @current_state = rule.next_state if rule.next_state
        break
      end
    end

    def append_record
      catch(:skip_record) do
        @fields.each_value(&:prepare_record)
        record = @output_fields.map(&:value)
        unless record.all? { |value| value.nil? || value == [] }
          @rows << record.map! { |value| Data.copy(value.nil? ? "" : value, immutable: true) }.freeze
        end
      end
      @fields.each_value(&:clear)
    end
  end
end
