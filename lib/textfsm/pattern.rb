# frozen_string_literal: true

require "strscan"
require_relative "errors"

module TextFSM
  # Compile Python-style template patterns into immutable Ruby matchers.
  class Pattern
    attr_reader :source, :regexp, :names

    def initialize(source)
      raise ArgumentError, "pattern must be a String" unless source.is_a?(String)

      @source = source.dup.freeze
      expression, @group_names = Compiler.new(@source).compile
      @regexp = Regexp.new("\\A(?:#{expression})").freeze
      @names = @group_names.keys.freeze
      freeze
    rescue RegexpError, ArgumentError, RangeError, EncodingError => e
      raise TemplateError, "Invalid regular expression #{source.inspect}: #{e.message}"
    end

    def match(text)
      @regexp.match(text)
    end

    def match?(text)
      @regexp.match?(text)
    end

    def named_captures(match)
      @group_names.transform_values { |internal_name| match[internal_name] }
    end

    # 解析器逐项消费命名捕获，避免每条匹配规则都构造临时 Hash。
    def each_capture(match)
      return enum_for(__method__, match) { @group_names.size } unless block_given?

      @group_names.each do |name, internal_name|
        yield name, match[internal_name]
      end
      self
    end

    # Ruby drops unnamed captures when named captures are present. Giving every
    # capture an internal name preserves Python's numeric backreferences.
    class Compiler
      ASSERTIONS = %w[A Z z b B].freeze
      CHARACTER_CLASSES = { "d" => "\\p{Nd}", "w" => "\\p{L}\\p{N}_", "s" => "\\p{Space}\\x1c-\\x1f" }.freeze
      FLAG_NAMES = { "m" => :multiline, "s" => :dotall, "x" => :extended, "a" => :ascii }.freeze

      def initialize(source)
        @scanner = StringScanner.new(source)
        @output = []
        @group_names = {}
        @captures = []
        @groups = []
        @flags = { multiline: false, dotall: false, extended: false, ascii: false }
        @has_expression = false
        @atom_start = nil
        @repeatable = false
        @quantified = false
      end

      def compile
        until @scanner.eos?
          character = @scanner.getch
          next if @flags[:extended] && character.match?(/[ \t\n\r\f\v]/)

          compile_token(character)
        end
        raise ArgumentError, "unbalanced parenthesis" unless @groups.empty?

        [@output.join, @group_names.freeze]
      end

      private

      def compile_token(character)
        case character
        when "\\"
          assertion = ASSERTIONS.include?(@scanner.peek(1))
          emit_atom(escape(in_class: false), repeatable: !assertion)
        when "[" then emit_atom(character_class)
        when "(" then open_group
        when ")" then close_group
        when "^", "$" then emit_atom(anchor(character), repeatable: false)
        when "." then emit_atom(@flags[:dotall] ? "(?m:.)" : ".")
        when "|"
          @output << character
          @atom_start = nil
          @has_expression = true
        when "*", "+", "?" then quantifier(character)
        when "{"
          count = @scanner.scan(/(?:\d+(?:,\d*)?|,\d*)\}/)
          count ? quantifier("{#{count}") : emit_atom("\\{")
        when "#"
          @flags[:extended] ? @scanner.skip(/[^\n]*/) : emit_atom("\\#")
        else emit_atom(Regexp.escape(character))
        end
      end

      def emit_atom(expression, repeatable: true)
        @atom_start = @output.length
        @repeatable = repeatable
        @quantified = false
        @has_expression = true
        @output << expression
      end

      def anchor(character)
        return character if @flags[:multiline]

        character == "^" ? "\\A" : "\\Z"
      end

      def quantifier(expression)
        raise ArgumentError, "nothing to repeat" unless @atom_start && @repeatable
        raise ArgumentError, "multiple repeat" if @quantified

        expression = counted_quantifier(expression) if expression.start_with?("{")
        modifier = @scanner.scan(/[?+]/)
        if modifier == "+"
          atom = @output.slice!(@atom_start..).join
          @output << "(?>#{atom}#{expression})"
        else
          @output << expression
          @output << modifier if modifier
        end
        @quantified = true
      end

      def counted_quantifier(expression)
        minimum, maximum = expression[1...-1].split(",", -1)
        minimum = minimum.empty? ? 0 : Integer(minimum, 10)
        maximum = if maximum.nil?
                    minimum
                  elsif !maximum.empty?
                    Integer(maximum, 10)
                  end
        raise ArgumentError, "minimum repeat exceeds maximum" if maximum && minimum > maximum

        # Ruby treats {n}? as an optional n-character block. An explicit range
        # retains Python's required count when the lazy suffix is appended.
        "{#{minimum},#{maximum}}"
      end

      def escape(in_class:)
        character = @scanner.getch
        raise ArgumentError, "trailing backslash" unless character

        return octal(character + @scanner.scan(/[0-7]{0,2}/)) if character == "0" || (in_class && character.match?(/[0-7]/))
        raise ArgumentError, "invalid character class escape \\#{character}" if in_class && %w[A B Z z 8 9].include?(character)
        return numeric_reference(character) if !in_class && character.match?(/[1-9]/)
        return "\\z" if !in_class && %w[Z z].include?(character)
        return word_boundary(character) if !in_class && %w[b B].include?(character)
        return unicode_escape(character) if %w[x u U].include?(character)

        character_class_escape(character, in_class: in_class) || literal_escape(character)
      end

      def character_class_escape(character, in_class:)
        return if @flags[:ascii]

        if (body = CHARACTER_CLASSES[character.downcase])
          return body if in_class && character == character.downcase

          "[#{'^' if character == character.upcase}#{body}]"
        end
      end

      def literal_escape(character)
        raise ArgumentError, "\\N is not supported; use literal Unicode characters" if character == "N"
        if character.match?(/[A-Za-z]/) && !"AbBdDsSwWZzfnrtvuxUa".include?(character)
          raise ArgumentError, "unsupported escape \\#{character}"
        end

        "\\#{character}"
      end

      def numeric_reference(character)
        digits = character + @scanner.scan(/[0-9]?/)
        if digits.match?(/\A[0-7]{2}\z/) && (last_digit = @scanner.scan(/[0-7]/))
          return octal(digits + last_digit)
        end

        internal_name = @captures[digits.to_i - 1]
        raise ArgumentError, "invalid group reference #{digits}" unless internal_name

        backreference(internal_name)
      end

      def backreference(internal_name)
        raise ArgumentError, "cannot refer to an open group" if @groups.any? { |group| group[:capture] == internal_name }

        "\\k<#{internal_name}>"
      end

      def word_boundary(character)
        word = @flags[:ascii] ? "[a-zA-Z0-9_]" : "[\\p{L}\\p{N}_]"
        boundary = "(?:(?<!#{word})(?=#{word})|(?<=#{word})(?!#{word}))"
        character == "b" ? boundary : "(?!#{boundary})"
      end

      def unicode_escape(character)
        length = { "x" => 2, "u" => 4, "U" => 8 }.fetch(character)
        digits = @scanner.scan(/[0-9a-fA-F]{#{length}}/)
        raise ArgumentError, "incomplete Unicode or hexadecimal escape" unless digits

        Regexp.escape(digits.to_i(16).chr(Encoding::UTF_8))
      end

      def octal(digits)
        codepoint = digits.to_i(8)
        raise ArgumentError, "octal escape outside range 0-0o377" if codepoint > 255

        Regexp.escape(codepoint.chr(Encoding::UTF_8))
      end

      def character_class
        expression = +"["
        expression << @scanner.getch if @scanner.peek(1) == "^"
        first = true
        until @scanner.eos?
          character = @scanner.getch
          return "#{expression}]" if character == "]" && !first

          first = false
          atom, literal = class_atom(character)
          if @scanner.peek(1) == "-" && @scanner.peek(2) != "-]"
            @scanner.getch
            ending, end_literal = class_atom(@scanner.getch)
            raise ArgumentError, "bad character range: endpoints must be single characters" unless literal && end_literal

            atom = "#{atom}-#{ending}"
          end
          expression << atom
        end
        raise ArgumentError, "unterminated character class"
      end

      def class_atom(character)
        raise ArgumentError, "unterminated character class" unless character
        return ["\\&", true] if character == "&"
        return [Regexp.escape(character), true] unless character == "\\"

        literal = !@scanner.peek(1).match?(/[dDsSwW]/)
        [escape(in_class: true), literal]
      end

      def open_group
        return capture unless @scanner.scan(/\?/)

        if @scanner.scan(/P<([^>]+)>/)
          name = @scanner[1]
          unless name.match?(/\A[\p{L}_][\p{L}\p{N}_]*\z/) && !@group_names.key?(name)
            raise ArgumentError, "invalid or duplicate group name #{name.inspect}"
          end

          return capture(name.freeze)
        end
        if @scanner.scan(/P=([^)]*)\)/)
          name = @scanner[1]
          internal_name = @group_names[name]
          raise ArgumentError, "unknown group name #{name.inspect}" unless internal_name

          return emit_atom(backreference(internal_name))
        end
        return if @scanner.skip(/#(?:\\.|[^)])*\)/)
        return inline_flags if @scanner.scan(/([aimsux]*)(?:-([imsx]+))?([:)])/)
        if (extension = @scanner.scan(/<=|<!|=|!|>/))
          return push_group("(?#{extension}")
        end

        raise ArgumentError, "unsupported group extension at byte offset #{@scanner.pos - 2}"
      end

      def capture(name = nil)
        internal_name = "tfsm_capture_#{@captures.length + 1}".freeze
        @captures << internal_name
        @group_names[name] = internal_name if name
        push_group("(?<#{internal_name}>", capture: internal_name)
      end

      def push_group(expression, capture: nil)
        @groups << { flags: @flags.dup, start: @output.length, capture: capture }
        @output << expression
        @atom_start = nil
        @has_expression = true
      end

      def close_group
        group = @groups.pop
        raise ArgumentError, "unbalanced parenthesis" unless group

        @flags = group[:flags]
        @output << ")"
        @atom_start = group[:start]
        @repeatable = true
        @quantified = false
      end

      def inline_flags
        enabled = @scanner[1]
        disabled = @scanner[2]
        ending = @scanner[3]
        validate_flags(enabled, disabled, ending)

        ruby_on = enabled.delete("amsu")
        ruby_off = disabled.to_s.delete("ms")
        flags = ruby_on + (ruby_off.empty? ? "" : "-#{ruby_off}")
        if ending == ":"
          push_group("(?#{flags}:")
        elsif !flags.empty?
          @output << "(?#{flags})"
        end
        enabled.each_char do |flag|
          @flags[FLAG_NAMES[flag]] = true if FLAG_NAMES.key?(flag)
        end
        disabled.to_s.each_char do |flag|
          @flags[FLAG_NAMES[flag]] = false if FLAG_NAMES.key?(flag)
        end
        @flags[:ascii] = false if enabled.include?("u")
      end

      def validate_flags(enabled, disabled, ending)
        if (enabled.include?("a") && enabled.include?("u")) || enabled.each_char.any? { |flag| disabled.to_s.include?(flag) }
          raise ArgumentError, "incompatible inline flags"
        end
        return unless ending == ")"

        raise ArgumentError, "global flags must occur at the start of the expression" if @has_expression || enabled.empty? || disabled

        character_mode = enabled[/[au]/]
        return unless character_mode

        raise ArgumentError, "incompatible global character flags" if @global_character_mode && @global_character_mode != character_mode

        @global_character_mode = character_mode
      end
    end

    private_constant :Compiler
  end
end
