#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "erb"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "tempfile"
require "tmpdir"

class ReleaseUpdateError < StandardError; end

class ReleaseUpdater
  ROOT = Pathname(__dir__).join("..").expand_path.freeze
  TAG_PATTERN = /\Av[0-9]+(?:\.[0-9]+)*\z/
  COMMIT_PATTERN = /\A[0-9a-f]{40}\z/
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/
  ASSET_NAME_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  MANIFEST_FIELDS = %w[schemaVersion repository tag version commit packages].freeze
  PACKAGE_FIELDS = %w[type token source].freeze

  PACKAGE_CONFIGS = {
    "sonim1/switchtab" => {
      "switchtab" => {
        type: "cask",
        kind: "release-asset",
        template: "Templates/Casks/switchtab.rb.erb",
        destination: "Casks/switchtab.rb",
      }.freeze,
    }.freeze,
    "sonim1/UpdateBar" => {
      "updatebar" => {
        type: "formula",
        kind: "release-asset",
        template: "Templates/Formula/updatebar.rb.erb",
        destination: "Formula/updatebar.rb",
      }.freeze,
      "updatebar-app" => {
        type: "cask",
        kind: "release-asset",
        template: "Templates/Casks/updatebar-app.rb.erb",
        destination: "Casks/updatebar-app.rb",
      }.freeze,
      "updatebar-tui" => {
        type: "formula",
        kind: "github-tag-archive",
        template: "Templates/Formula/updatebar-tui.rb.erb",
        destination: "Formula/updatebar-tui.rb",
      }.freeze,
    }.freeze,
  }.freeze

  def self.parse_options(arguments)
    arguments.each do |argument|
      next unless argument.start_with?("-")
      next if ["--repository", "--tag"].include?(argument)

      raise OptionParser::InvalidOption, argument
    end

    options = {}
    parser = OptionParser.new do |option_parser|
      option_parser.on("--repository VALUE", String) do |value|
        raise ReleaseUpdateError, "--repository may only be specified once" if options.key?(:repository)

        options[:repository] = value
      end
      option_parser.on("--tag VALUE", String) do |value|
        raise ReleaseUpdateError, "--tag may only be specified once" if options.key?(:tag)

        options[:tag] = value
      end
    end
    remaining = parser.parse(arguments)
    raise ReleaseUpdateError, "unexpected arguments: #{remaining.join(' ')}" unless remaining.empty?
    raise ReleaseUpdateError, "--repository is required" if options[:repository].nil? || options[:repository].empty?
    raise ReleaseUpdateError, "--tag is required" if options[:tag].nil? || options[:tag].empty?

    options
  end

  def initialize(repository:, tag:)
    @repository = repository
    @tag = tag
  end

  def run
    configurations = PACKAGE_CONFIGS[@repository]
    raise ReleaseUpdateError, "unknown repository: #{@repository}" unless configurations
    raise ReleaseUpdateError, "tag must match v[0-9]+(.[0-9]+)*: #{@tag}" unless TAG_PATTERN.match?(@tag)

    manifest = read_manifest
    packages = validate_manifest(manifest, configurations)
    return if ENV["TAP_VERIFY_ONLY"] == "1"

    version = manifest.fetch("version")
    refuse_downgrades(packages, configurations, version)
    rendered_destinations = render_destinations(packages, configurations, version)
    verify_downloaded_sources(packages, configurations)
    write_transaction(rendered_destinations)
  end

  private

  def read_manifest
    manifest_path = ENV["TAP_MANIFEST_FILE"]
    raise ReleaseUpdateError, "TAP_MANIFEST_FILE is required" if manifest_path.nil? || manifest_path.empty?

    JSON.parse(Pathname(manifest_path).binread)
  rescue JSON::ParserError => error
    raise ReleaseUpdateError, "manifest is not valid JSON: #{error.message}"
  rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => error
    raise ReleaseUpdateError, "cannot read TAP_MANIFEST_FILE: #{error.message}"
  end

  def validate_manifest(manifest, configurations)
    raise ReleaseUpdateError, "manifest must be a JSON object" unless manifest.is_a?(Hash)

    validate_exact_fields(manifest, MANIFEST_FIELDS, "manifest")
    unless manifest["schemaVersion"].instance_of?(Integer) && manifest["schemaVersion"] == 1
      raise ReleaseUpdateError, "schemaVersion must be the integer 1"
    end
    unless manifest["repository"] == @repository
      raise ReleaseUpdateError, "manifest repository does not match --repository"
    end
    raise ReleaseUpdateError, "manifest tag does not match --tag" unless manifest["tag"] == @tag

    version = manifest["version"]
    unless version.is_a?(String) && version == @tag.delete_prefix("v")
      raise ReleaseUpdateError, "manifest version must exactly match tag without its v prefix"
    end
    unless manifest["commit"].is_a?(String) && COMMIT_PATTERN.match?(manifest["commit"])
      raise ReleaseUpdateError, "commit must be 40 lowercase hexadecimal characters"
    end

    packages = manifest["packages"]
    unless packages.is_a?(Array) && !packages.empty?
      raise ReleaseUpdateError, "packages must be a non-empty array"
    end

    packages_by_token = {}
    packages.each do |package|
      raise ReleaseUpdateError, "each package must be a JSON object" unless package.is_a?(Hash)

      validate_exact_fields(package, PACKAGE_FIELDS, "package")
      token = package["token"]
      raise ReleaseUpdateError, "package token must be a string" unless token.is_a?(String)
      raise ReleaseUpdateError, "duplicate package token: #{token}" if packages_by_token.key?(token)

      configuration = configurations[token]
      raise ReleaseUpdateError, "unknown package token: #{token}" unless configuration
      unless package["type"] == configuration.fetch(:type)
        raise ReleaseUpdateError, "#{token} must have type #{configuration.fetch(:type)}"
      end

      source = package["source"]
      raise ReleaseUpdateError, "#{token} source must be a JSON object" unless source.is_a?(Hash)
      unless source["kind"] == configuration.fetch(:kind)
        raise ReleaseUpdateError, "#{token} must have source kind #{configuration.fetch(:kind)}"
      end
      validate_source(token, source, configuration.fetch(:kind), version)
      packages_by_token[token] = package
    end

    unless packages_by_token.keys.sort == configurations.keys.sort
      raise ReleaseUpdateError, "packages must contain exactly: #{configurations.keys.join(', ')}"
    end

    packages_by_token
  end

  def validate_source(token, source, kind, version)
    expected_fields = %w[kind sha256]
    if kind == "release-asset"
      expected_fields << "name"
    elsif source.key?("name")
      raise ReleaseUpdateError, "github-tag-archive source must not contain name"
    end
    validate_exact_fields(source, expected_fields, "#{token} source")

    sha256 = source["sha256"]
    unless sha256.is_a?(String) && SHA256_PATTERN.match?(sha256)
      raise ReleaseUpdateError, "#{token} sha256 must be 64 lowercase hexadecimal characters"
    end
    return unless kind == "release-asset"

    name = source["name"]
    unless name.is_a?(String) && ASSET_NAME_PATTERN.match?(name)
      raise ReleaseUpdateError, "release asset name must be a safe basename for #{token}"
    end

    validate_canonical_asset_name(token, name, version)
  end

  def validate_canonical_asset_name(token, name, version)
    case token
    when "switchtab"
      pattern = /\ASwitchTab-#{Regexp.escape(version)}-[0-9]+(?:\.[0-9]+){0,2}\.dmg\z/
      return if pattern.match?(name)

      raise ReleaseUpdateError,
            "switchtab release asset name must match SwitchTab-#{version}-<numeric build>.dmg"
    when "updatebar"
      expected_name = "updatebar-#{version}-macos-arm64.tar.gz"
    when "updatebar-app"
      expected_name = "UpdateBar-#{version}-macos-arm64.dmg"
    end
    return if name == expected_name

    raise ReleaseUpdateError, "#{token} release asset name must be #{expected_name}"
  end

  def validate_exact_fields(object, expected_fields, context)
    unexpected = object.keys - expected_fields
    raise ReleaseUpdateError, "unexpected #{context} field: #{unexpected.first}" unless unexpected.empty?

    missing = expected_fields - object.keys
    raise ReleaseUpdateError, "missing #{context} field: #{missing.first}" unless missing.empty?
  end

  def refuse_downgrades(packages, configurations, new_version)
    packages.each_key do |token|
      destination = ROOT.join(configurations.fetch(token).fetch(:destination))
      next unless destination.file?

      current_version = extract_version(destination.binread)
      next unless current_version && compare_versions(current_version, new_version).positive?

      raise ReleaseUpdateError,
            "refusing to replace #{token} version #{current_version} with older version #{new_version}"
    end
  end

  def extract_version(contents)
    explicit = contents.match(/^\s*version\s+["']([0-9]+(?:\.[0-9]+)*)["']/)
    return explicit[1] if explicit

    archive_url = contents.match(%r{/archive/refs/tags/v([0-9]+(?:\.[0-9]+)*)\.tar\.gz})
    archive_url && archive_url[1]
  end

  def compare_versions(left, right)
    left_parts = left.split(".").map(&:to_i)
    right_parts = right.split(".").map(&:to_i)
    length = [left_parts.length, right_parts.length].max
    (left_parts.fill(0, left_parts.length...length) <=> right_parts.fill(0, right_parts.length...length))
  end

  def render_destinations(packages, configurations, version)
    packages.to_h do |token, package|
      configuration = configurations.fetch(token)
      source = package.fetch("source")
      url = source_url(source)
      template_path = ROOT.join(configuration.fetch(:template))
      template = template_path.binread
      rendered = ERB.new(template).result_with_hash(
        version: version,
        sha256: source.fetch("sha256"),
        url: url,
        token: token,
      )
      rendered += "\n" unless rendered.end_with?("\n")
      [ROOT.join(configuration.fetch(:destination)), rendered]
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => error
      raise ReleaseUpdateError, "cannot read template for #{token}: #{error.message}"
    rescue SyntaxError, NameError => error
      raise ReleaseUpdateError, "cannot render template for #{token}: #{error.message}"
    end
  end

  def source_url(source)
    if source.fetch("kind") == "release-asset"
      "https://github.com/#{@repository}/releases/download/#{@tag}/#{source.fetch('name')}"
    else
      "https://github.com/#{@repository}/archive/refs/tags/#{@tag}.tar.gz"
    end
  end

  def verify_downloaded_sources(packages, configurations)
    gh_bin = ENV.fetch("GH_BIN", "gh")
    curl_bin = ENV.fetch("CURL_BIN", "curl")
    raise ReleaseUpdateError, "GH_BIN must not be empty" if gh_bin.empty?
    raise ReleaseUpdateError, "CURL_BIN must not be empty" if curl_bin.empty?

    Dir.mktmpdir("tap-release-") do |directory|
      configurations.each do |token, configuration|
        source = packages.fetch(token).fetch("source")
        downloaded_path = if configuration.fetch(:kind) == "release-asset"
                            download_release_asset(gh_bin, token, source, directory)
                          else
                            download_tag_archive(curl_bin, token, source, directory)
                          end
        actual_sha256 = Digest::SHA256.file(downloaded_path).hexdigest
        next if actual_sha256 == source.fetch("sha256")

        raise ReleaseUpdateError,
              "checksum mismatch for #{token}: expected #{source.fetch('sha256')}, got #{actual_sha256}"
      end
    end
  end

  def download_release_asset(gh_bin, token, source, directory)
    arguments = [
      "release", "download", @tag,
      "--repo", @repository,
      "--pattern", source.fetch("name"),
      "--dir", directory,
    ]
    _stdout, stderr, status = Open3.capture3({ "GH_TOKEN" => ENV["GH_TOKEN"] }, gh_bin, *arguments)
    unless status.success?
      raise ReleaseUpdateError, tool_failure("failed to download release asset for #{token}", status, stderr)
    end

    downloaded_path = Pathname(directory).join(source.fetch("name"))
    raise ReleaseUpdateError, "downloaded release asset is missing for #{token}" unless downloaded_path.file?

    downloaded_path
  rescue Errno::ENOENT, Errno::EACCES => error
    raise ReleaseUpdateError, "failed to download release asset for #{token}: #{error.message}"
  end

  def download_tag_archive(curl_bin, token, source, directory)
    downloaded_path = Pathname(directory).join("#{token}.tar.gz")
    arguments = [
      "--fail", "--location", "--silent", "--show-error",
      "--output", downloaded_path.to_s,
      source_url(source),
    ]
    _stdout, stderr, status = Open3.capture3(curl_bin, *arguments)
    unless status.success?
      raise ReleaseUpdateError, tool_failure("failed to download tag archive for #{token}", status, stderr)
    end
    raise ReleaseUpdateError, "downloaded tag archive is missing for #{token}" unless downloaded_path.file?

    downloaded_path
  rescue Errno::ENOENT, Errno::EACCES => error
    raise ReleaseUpdateError, "failed to download tag archive for #{token}: #{error.message}"
  end

  def tool_failure(message, status, stderr)
    detail = stderr.strip
    suffix = detail.empty? ? "" : ": #{detail}"
    "#{message} (exit #{status.exitstatus})#{suffix}"
  end

  def write_transaction(rendered_destinations)
    entries = []
    preflight_destinations(rendered_destinations.keys)
    begin
      stage_destinations(rendered_destinations, entries)
      prepare_backups(entries)
      commit_staged_destinations(entries)
    ensure
      cleanup_transaction_files(entries)
    end
  end

  def preflight_destinations(destinations)
    destinations.each do |destination|
      FileUtils.mkdir_p(destination.dirname)
      unless destination.dirname.directory? && destination.dirname.writable?
        raise ReleaseUpdateError, "destination directory is not writable: #{destination.relative_path_from(ROOT)}"
      end
      if destination.symlink? || (destination.exist? && !destination.file?)
        raise ReleaseUpdateError, "destination is not a regular file: #{destination.relative_path_from(ROOT)}"
      end
    end
  rescue SystemCallError => error
    raise ReleaseUpdateError, "cannot preflight destinations: #{error.message}"
  end

  def stage_destinations(rendered_destinations, entries)
    rendered_destinations.each do |destination, contents|
      next if destination.file? && destination.binread == contents

      entry = {
        destination: destination,
        existed: destination.file?,
        committed: false,
      }
      entries << entry
      temporary_file = Tempfile.create([".update-release-stage-", ".tmp"], destination.dirname.to_s)
      entry[:staged_path] = Pathname(temporary_file.path)
      temporary_file.binmode
      temporary_file.write(contents)
      temporary_file.flush
      temporary_file.fsync
      temporary_file.close
      mode = entry.fetch(:existed) ? destination.stat.mode & 0o777 : 0o644
      File.chmod(mode, entry.fetch(:staged_path))
    rescue SystemCallError => error
      raise ReleaseUpdateError,
            "cannot stage #{destination.relative_path_from(ROOT)}: #{error.message}"
    end
  end

  def prepare_backups(entries)
    entries.each do |entry|
      next unless entry.fetch(:existed)

      destination = entry.fetch(:destination)
      backup_file = Tempfile.create([".update-release-backup-", ".tmp"], destination.dirname.to_s)
      entry[:backup_path] = Pathname(backup_file.path)
      backup_file.close
      FileUtils.copy_file(destination, entry.fetch(:backup_path), true)
    rescue SystemCallError => error
      raise ReleaseUpdateError,
            "cannot prepare backup for #{destination.relative_path_from(ROOT)}: #{error.message}"
    end
  end

  def commit_staged_destinations(entries)
    current_entry = nil
    entries.each do |entry|
      current_entry = entry
      File.rename(entry.fetch(:staged_path), entry.fetch(:destination))
      entry[:committed] = true
    end
  rescue SystemCallError => error
    rollback_errors = rollback_destinations(entries)
    destination = current_entry.fetch(:destination).relative_path_from(ROOT)
    detail = rollback_errors.empty? ? "" : "; rollback failed: #{rollback_errors.join('; ')}"
    raise ReleaseUpdateError, "transactional destination update failed at #{destination}: #{error.message}#{detail}"
  end

  def rollback_destinations(entries)
    errors = []
    entries.reverse_each do |entry|
      next unless entry.fetch(:committed)

      destination = entry.fetch(:destination)
      if entry.fetch(:existed)
        File.rename(entry.fetch(:backup_path), destination)
      elsif destination.file?
        File.unlink(destination)
      end
      entry[:committed] = false
    rescue SystemCallError => error
      errors << "#{destination.relative_path_from(ROOT)}: #{error.message}"
    end
    errors
  end

  def cleanup_transaction_files(entries)
    entries.each do |entry|
      [entry[:staged_path], entry[:backup_path]].compact.each do |path|
        FileUtils.rm_f(path.to_s)
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = ReleaseUpdater.parse_options(ARGV.dup)
    ReleaseUpdater.new(**options).run
  rescue OptionParser::ParseError, ReleaseUpdateError => error
    warn "update-release: #{error.message}"
    exit 64
  end
end
