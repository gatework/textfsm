# frozen_string_literal: true

require_relative "lib/textfsm/version"

Gem::Specification.new do |spec|
  spec.name = "textfsm"
  spec.version = TextFSM::VERSION
  spec.authors = ["TextFSM Ruby contributors"]
  spec.summary = "A Ruby state machine for parsing text with TextFSM templates"
  spec.description = "Parses semi-structured text using Google TextFSM template syntax, " \
                     "with field options, state transitions, and CLI template indexes."
  spec.license = "Apache-2.0"
  spec.homepage = "https://github.com/gatework/textfsm"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["lib/**/*.rb", "exe/*", "examples/*", "README.md", "LICENSE", "NOTICE"]
  spec.bindir = "exe"
  spec.executables = ["textfsm"]
  spec.require_paths = ["lib"]
  spec.add_dependency "json", "~> 2.0"
  spec.add_dependency "strscan", "~> 3.0"
end
