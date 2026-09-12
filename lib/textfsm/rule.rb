# frozen_string_literal: true

# Ruby port of Google TextFSM rules. Copyright 2010 Google Inc.
# Modified in 2026. Licensed under Apache-2.0; see LICENSE.
require_relative "errors"
require_relative "pattern"

module TextFSM
  class Rule
    LINE_ACTIONS = { "Continue" => :continue, "Next" => :next, "Error" => :error }.freeze
    RECORD_ACTIONS = { "Clear" => :clear, "Clearall" => :clear_all, "Record" => :record, "NoRecord" => :no_record }.freeze
    OPERATIONS = (LINE_ACTIONS.keys + RECORD_ACTIONS.keys).freeze
    TARGET = '(?:[\p{L}\p{N}_]+|".*")'
    ACTION = /\A\s+(?<line>Continue|Next|Error)(?:\.(?<record>Clear|Clearall|Record|NoRecord))?(?:\s+(?<target>#{TARGET}))?\z/
    RECORD_ACTION = /\A\s+(?<record>Clear|Clearall|Record|NoRecord)(?:\s+(?<target>#{TARGET}))?\z/
    STATE_ACTION = /\A(?:\s+(?<target>#{TARGET}))?\z/
    private_constant :LINE_ACTIONS, :RECORD_ACTIONS, :TARGET, :ACTION, :RECORD_ACTION, :STATE_ACTION

    attr_reader :source, :pattern, :line_number, :line_action, :record_action, :next_state, :error_message

    def initialize(line, line_number:, fields:)
      @line_number = line_number
      @line_action = :next
      @record_action = :no_record
      @next_state = @error_message = nil
      @action_source = ""
      line = line.strip
      action = /\A(.*)\s->(.*)\z/.match(line)
      @source = (action ? action[1] : line).freeze
      @pattern = Pattern.new(substitute(@source, fields))
      parse_action(action[2]) if action
      freeze
    rescue TemplateError => e
      raise TemplateError, "#{e.message}. Line: #{@line_number}."
    end

    def to_s
      "  #{@source}#{" -> #{@action_source}" unless @action_source.empty?}"
    end

    private

    def substitute(text, fields)
      text.gsub(/\$(?:\$|\{[a-zA-Z_][a-zA-Z_0-9]*\}|[a-zA-Z_][a-zA-Z_0-9]*|)/) do |token|
        next "$" if token == "$$"

        name = token[1] == "{" ? token[2...-1] : token[1..]
        fields.fetch(name) { raise TemplateError, "Invalid variable substitution #{token.inspect}" }.capture_source
      end
    end

    def parse_action(action)
      match = ACTION.match(action) || RECORD_ACTION.match(action) || STATE_ACTION.match(action)
      raise TemplateError, "Badly formatted rule action #{action.inspect}" unless match

      parts = match.named_captures
      @line_action = LINE_ACTIONS.fetch(parts["line"], :next)
      @record_action = RECORD_ACTIONS.fetch(parts["record"], :no_record)
      target = parts["target"]&.freeze
      raise TemplateError, "Continue cannot specify a new state" if @line_action == :continue && target
      raise TemplateError, "Only Error can specify a quoted message" if @line_action != :error && target&.start_with?('"')

      if @line_action == :error
        @error_message = target
      else
        @next_state = target
      end
      operation = [parts["line"], parts["record"]].compact.join(".")
      @action_source = [operation, target].compact.reject(&:empty?).join(" ").freeze
    end
  end
end
