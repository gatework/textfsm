# frozen_string_literal: true

# Ruby port of Google TextFSM options. Copyright 2010 Google Inc.
# Modified in 2026. Licensed under Apache-2.0; see LICENSE.
module TextFSM
  module Options
    class Base
      attr_reader :field

      def initialize(field)
        @field = field
      end

      def after_initialize
      end

      def after_assign
      end

      def after_clear
      end

      def after_reset
      end

      def before_record
      end

      def visible?
        true
      end
    end

    class Required < Base
      def before_record
        throw :skip_record if field.empty?
      end
    end

    class Filldown < Base
      def after_assign
        @saved_value = field.value
      end

      def after_clear
        field.value = @saved_value
      end

      def after_reset
        @saved_value = nil
      end
    end

    class Fillup < Base
      def after_assign
        field.parser.fill_up(field) unless field.empty?
      end
    end

    class Key < Base; end

    class List < Base
      def after_initialize
        @items = []
      end

      def after_assign
        match = field.pattern.match(field.value) if field.value && !field.pattern.names.empty?
        @items << (match ? field.pattern.named_captures(match) : field.value)
      end

      def after_clear
        @items = [] unless field.option?("Filldown")
      end

      def after_reset
        @items = []
      end

      def before_record
        field.value = @items.dup
      end
    end

    BUILTINS = {
      "Required" => Required,
      "Filldown" => Filldown,
      "Fillup" => Fillup,
      "List" => List,
      "Key" => Key
    }.freeze
  end
end
