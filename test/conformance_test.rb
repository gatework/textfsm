# frozen_string_literal: true

require_relative "test_helper"

class ConformanceTest < Minitest::Test
  FIXTURES = JSON.parse(File.read(File.join(__dir__, "fixtures/python_conformance.json")))

  FIXTURES.fetch("cases").each_with_index do |scenario, index|
    define_method("test_python_#{index}_#{scenario.fetch('name').gsub(/\W/, '_')}") do
      template = scenario.fetch("template")
      if scenario["error"]
        assert_raises(TextFSM::TemplateError) do
          TextFSM::Parser.new(template)
        end
        next
      end

      fsm = TextFSM::Parser.new(template)
      assert_equal scenario.fetch("header"), fsm.header
      assert_equal scenario.fetch("normalized"), fsm.to_s
      scenario.fetch("options").each do |option, names|
        assert_equal names, fsm.fields_with_option(option)
      end
      scenario.fetch("events").each do |event|
        if event.fetch("operation") == "reset"
          assert_same fsm, fsm.reset
          assert_empty fsm.rows
          assert_equal "Start", fsm.current_state
        elsif event["error"]
          assert_raises(TextFSM::ParseError) do
            fsm.parse(event["text"], eof: event["eof"])
          end
        else
          assert_equal event.fetch("rows"), fsm.parse(event["text"], eof: event["eof"])
          assert_equal event.fetch("state"), fsm.current_state
        end
      end
    end
  end
end
