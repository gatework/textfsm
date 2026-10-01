# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "open3"
require "rbconfig"
require "rubygems/package"

class VerifyPackageTest < Minitest::Test
  def test_undeclared_development_dependency_is_not_available_to_the_installed_gem
    root = File.expand_path("..", __dir__)
    spec = Gem::Specification.load(File.join(root, "textfsm.gemspec"))
    Dir.mktmpdir("textfsm-package-test-") do |directory|
      (spec.files + %w[textfsm.gemspec script/verify_package.rb]).uniq.each do |file|
        destination = File.join(directory, file)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(File.join(root, file), destination)
      end
      library = File.join(directory, "lib/textfsm.rb")
      File.write(library, "require 'rake'\n#{File.read(library)}")
      package = File.join(directory, spec.file_name)
      capture_io do
        Dir.chdir(directory) { Gem::Package.build(spec, false, false, package) }
      end
      output, error, status = Open3.capture3(RbConfig.ruby, File.join(directory, "script/verify_package.rb"), package)

      refute status.success?, "An undeclared development dependency passed isolated verification: #{output}"
      assert_includes error, "cannot load such file -- rake"
    end
  end
end
