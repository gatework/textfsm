# frozen_string_literal: true

require_relative "test_helper"

class ParserOptionsTest < Minitest::Test
  class Boolean < TextFSM::Options::Base
    def after_assign
      field.value = field.value == "true" unless field.value.nil?
    end
  end

  def test_required_accepts_false_from_custom_options
    template = "Value Boolean,Required FLAG (true|false)\n\nStart\n  ^${FLAG} -> Record\n"
    parser = TextFSM::Parser.new(template, options: { Boolean: Boolean })

    assert_equal [[false], [true]], parser.parse("false\ntrue\n")
    assert_equal [{ "FLAG" => false }, { "FLAG" => true }], parser.to_hashes
  end

  def test_fillup_accepts_false_and_stops_at_previously_recorded_false
    template = <<~'FSM'
      Value Boolean,Fillup FLAG (true|false)
      Value Required ID (\d+)

      Start
        ^id ${ID} -> Record
        ^flag ${FLAG}
    FSM
    parser = TextFSM::Parser.new(template, options: { Boolean: Boolean })
    snapshot = parser.parse("id 1\n", eof: false)

    assert_equal [[false, "1"], [false, "2"]], parser.parse("flag false\nid 2\n", eof: false)
    assert_equal [["", "1"]], snapshot
    assert_equal [[false, "1"], [false, "2"], [true, "3"]], parser.parse("flag true\nid 3\n")
  end

  def test_filldown_and_required_preserve_false_until_clearall
    template = <<~'FSM'
      Value Boolean,Filldown,Required FLAG (true|false)
      Value Required ID (\d+)

      Start
        ^flag ${FLAG}
        ^id ${ID} -> Record
        ^clear -> Clearall
    FSM
    parser = TextFSM::Parser.new(template, options: { Boolean: Boolean })

    assert_equal [[false, "1"], [false, "2"], [true, "4"]],
                 parser.parse("flag false\nid 1\nid 2\nclear\nid 3\nflag true\nid 4\n")
  end
end
