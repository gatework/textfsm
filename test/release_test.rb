# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require_relative "../script/release"

class ReleaseTest < Minitest::Test
  class FakeRelease < Release
    attr_accessor :versions, :push_result, :verification_error, :after_verify, :after_package_check
    attr_reader :pushes, :verifications, :lookups

    def initialize(**)
      super
      @versions = []
      @pushes = []
      @verifications = []
      @lookups = 0
      @push_result = true
    end

    private

    def build!(revision)
      @verifications << revision
      raise Error, "verification failed" if verification_error

      spec = Gem::Specification.load("textfsm.gemspec")
      FileUtils.mkdir_p("pkg")
      Gem::Package.build(spec, false, false, "pkg/#{spec.file_name}")
      after_verify&.call
    end

    def check_package!(candidate)
      after_package_check&.call(candidate)
    end

    def registry_version(spec)
      @lookups += 1
      result = versions.shift
      raise result if result.is_a?(Exception)
      return result unless result == :matching

      {
        "name" => spec.name, "version" => spec.version.to_s, "platform" => spec.platform.to_s,
        "sha" => Digest::SHA256.file("pkg/#{spec.file_name}").hexdigest, "yanked" => false
      }
    end

    def push_gem(candidate)
      @pushes << [candidate, File.binread(candidate)]
      push_result
    end

    def confirm_download!(_spec, _checksum)
    end

    def sleep(_seconds)
    end
  end

  def setup
    @directory = Dir.mktmpdir("textfsm-release-test-")
    @output = StringIO.new
    @release = FakeRelease.new(root: @directory, output: @output)
    File.write(File.join(@directory, ".gitignore"), "/pkg/\n")
    File.write(File.join(@directory, "payload.rb"), "# test package\n")
    File.write(File.join(@directory, "textfsm.gemspec"), <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = "textfsm-release-test"
        spec.version = "0.1.0"
        spec.authors = ["Test"]
        spec.summary = "Release orchestration fixture"
        spec.license = "Apache-2.0"
        spec.homepage = "https://github.com/gatework/textfsm"
        spec.metadata["allowed_push_host"] = "https://rubygems.org"
        spec.files = ["payload.rb"]
      end
    RUBY
    git("init", "-q", "-b", "main")
    # Keep background maintenance from outliving the disposable repository.
    git("config", "maintenance.auto", "false")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_dry_run_builds_without_a_commit_or_any_remote_calls
    original_directory = Dir.pwd
    run_release

    assert_equal original_directory, Dir.pwd
    assert_equal [nil], @release.verifications
    assert_empty @release.pushes
    assert_equal 0, @release.lookups
    assert_includes @output.string, "Dry run complete"
    assert_includes @output.string, "Commit: uncommitted"
  end

  def test_existing_artifact_is_verified_without_rebuilding
    commit
    run_release
    @release.verifications.clear
    run_release(artifact: File.join(@directory, "pkg/textfsm-release-test-0.1.0.gem"))
    assert_empty @release.verifications
    assert_empty @release.pushes
  end

  def test_replaced_artifact_content_is_rejected_before_registry_access
    commit
    run_release
    File.write(File.join(@directory, "payload.rb"), "different source\n")
    error = assert_raises(Release::Error) do
      run_release(artifact: File.join(@directory, "pkg/textfsm-release-test-0.1.0.gem"))
    end
    assert_includes error.message, "content differs"
    assert_equal 0, @release.lookups
  end

  def test_download_is_checked_against_the_verified_bytes
    spec = Gem::Specification.load(File.join(@directory, "textfsm.gemspec"))
    release = Release.new(root: @directory, output: @output)
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.define_singleton_method(:body) { "downloaded bytes" }
    http = Object.new
    http.define_singleton_method(:get) { |_path| response }
    Net::HTTP.stub(:start, ->(*, **, &block) { block.call(http) }) do
      assert_raises(Release::Error) { release.send(:confirm_download!, spec, "wrong checksum") }
      release.send(:confirm_download!, spec, Digest::SHA256.hexdigest("downloaded bytes"))
    end
  end

  def test_push_requires_a_commit_before_verification
    error = assert_raises(Release::Error) do
      run_release(push: true)
    end
    assert_includes error.message, "Create a Git commit"
    assert_empty @release.verifications
    assert_empty @release.pushes
  end

  def test_conflicting_mode_flags_are_rejected_without_running_a_release
    [%(--push --dry-run), %(--dry-run --push)].each do |flags|
      _output, error = capture_io do
        Release.stub(:new, -> { flunk "Conflicting modes must not start a release" }) do
          assert_equal 1, Release.run(flags.split)
        end
      end
      assert_includes error, "choose --dry-run or --push"
    end
  end

  def test_push_rejects_dirty_and_untracked_files
    commit
    ["payload.rb", "untracked.rb"].each do |name|
      File.write(File.join(@directory, name), "changed\n")
      error = assert_raises(Release::Error) do
        run_release(push: true)
      end
      assert_includes error.message, "Commit all changes"
      commit
    end
    assert_empty @release.verifications
    assert_empty @release.pushes
  end

  def test_ignored_packaged_files_must_still_be_tracked
    File.write(File.join(@directory, ".gitignore"), "/pkg/\n/payload.rb\n")
    commit
    error = assert_raises(Release::Error) do
      run_release(push: true)
    end
    assert_includes error.message, "not tracked by Git: payload.rb"
    assert_empty @release.pushes
  end

  def test_verification_failure_never_reaches_the_registry
    commit
    @release.verification_error = true
    assert_raises(Release::Error) do
      run_release(push: true)
    end
    assert_equal 0, @release.lookups
    assert_empty @release.pushes
  end

  def test_new_changes_after_verification_stop_publication
    commit
    @release.after_verify = -> { File.write("payload.rb", "changed\n") }
    error = assert_raises(Release::Error) do
      run_release(push: true)
    end
    assert_includes error.message, "Commit all changes"
    assert_equal 0, @release.lookups
  end

  def test_head_changes_after_verification_stop_publication
    commit
    @release.after_verify = lambda do
      File.write("payload.rb", "changed\n")
      commit
    end
    error = assert_raises(Release::Error) do
      run_release(push: true)
    end
    assert_includes error.message, "HEAD changed"
    assert_empty @release.pushes
  end

  def test_successful_publication_uploads_the_verified_bytes_once
    commit
    @release.versions = [nil, :matching]
    run_release(push: true)

    assert_equal 1, @release.pushes.size
    candidate, contents = @release.pushes.first
    assert_equal File.binread(File.join(@directory, "pkg/textfsm-release-test-0.1.0.gem")), contents
    refute File.exist?(candidate)
    assert_equal 2, @release.lookups
    assert_includes @output.string, "Published and verified"
  end

  def test_candidate_changes_during_package_verification_stop_publication
    commit
    @release.after_package_check = ->(candidate) { File.write(candidate, "changed") }
    error = assert_raises(Release::Error) do
      run_release(push: true)
    end
    assert_includes error.message, "Artifact changed during verification"
    assert_empty @release.pushes
    assert_equal 0, @release.lookups
  end

  def test_a_concurrent_build_cannot_replace_the_verified_candidate
    commit
    @release.after_package_check = lambda do |candidate|
      @release.versions = [nil, {
        "name" => "textfsm-release-test", "version" => "0.1.0", "platform" => "ruby",
        "sha" => Digest::SHA256.file(candidate).hexdigest, "yanked" => false
      }]
      File.write("pkg/textfsm-release-test-0.1.0.gem", "concurrent build")
    end
    run_release(push: true)
    assert_equal 1, @release.pushes.size
    refute_equal "concurrent build", @release.pushes.first.last
    assert_includes @output.string, "Published and verified"
  end

  def test_matching_published_version_is_a_noop
    commit
    @release.versions = [:matching]
    run_release(push: true)

    assert_empty @release.pushes
    assert_includes @output.string, "Already published"
  end

  def test_conflicting_version_is_never_pushed
    commit
    @release.versions = [{ "sha" => "another artifact" }]
    error = assert_raises(Release::Error) do
      run_release(push: true)
    end
    assert_includes error.message, "use a new version"
    assert_empty @release.pushes
  end

  def test_ambiguous_push_can_be_confirmed_without_another_upload
    commit
    @release.push_result = false
    @release.versions = [nil, Release::Error.new("connection lost"), nil, :matching]
    run_release(push: true)

    assert_equal 1, @release.pushes.size
    assert_equal 4, @release.lookups
    assert_includes @output.string, "Published and verified"
  end

  def test_unconfirmed_upload_reports_uncertainty_and_does_not_retry_push
    commit
    @release.push_result = false
    error = assert_raises(Release::Error) do
      run_release(push: true)
    end
    assert_includes error.message, "result is unknown"
    assert_includes error.message, "SHA256"
    assert_equal 1, @release.pushes.size
    assert_equal 6, @release.lookups
  end

  def test_initial_registry_failure_does_not_upload
    commit
    @release.versions = [Release::Error.new("service unavailable")]
    assert_raises(Release::Error) do
      run_release(push: true)
    end
    assert_empty @release.pushes
    assert_equal 1, @release.lookups
  end

  def test_registry_only_treats_404_as_an_unpublished_version
    release = Release.new(root: @directory, output: @output)
    spec = Gem::Specification.load(File.join(@directory, "textfsm.gemspec"))
    response = Net::HTTPNotFound.new("1.1", "404", "Not Found")
    http = Object.new
    http.define_singleton_method(:get) { |_path| response }
    Net::HTTP.stub(:start, ->(*, **, &block) { block.call(http) }) do
      assert_nil release.send(:registry_version, spec)
      response = Net::HTTPServiceUnavailable.new("1.1", "503", "Unavailable")
      error = assert_raises(Release::Error) do
        release.send(:registry_version, spec)
      end
      assert_includes error.message, "HTTP 503"
    end
  end

  def test_registry_rejects_invalid_json_or_non_object_responses
    release = Release.new(root: @directory, output: @output)
    spec = Gem::Specification.load(File.join(@directory, "textfsm.gemspec"))
    ["not JSON", "[]"].each do |body|
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.define_singleton_method(:body) { body }
      http = Object.new
      http.define_singleton_method(:get) { |_path| response }
      Net::HTTP.stub(:start, ->(*, **, &block) { block.call(http) }) do
        assert_raises(Release::Error) do
          release.send(:registry_version, spec)
        end
      end
    end
  end

  def test_yanked_versions_cannot_be_confirmed_as_published
    release = Release.new(root: @directory, output: @output)
    spec = Gem::Specification.load(File.join(@directory, "textfsm.gemspec"))
    metadata = { "name" => spec.name, "version" => "0.1.0", "platform" => "ruby", "sha" => "matching", "yanked" => true }
    assert_raises(Release::Error) do
      release.send(:confirm_version!, metadata, spec, "matching")
    end
  end

  def test_push_passes_the_artifact_as_one_argument_and_fixes_the_registry_host
    release = Release.new(root: @directory, output: @output)
    command = nil
    release.stub(:system, ->(*arguments) { command = arguments }) do
      release.send(:push_gem, "/tmp/with spaces/package.gem")
    end
    assert_equal [RbConfig.ruby, "-S", "gem", "push", "/tmp/with spaces/package.gem", "--host", "https://rubygems.org"], command
  end

  private

  def run_release(**options)
    capture_io do
      @release.run(**options)
    end
  end

  def git(*arguments)
    output, error, status = Open3.capture3("git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                                           *arguments, chdir: @directory)
    raise "git failed: #{error}" unless status.success?

    output
  end

  def commit
    git("add", ".")
    git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "Fixture")
  end
end
