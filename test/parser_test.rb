# frozen_string_literal: true

require_relative "test_helper"

class ParserTest < Minitest::Test
  SIMPLE = "Value X (.*)\n\nStart\n  ^${X} -> Record\n"

  Person = Struct.new(:name)

  class AsPerson < TextFSM::Options::Base
    def after_assign
      field.value = Person.new(field.value)
    end
  end

  def test_struct_snapshots_and_exports_cannot_change_filldown_state
    template = <<~'FSM'
      Value AsPerson,Filldown PERSON (\w+)
      Value Required ID (\d+)

      Start
        ^person ${PERSON}
        ^id ${ID} -> Record
    FSM
    parser = TextFSM::Parser.new(template, options: { AsPerson: AsPerson })
    snapshot = parser.parse("person Alice\nid 1\n", eof: false)
    parser.to_a[0][0].name.replace("changed")

    assert_equal "Alice", snapshot[0][0].name
    assert_raises(FrozenError) { snapshot[0][0].name.replace("changed") }
    assert_equal "Alice", parser.parse("id 2\n", eof: false).last[0].name
  end

  def test_feed_returns_the_parser_and_defers_the_final_record_by_default
    parser = TextFSM::Parser.new("Value X (.*)\n\nStart\n  ^${X}\n")

    assert_same parser, parser.feed(StringIO.new("first\n"))
    assert_empty parser.rows
    assert_same parser, parser.feed("last\n", eof: true)
    assert_equal [["last"]], parser.rows
    assert_raises(ArgumentError) { parser.feed(nil) }
  end

  def test_feed_preserves_previous_snapshots_during_fillup_and_reset
    template = "Value Fillup X (.*)\nValue Required ID (\\d+)\n\nStart\n  ^id ${ID} -> Record\n  ^x ${X}\n"
    parser = TextFSM::Parser.new(template)
    snapshot = parser.feed("id 1\n").rows
    parser.feed("x filled\n").feed("id 2\n")

    assert_equal [["", "1"]], snapshot
    assert_equal [%w[filled 1], %w[filled 2]], parser.rows
    latest = parser.rows
    parser.reset.feed("id 3\n")
    assert_equal [["", "3"]], parser.rows
    assert_equal [%w[filled 1], %w[filled 2]], latest
  end

  def test_feed_keeps_terminal_states_until_reset
    parser = TextFSM::Parser.new("Value X (.*)\n\nStart\n  ^${X} -> Record End\n")
    parser.feed("one\ntwo\n")
    input = StringIO.new("three\n")
    parser.feed(input, eof: true)

    assert_equal [["one"]], parser.rows
    assert_equal 0, input.pos
    assert_equal [["four"]], parser.reset.feed("four\n").rows
  end

  def test_arrays_hashes_and_io
    fsm = TextFSM::Parser.new(StringIO.new(SIMPLE))
    assert_equal ["X"], fsm.header
    assert_equal [["hello"], ["world"]], fsm.parse(StringIO.new("hello\nworld\n"))
    fsm.reset
    assert_equal [{ "X" => "中文" }], fsm.parse_hashes("中文")
  end

  def test_template_io_is_consumed_without_rewinding
    handle = StringIO.new(SIMPLE)
    assert_equal ["X"], TextFSM::Parser.new(handle).header
    assert_equal handle.size, handle.pos
    handle.rewind
    assert_equal ["X"], TextFSM::Parser.new(handle).header
    bad = StringIO.new("invalid")
    assert_raises(TextFSM::TemplateError) do
      TextFSM::Parser.new(bad)
    end
    assert_equal bad.size, bad.pos
  end

  def test_chunks_retain_values_until_eof
    fsm = TextFSM::Parser.new("Value X (.*)\n\nStart\n  ^${X}\n")
    assert_equal [], fsm.parse("first\n", eof: false)
    assert_equal [["last"]], fsm.parse("last\n")
    assert_equal [["last"]], fsm.parse("")
  end

  def test_empty_lines_are_records_but_empty_input_is_not
    fsm = TextFSM::Parser.new(SIMPLE)
    assert_empty fsm.parse("")
    assert_equal [[""]], fsm.parse("\n")
    fsm.reset
    assert_equal [["a"], [""]], fsm.parse("a\n\n")
  end

  def test_python_line_separators
    fsm = TextFSM::Parser.new(SIMPLE)
    assert_equal %w[a b c d e f g h i j k].map { |v| [v] },
                 fsm.parse("a\r\nb\rc\vd\fe\x1cf\x1dg\x1eh\u0085i\u2028j\u2029k\n")
  end

  def test_multibyte_lines_keep_empty_records_and_unterminated_tails
    parser = TextFSM::Parser.new(SIMPLE)
    separators = ["\n", "\r\n", "\r", "\v", "\f", "\x1c", "\x1d", "\x1e", "\u0085", "\u2028", "\u2029"]
    separators.each do |separator|
      text = "中文😀#{separator}#{separator}末尾".freeze
      expected = [["中文😀"], [""], ["末尾"]]

      assert_equal expected, parser.reset.parse(text), separator.inspect
      assert_equal expected, parser.reset.parse("#{text}#{separator}"), separator.inspect
      assert_equal [[""]], parser.reset.parse(separator), separator.inspect
    end
    snapshot = parser.reset.feed("先頭\r\n").rows
    assert_equal [["先頭"], [""], ["末尾"]], parser.feed("\u2028末尾", eof: true).rows
    assert_equal [["先頭"]], snapshot
  end

  def test_end_remains_terminal_until_reset
    fsm = TextFSM::Parser.new("Value X (.*)\n\nStart\n  ^${X} -> Record End\n")
    assert_equal [["one"]], fsm.parse("one\ntwo")
    assert_equal [["one"]], fsm.parse("three")
    fsm.reset
    assert_equal [["four"]], fsm.parse("four")
  end

  def test_eof_does_not_repeat_a_filldown_record_on_subsequent_calls
    fsm = TextFSM::Parser.new("Value Filldown X (.*)\n\nStart\n  ^${X} -> EOF\n")
    assert_equal [["one"]], fsm.parse("one\ntwo")
    assert_equal [["one"]], fsm.parse("three")
    assert_equal [["one"]], fsm.parse("")
    fsm.reset
    assert_equal [["four"]], fsm.parse("four")
  end

  def test_nested_list_groups_and_optional_values
    template = <<~'FSM'
      Value List PERSON ((?P<name>\w+)(?: (?P<age>\d+))?)
      Value Required ID (\d+)

      Start
        ^person ${PERSON}
        ^id ${ID} -> Record
    FSM
    rows = TextFSM::Parser.new(template).parse("person 王五 32\nperson Alice\nid 1\nid 2")
    assert_equal [[[{ "name" => "王五", "age" => "32" }, { "name" => "Alice", "age" => nil }], "1"], [[], "2"]], rows
  end

  def test_error_reports_template_line_and_input
    fsm = TextFSM::Parser.new("Value X (.*)\n\nStart\n  ^bad -> Error \"unexpected input\"\n")
    error = assert_raises(TextFSM::ParseError) do
      fsm.parse("bad data")
    end
    assert_includes error.message, "Rule Line: 4"
    assert_includes error.message, "unexpected input"
    assert_includes error.message, "bad data"
  end

  INVALID_TEMPLATES = {
    missing_start: "Value X (.*)\n\nBody\n",
    missing_separator: "Value X (.*)\nStart\n",
    duplicate_value: "Value X (.*)\nValue X (.*)\n\nStart\n",
    duplicate_state: "Value X (.*)\n\nStart\n\nStart\n",
    unknown_option: "Value Imaginary X (.*)\n\nStart\n",
    duplicate_option: "Value List,List X (.*)\n\nStart\n",
    missing_regex: "Value Required X\n\nStart\n",
    unwrapped_regex: "Value X .*\n\nStart\n",
    malformed_regex: "Value X ([)\n\nStart\n",
    duplicate_group: "Value X ((?P<a>.)(?P<a>.))\n\nStart\n",
    duplicate_substitution: "Value X (.)\n\nStart\n  ^${X}${X}\n",
    unknown_substitution: "Value X (.)\n\nStart\n  ^${missing}\n",
    unescaped_dollar: "Value X (.)\n\nStart\n  ^${X}$\n",
    invalid_dollar: "Value X (.)\n\nStart\n  ^${X}${}\n",
    missing_caret: "Value X (.)\n\nStart\n  hello\n",
    missing_indent: "Value X (.)\n\nStart\n^hello\n",
    excessive_indent: "Value X (.)\n\nStart\n   ^hello\n",
    unknown_state: "Value X (.)\n\nStart\n  ^hello -> Unknown\n",
    reserved_state: "Value X (.)\n\nStart\n\nRecord\n",
    long_state: "Value X (.)\n\nStart\n\n#{'A' * 49}\n",
    long_value: "Value #{'X' * 49} (.)\n\nStart\n",
    continue_transition: "Value X (.)\n\nStart\n  ^hello -> Continue Start\n",
    malformed_action: "Value X (.)\n\nStart\n  ^hello -> Record.Next\n",
    no_action_space: "Value X (.)\n\nStart\n  ^hello ->Record\n",
    quoted_state: "Value X (.)\n\nStart\n  ^hello -> Next \"Body\"\n",
    nonempty_end: "Value X (.)\n\nStart\n\nEnd\n  ^hello\n",
    nonempty_eof: "Value X (.)\n\nStart\n\nEOF\n  ^hello\n"
  }.freeze

  INVALID_TEMPLATES.each do |name, template|
    define_method("test_rejects_#{name}") do
      assert_raises(TextFSM::TemplateError) do
        TextFSM::Parser.new(template)
      end
    end
  end

  module CustomOptions
    class Uppercase < TextFSM::Options::Base
      def after_assign
        field.value = field.value.upcase
      end
    end

    class Hidden < TextFSM::Options::Base
      def visible?
        false
      end
    end
  end

  def test_custom_option_hooks
    template = "Value Uppercase,Required X (.*)\nValue Hidden Y (.*)\n\nStart\n  ^${X} -> Record\n"
    fsm = TextFSM::Parser.new(template, options: { "Uppercase" => CustomOptions::Uppercase, "Hidden" => CustomOptions::Hidden })
    assert_equal ["X"], fsm.header
    assert_equal [["HELLO"]], fsm.parse("hello")
    assert_equal ["X"], fsm.fields_with_option("Uppercase")
  end

  def test_fillup_uses_visible_columns_when_an_earlier_field_is_hidden
    template = <<~'FSM'
      Value Hidden H (.*)
      Value Fillup X (.*)
      Value Required ID (\d+)

      Start
        ^id ${ID} -> Record
        ^x ${X}
    FSM
    fsm = TextFSM::Parser.new(template, options: { "Uppercase" => CustomOptions::Uppercase, "Hidden" => CustomOptions::Hidden })
    assert_equal [%w[filled 1]], fsm.parse("id 1\nx filled\n")
  end

  def test_snapshots_and_exports_do_not_change_list_filldown_state
    template = <<~'FSM'
      Value List,Filldown PERSON ((?P<name>\w+))
      Value Required ID (\d+)

      Start
        ^person ${PERSON}
        ^id ${ID} -> Record
    FSM
    parser = TextFSM::Parser.new(template)
    snapshot = parser.parse("person Alice\nid 1\nid 2\n")
    assert_raises(FrozenError) do
      snapshot[0][0][0]["name"].replace("changed")
    end
    parser.to_a[0][0][0]["name"].replace("changed")
    parser.to_hashes[0]["PERSON"] << { "name" => "Bob" }

    assert_equal [[[{ "name" => "Alice" }], "1"], [[{ "name" => "Alice" }], "2"]], snapshot
    assert_equal [{ "name" => "Alice" }], parser.parse("id 3\n").last.first
    assert_equal 2, snapshot.size
  end

  def test_fillup_updates_current_results_without_changing_earlier_snapshots
    template = "Value Fillup X (.*)\nValue Required ID (\\d+)\n\nStart\n  ^id ${ID} -> Record\n  ^x ${X}\n"
    parser = TextFSM::Parser.new(template)
    snapshot = parser.parse("id 1\n", eof: false)
    assert_equal [%w[filled 1]], parser.parse("x filled\n")
    assert_equal [["", "1"]], snapshot
  end

  def test_template_metadata_is_immutable_and_reset_keeps_it
    parser = TextFSM::Parser.new(SIMPLE)
    assert_raises(FrozenError) do
      parser.states["Start"].clear
    end
    assert_raises(FrozenError) do
      parser.header.first.replace("Y")
    end
    parser.state_names.clear
    parser.fields_with_option("Key").clear
    assert_equal SIMPLE, parser.to_s
    assert_same parser, parser.reset
    assert_equal ["Start"], parser.state_names
  end

  def test_terminal_parser_does_not_read_another_io
    parser = TextFSM::Parser.new("Value X (.*)\n\nStart\n  ^${X} -> Record End\n")
    parser.parse("first")
    input = StringIO.new("second")
    assert_equal [["first"]], parser.parse(input)
    assert_equal 0, input.pos
  end

  def test_invalid_input_and_option_types_fail_at_the_api_boundary
    [nil, 1, Object.new].each do |input|
      assert_raises(ArgumentError) do
        TextFSM::Parser.new(SIMPLE).parse(input)
      end
      assert_raises(TextFSM::TemplateError) do
        TextFSM::Parser.new(input)
      end
    end
    assert_raises(ArgumentError) do
      TextFSM::Parser.new(SIMPLE, options: { Uppercase: String })
    end
    assert_raises(ArgumentError) do
      TextFSM::Parser.new(SIMPLE).fields_with_option(:Unknown)
    end
  end

  def test_invalid_template_encoding_raises_template_errors
    ["# invalid \xFF\n#{SIMPLE}", SIMPLE.sub("Start", "Start\xFF")].each do |template|
      [template, StringIO.new(template)].each do |source|
        error = assert_raises(TextFSM::TemplateError) { TextFSM::Parser.new(source) }
        assert_includes error.message, "UTF-8"
      end
    end
    error = assert_raises(TextFSM::TemplateError) { TextFSM::Parser.new(SIMPLE.encode("UTF-16LE")) }
    assert_includes error.message, "UTF-16LE"
  end

  def test_capture_assignment_keeps_optional_nil_values_and_nested_names
    template = <<~'FSM'
      Value Filldown LABEL (\w+)
      Value Required ID (\d+)

      Start
        ^id ${ID}(?: ${LABEL})?(?: (?P<unused>\w+))?$$ -> Record
    FSM
    parser = TextFSM::Parser.new(template)

    assert_equal [["first", "1"], ["", "2"]], parser.parse("id 1 first extra\nid 2\n")
  end

  class Skip < TextFSM::Options::Base
    def before_record
      throw :skip_record if field.value == "skip"
    end
  end

  def test_custom_option_can_skip_a_record_and_clear_its_fields
    template = "Value Skip X (.*)\nValue Y (.*)\n\nStart\n  ^y ${Y}\n  ^x ${X} -> Record\n"
    parser = TextFSM::Parser.new(template, options: { Skip: Skip })
    assert_equal [["ok", ""]], parser.parse("y old\nx skip\nx ok\n")
    assert_equal ["X"], parser.fields_with_option(:Skip)
  end

  def test_field_can_end_with_a_literal_backslash
    template = <<~'FSM'
      Value PATH (folder\\)

      Start
        ^${PATH}$$ -> Record
    FSM
    assert_equal [["folder\\"]], TextFSM::Parser.new(template).parse("folder\\\n")
  end

  class CountRecords < TextFSM::Options::Base
    def after_assign
      field.value = { "label" => field.value, "records" => 0 }
    end

    def before_record
      field.value["records"] += 1 if field.value
    end
  end

  def test_records_own_values_before_later_option_callbacks_run
    template = <<~'FSM'
      Value CountRecords,Filldown LABEL (\w+)
      Value Required ID (\d+)

      Start
        ^label ${LABEL}
        ^id ${ID} -> Record
    FSM
    parser = TextFSM::Parser.new(template, options: { CountRecords: CountRecords })
    parser.parse("label Alpha\nid 1\n", eof: false)
    assert_equal([1, 2], parser.parse("id 2\n", eof: false).map { |row| row.first["records"] })
  end

  def test_fillup_preserves_nested_snapshots_across_chunks_and_record_callbacks
    template = <<~'FSM'
      Value CountRecords,Fillup LABEL (\w+)
      Value Required ID (\d+)

      Start
        ^label ${LABEL}
        ^id ${ID} -> Record
    FSM
    parser = TextFSM::Parser.new(template, options: { CountRecords: CountRecords })
    empty_snapshot = parser.parse("id 1\n", eof: false)
    first_snapshot = parser.parse("label Alpha\nid 2\nid 3\n", eof: false)
    latest_snapshot = parser.parse("label Beta\nid 4\n", eof: false)

    assert_equal [["", "1"]], empty_snapshot
    assert_equal [[{ "label" => "Alpha", "records" => 0 }, "1"],
                  [{ "label" => "Alpha", "records" => 1 }, "2"], ["", "3"]], first_snapshot
    assert_equal first_snapshot.first(2) + [[{ "label" => "Beta", "records" => 0 }, "3"],
                                            [{ "label" => "Beta", "records" => 1 }, "4"]], latest_snapshot
    assert_raises(FrozenError) { latest_snapshot[2][0]["label"].replace("changed") }
    parser.to_a[2][0]["label"].replace("changed")
    assert_equal "Beta", parser.rows[2][0]["label"]
    parser.reset
    assert_equal "Beta", latest_snapshot[2][0]["label"]
  end

  def test_fillup_reuses_values_without_sharing_mutable_exports_or_crossing_filled_rows
    template = <<~'FSM'
      Value CountRecords,Fillup LABEL (\w+)
      Value Required ID (\d+)

      Start
        ^label ${LABEL}
        ^id ${ID} -> Record
    FSM
    parser = TextFSM::Parser.new(template, options: { CountRecords: CountRecords })
    empty = parser.feed("id 1\nid 2\n").rows
    first = parser.feed("label Alpha\nid 3\nid 4\nid 5\n").rows
    latest = parser.feed("label Beta\n").rows

    assert_equal [["", "1"], ["", "2"]], empty
    assert_equal(%w[Alpha Alpha Alpha Beta Beta], latest.map { |row| row[0]["label"] })
    assert_equal([0, 0, 1, 0, 0], latest.map { |row| row[0]["records"] })
    assert_equal [["", "4"], ["", "5"]], first.last(2)
    exported = parser.to_hashes
    exported[0]["LABEL"]["label"].replace("changed")
    assert_equal "Alpha", exported[1]["LABEL"]["label"]
    assert_equal "Alpha", latest[0][0]["label"]
    assert_raises(FrozenError) { latest[1][0]["label"].replace("changed") }
    parser.reset
    assert_equal "Beta", latest.last[0]["label"]
  end

  def test_empty_visible_records_still_clear_hidden_fields
    template = <<~'FSM'
      Value Hidden,Required H (\w+)
      Value X (\w+)

      Start
        ^hidden ${H} -> Record
        ^x ${X} -> Record
    FSM
    parser = TextFSM::Parser.new(template, options: { Hidden: CustomOptions::Hidden })
    assert_empty parser.parse("hidden token\nx item\n")
  end
end
