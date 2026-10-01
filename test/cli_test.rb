# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/textfsm/cli"

class CLITest < Minitest::Test
  TEMPLATE = File.expand_path("../examples/cisco_version_template", __dir__)
  INPUT = File.expand_path("../examples/cisco_version_example", __dir__)

  def run_cli(*args, stdin: "")
    output = StringIO.new
    error = StringIO.new
    status = TextFSM::CLI.run(args, input: StringIO.new(stdin), output: output, error: error)
    [status, output.string, error.string]
  end

  def test_json_file_and_stdin
    status, output, error = run_cli(TEMPLATE, INPUT)
    assert_equal 0, status
    assert_empty error
    assert_equal TextFSM::Parser.from_file(TEMPLATE).parse_hashes(File.read(INPUT)), JSON.parse(output)
    assert_equal output, run_cli(TEMPLATE, "-", stdin: File.read(INPUT))[1]
    assert_equal output, run_cli(TEMPLATE, stdin: File.read(INPUT))[1]
  end

  def test_rows_and_table_output
    status, output, = run_cli("--rows", TEMPLATE, INPUT)
    assert_equal 0, status
    assert_equal %w[header rows], JSON.parse(output).keys
    status, output, = run_cli("--format", "table", TEMPLATE, INPUT)
    assert_equal 0, status
    assert_includes output, "\t"
  end

  def test_validation_and_help
    status, output, = run_cli("--validate", TEMPLATE)
    assert_equal 0, status
    assert_includes output, "Template OK"
    assert_equal 0, run_cli("--help")[0]
    assert_equal [0, "#{TextFSM::VERSION}\n", ""], run_cli("--version")
  end

  def test_invalid_arguments_and_files
    [[], ["--unknown"], ["--format", "xml", TEMPLATE], ["missing"], [TEMPLATE, "missing"]].each do |args|
      status, output, error = run_cli(*args)
      assert_equal 2, status
      assert_empty output
      refute_empty error
    end
  end

  def test_parse_error_does_not_emit_partial_json
    Dir.mktmpdir do |dir|
      path = File.join(dir, "template")
      File.write(path, "Value X (.*)\n\nStart\n  ^bad -> Error\n  ^${X} -> Record\n")
      status, output, error = run_cli(path, stdin: "good\nbad\n")
      assert_equal 2, status
      assert_empty output
      assert_includes error, "Rule Line: 4"
    end
  end

  def test_invalid_unicode_regex_reports_an_error_without_a_backtrace
    Dir.mktmpdir do |directory|
      path = File.join(directory, "template")
      File.write(path, "Value X (\\U00110000)\n\nStart\n")
      status, output, error = run_cli("--validate", path)
      assert_equal 2, status
      assert_empty output
      assert_includes error, "Invalid regular expression"
      refute_includes error, "from "
    end
  end

  def test_incompatible_input_encoding_reports_an_error_without_a_backtrace
    Dir.mktmpdir do |directory|
      path = File.join(directory, "template")
      File.write(path, "Value X (.*)\n\nStart\n  ^${X} -> Record\n")
      status, output, error = run_cli(path, stdin: "\xFF\n".b)
      assert_equal 2, status
      assert_empty output
      assert_match(/\Atextfsm: /, error)
      refute_includes error, "from "
    end
  end

  def test_validation_help_and_version_do_not_read_input_or_change_arguments
    input = Object.new
    def input.read
      raise "must not read input"
    end

    [["--validate", TEMPLATE], ["--help"], ["--version"]].each do |args|
      assert_equal 0, TextFSM::CLI.run(args.freeze, input: input, output: StringIO.new, error: StringIO.new)
    end
  end
end
