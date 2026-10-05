#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "optparse"
require "rbconfig"
require "rubygems"
require "rubygems/package"
require "tmpdir"

class Release
  HOST = "https://rubygems.org"

  class Error < StandardError; end

  def self.run(argv = ARGV)
    modes = []
    artifact = nil
    options = OptionParser.new do |parser|
      parser.banner = "Usage: bundle exec ruby script/release.rb [--dry-run | --push]"
      parser.on("--dry-run", "Verify and build only (default)") do
        modes << :dry_run
      end
      parser.on("--push", "Verify, publish to RubyGems.org, and check the uploaded checksum") do
        modes << :push
      end
      parser.on("--artifact PATH", "Verify an existing CI artifact without rebuilding") { |path| artifact = path }
      parser.on("-h", "--help", "Show this help") do
        puts parser
        return 0
      end
    end
    arguments = options.parse(argv.dup)
    raise OptionParser::InvalidArgument, arguments.join(" ") unless arguments.empty?
    raise OptionParser::InvalidArgument, "choose --dry-run or --push, not both" if modes.uniq.size > 1

    new.run(push: modes.include?(:push), artifact: artifact)
    0
  rescue Error, OptionParser::ParseError, SystemCallError, Gem::Exception => e
    warn "release: #{e.message}"
    1
  end

  def initialize(root: File.expand_path("..", __dir__), output: $stdout)
    @root = File.expand_path(root)
    @output = output
  end

  def run(push: false, artifact: nil)
    Dir.chdir(@root) do
      spec = Gem::Specification.load("textfsm.gemspec")
      raise Error, "Cannot load textfsm.gemspec" unless spec
      raise Error, "allowed_push_host must be #{HOST}" unless spec.metadata["allowed_push_host"] == HOST

      revision = head
      check_checkout!(revision, spec) if push
      build!(revision) unless artifact
      check_checkout!(revision, spec) if push
      artifact = File.expand_path(artifact || File.join("pkg", spec.file_name))
      Dir.mktmpdir("textfsm-release-") do |directory|
        candidate = File.join(directory, spec.file_name)
        FileUtils.cp(artifact, candidate)
        checksum = verify_candidate!(candidate, spec)
        @output.puts "Prepared #{artifact}\nCommit: #{revision || 'uncommitted'}\nSHA256: #{checksum}"
        if push
          check_checkout!(revision, spec)
          publish!(spec, candidate, checksum)
        else
          @output.puts "Dry run complete. Publish the committed version with bundle exec rake release."
        end
      end
    end
  end

  private

  def head
    output, _error, status = Open3.capture3("git", "rev-parse", "--verify", "HEAD")
    output.strip if status.success?
  end

  def git(*arguments)
    output, error, status = Open3.capture3("git", *arguments)
    raise Error, "git #{arguments.join(' ')} failed: #{error.strip}" unless status.success?

    output
  end

  def check_checkout!(revision, spec)
    raise Error, "Create a Git commit before publishing" unless revision

    repository = File.realpath(git("rev-parse", "--show-toplevel").strip)
    raise Error, "The project must be the Git repository root" unless repository == File.realpath(@root)
    raise Error, "HEAD changed during verification" unless head == revision

    status = git("status", "--porcelain=v1", "--untracked-files=all")
    raise Error, "Commit all changes and untracked files before publishing" unless status.empty?

    missing = spec.files - git("ls-files", "-z").split("\0")
    raise Error, "Packaged files are not tracked by Git: #{missing.join(', ')}" unless missing.empty?
  end

  def build!(revision)
    require "bundler/setup"

    environment = { "BUNDLE_FROZEN" => "true" }
    environment["SOURCE_DATE_EPOCH"] = git("show", "-s", "--format=%ct", revision).strip if revision
    return if system(environment, RbConfig.ruby, "-rbundler/setup", Gem.bin_path("rake", "rake"), "test", "lint", "build")

    raise Error, "Tests, lint, or build failed; nothing was published"
  end

  def verify_candidate!(candidate, spec)
    checksum = Digest::SHA256.file(candidate).hexdigest
    candidate_spec = Gem::Package.new(candidate).spec
    raise Error, "Artifact identity differs from the gemspec" unless candidate_spec.full_name == spec.full_name

    package = Gem::Package.new(candidate)
    unless candidate_spec.files.sort == spec.files.sort && package.contents.sort == spec.files.sort
      raise Error, "Artifact file list differs from the gemspec"
    end

    attributes = %i[dependencies metadata required_ruby_version required_rubygems_version licenses
                    executables bindir extensions require_paths authors email summary description homepage platform]
    unless attributes.all? { |attribute| candidate_spec.public_send(attribute) == spec.public_send(attribute) }
      raise Error, "Artifact metadata differs from the gemspec"
    end

    Dir.mktmpdir("release-contents-") do |directory|
      Gem::Package.new(candidate).extract_files(directory)
      spec.files.each do |path|
        expected = File.binread(path)
        raise Error, "Artifact content differs from source: #{path}" unless File.binread(File.join(directory, path)) == expected
      end
    end
    check_package!(candidate)
    raise Error, "Artifact changed during verification" unless Digest::SHA256.file(candidate).hexdigest == checksum

    checksum
  end

  def check_package!(candidate)
    return if system(RbConfig.ruby, "script/verify_package.rb", candidate)

    raise Error, "Package verification failed; nothing was published"
  end

  def registry_version(spec)
    uri = URI("#{HOST}/api/v2/rubygems/#{spec.name}/versions/#{spec.version}.json")
    uri.query = URI.encode_www_form(platform: spec.platform.to_s)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 15) do |http|
      http.get(uri.request_uri)
    end
    return if response.is_a?(Net::HTTPNotFound)
    raise Error, "RubyGems version lookup returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    metadata = JSON.parse(response.body)
    raise Error, "RubyGems returned invalid version metadata" unless metadata.is_a?(Hash)

    metadata
  rescue JSON::ParserError, IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError => e
    raise Error, "Cannot read RubyGems version metadata: #{e.message}"
  end

  def confirm_version!(metadata, spec, checksum)
    identity = metadata.values_at("name", "version", "platform", "sha")
    return if identity == [spec.name, spec.version.to_s, spec.platform.to_s, checksum] && metadata["yanked"] == false

    raise Error, "RubyGems already has a different or yanked #{spec.full_name}; use a new version"
  end

  def push_gem(candidate)
    system(RbConfig.ruby, "-S", "gem", "push", candidate, "--host", HOST)
  end

  def publish!(spec, candidate, checksum)
    existing = registry_version(spec)
    if existing
      confirm_version!(existing, spec, checksum)
      confirm_download!(spec, checksum)
      @output.puts "Already published with the same SHA256: #{HOST}/gems/#{spec.name}/versions/#{spec.version}"
      return
    end

    pushed = push_gem(candidate)
    # A disconnected push may still have succeeded. Only retry the readback.
    metadata = readback(spec)
    unless metadata
      outcome = pushed ? "Upload accepted but unconfirmed" : "Upload failed or its result is unknown"
      raise Error, "#{outcome}. Check #{HOST}/gems/#{spec.name}/versions/#{spec.version} and SHA256 #{checksum} before retry"
    end

    confirm_version!(metadata, spec, checksum)
    confirm_download!(spec, checksum)
    @output.puts "Published and verified: #{HOST}/gems/#{spec.name}/versions/#{spec.version}"
  end

  def confirm_download!(spec, checksum)
    uri = URI("#{HOST}/downloads/#{spec.full_name}.gem")
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
      http.get(uri.request_uri)
    end
    return if response.is_a?(Net::HTTPSuccess) && Digest::SHA256.hexdigest(response.body) == checksum

    raise Error, "Published gem download differs from the verified artifact"
  end

  def readback(spec)
    5.times do |attempt|
      begin
        metadata = registry_version(spec)
        return metadata if metadata
      rescue Error => e
        @output.puts "Readback pending: #{e.message}"
      end
      sleep 2 if attempt < 4
    end
    nil
  end
end

exit Release.run if $PROGRAM_NAME == __FILE__
