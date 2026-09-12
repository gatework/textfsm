#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "rubygems/package"
require "tmpdir"

package_path = File.expand_path(ARGV.fetch(0))
package = Gem::Package.new(package_path)
package.verify
source_root = File.expand_path("..", __dir__)
expected_files = Gem::Specification.load(File.join(source_root, "textfsm.gemspec")).files.sort
abort "Package contents differ from the gemspec" unless package.contents.sort == expected_files
abort "Executable is missing" unless package.spec.executables == ["textfsm"]

def run!(environment, *command, **options)
  output, error, status = Open3.capture3(environment, *command, **options)
  raise "#{command.inspect} failed (#{status.exitstatus}): #{error}" unless status.success?

  output
end

def verify_usage!(environment, executable, template, header)
  help = run!(environment, executable, "--help")
  raise "Installed help is missing usage" unless help.start_with?("Usage: textfsm")

  validation = run!(environment, executable, "--validate", template)
  raise "Installed validation differs" unless validation.strip == "Template OK: #{header.join(', ')}"

  output, error, status = Open3.capture3(environment, executable, "--unknown")
  raise "CLI error contract differs" unless status.exitstatus == 2 && output.empty? && error.start_with?("textfsm:")
end

def verify_cli!(environment, directory, root)
  executable = File.join(directory, "bin", "textfsm")
  template = File.join(root, "examples", "cisco_version_template")
  input = File.join(root, "examples", "cisco_version_example")
  actual = JSON.parse(run!(environment, executable, template, input, chdir: directory))
  raise "Installed CLI returned no records" if actual.empty?
  raise "Installed CLI returned the wrong data" unless actual.first.fetch("Model") == "WS-C4948-10GE"

  rows = JSON.parse(run!(environment, executable, "--rows", template, input, chdir: directory))
  raise "Rows and Hash output disagree" unless rows.fetch("rows").map { |row| rows.fetch("header").zip(row).to_h } == actual

  piped = JSON.parse(run!(environment, executable, template, "-", stdin_data: File.read(input), chdir: directory))
  raise "Stdin parsing differs from file parsing" unless piped == actual

  verify_usage!(environment, executable, template, rows.fetch("header"))

  table = run!(environment, executable, "--format", "table", template, input)
  return if table.lines.first&.chomp&.split("\t") == rows.fetch("header") && table.include?("WS-C4948-10GE")

  raise "Installed table output differs"
end

Dir.mktmpdir("textfsm-install-") do |directory|
  environment = {
    "GEM_HOME" => directory,
    "GEM_PATH" => ([directory] + Gem.path).join(File::PATH_SEPARATOR),
    "RUBYOPT" => nil,
    "RUBYLIB" => nil,
    "BUNDLE_GEMFILE" => nil
  }
  run!(environment, RbConfig.ruby, "-S", "gem", "install", package_path,
       "--local", "--ignore-dependencies", "--no-document", "--install-dir", directory)
  root = File.join(directory, "gems", package.spec.full_name)
  expected_files.each do |file|
    unless File.binread(File.join(root, file)) == File.binread(File.join(source_root, file))
      raise "Installed file differs from source: #{file}"
    end
  end
  library = File.join(root, "lib")
  Dir.glob("**/*.rb", base: library).each do |file|
    run!(environment, RbConfig.ruby, "-I", library, "-e", "require ARGV.fetch(0)", file.delete_suffix(".rb"), chdir: directory)
  end

  verify_cli!(environment, directory, root)
  executable = File.join(directory, "bin", "textfsm")
  raise "Installed version differs" unless run!(environment, executable, "--version").strip == package.spec.version.to_s

  puts "Verified #{package.spec.full_name}: #{package.contents.size} files match source, isolated requires, CLI formats/stdin/errors."
end
