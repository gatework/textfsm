# frozen_string_literal: true

require "rake/testtask"
require "rubocop/rake_task"
require "rubygems/package"

Rake::TestTask.new do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end

RuboCop::RakeTask.new(:lint)
spec = Gem::Specification.load("textfsm.gemspec")
desc "Build the gem in pkg/"
task :build do
  mkdir_p "pkg"
  Gem::Package.build(spec, false, false, "pkg/#{spec.file_name}")
end

desc "Run tests, lint, and an isolated installation check"
task verify: %i[test lint build] do
  ruby "script/verify_package.rb", "pkg/#{spec.file_name}"
end

namespace :release do
  desc "Verify and prepare the current version without publishing"
  task :check do
    ruby "script/release.rb", "--dry-run"
  end
end

desc "Verify and publish the current version to RubyGems.org"
task :release do
  ruby "script/release.rb", "--push"
end

task default: %i[test lint]
