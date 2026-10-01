# frozen_string_literal: true

require "json"
require "optparse"
require_relative "version"
require_relative "parser"

module TextFSM
  class CLI
    def self.run(argv = ARGV, **streams)
      new(**streams).run(argv)
    end

    def initialize(input: $stdin, output: $stdout, error: $stderr)
      @input = input
      @output = output
      @error = error
    end

    def run(argv)
      settings = { format: "json", rows: false, validate: false, help: false, version: false }
      options = option_parser(settings)
      args = options.parse(argv.dup)
      if settings[:help] || settings[:version]
        @output.puts(settings[:help] ? options : VERSION)
        return 0
      end
      raise OptionParser::InvalidArgument, "expected TEMPLATE and optional INPUT" unless (1..2).cover?(args.length)

      parser = Parser.from_file(args.first)
      if settings[:validate]
        @output.puts("Template OK: #{parser.header.join(', ')}")
        return 0
      end
      text = args[1] && args[1] != "-" ? File.read(args[1], encoding: "UTF-8") : @input.read
      rows = parser.parse(text)
      write_result(parser.header, rows, settings)
      0
    rescue Error, OptionParser::ParseError, SystemCallError, IOError, ArgumentError, EncodingError => e
      @error.puts("textfsm: #{e.message}")
      2
    end

    private

    def option_parser(settings)
      OptionParser.new do |parser|
        parser.banner = "Usage: textfsm [options] TEMPLATE [INPUT|-]"
        parser.on("--format FORMAT", %w[json table], "Output format: json (default), table") do |format|
          settings[:format] = format
        end
        parser.on("--rows", "JSON output as {header, rows}") do
          settings[:rows] = true
        end
        parser.on("--validate", "Validate template without parsing input") do
          settings[:validate] = true
        end
        parser.on("-v", "--version", "Print version") do
          settings[:version] = true
        end
        parser.on("-h", "--help", "Print help") do
          settings[:help] = true
        end
      end
    end

    def write_result(header, rows, settings)
      if settings[:format] == "json"
        data = settings[:rows] ? { header: header, rows: rows } : rows.map { |row| header.zip(row).to_h }
        @output.puts(JSON.pretty_generate(data))
      else
        @output.puts(header.join("\t"))
        rows.each do |row|
          @output.puts(row.map { |value| value.is_a?(String) ? value : JSON.generate(value) }.join("\t"))
        end
      end
    end
  end
end
