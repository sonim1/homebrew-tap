# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"

class UpdateReleaseTest < Minitest::Test
  REPOSITORY_ROOT = Pathname(__dir__).join("..").expand_path
  SOURCE_SCRIPT = REPOSITORY_ROOT.join("scripts/update-release.rb")
  DESTINATIONS = [
    "Casks/switchtab.rb",
    "Formula/updatebar.rb",
    "Casks/updatebar-app.rb",
    "Formula/updatebar-tui.rb",
  ].freeze
  TEMPLATES = [
    "Templates/Casks/switchtab.rb.erb",
    "Templates/Formula/updatebar.rb.erb",
    "Templates/Casks/updatebar-app.rb.erb",
    "Templates/Formula/updatebar-tui.rb.erb",
  ].freeze

  def setup
    @temporary_directory = Dir.mktmpdir("update-release-test-")
    @tap = Pathname(@temporary_directory)
    @script = @tap.join("scripts/update-release.rb")
    @manifest_path = @tap.join("release-manifest.json")
    @fixtures = @tap.join("fixtures")
    @tool_log = @tap.join("tool-calls.jsonl")

    FileUtils.mkdir_p([@tap.join("scripts"), @fixtures])
    FileUtils.cp(SOURCE_SCRIPT, @script) if SOURCE_SCRIPT.file?
    TEMPLATES.each do |relative_path|
      source = REPOSITORY_ROOT.join(relative_path)
      next unless source.file?

      destination = @tap.join(relative_path)
      FileUtils.mkdir_p(destination.dirname)
      FileUtils.cp(source, destination)
    end

    @switchtab_asset = "SwitchTab-1.0.0-1.dmg"
    @updatebar_asset = "updatebar-1.0.0-macos-arm64.tar.gz"
    @updatebar_app_asset = "UpdateBar-1.0.0-macos-arm64.dmg"
    write_fixture(@switchtab_asset, "switchtab dmg fixture\n")
    write_fixture(@updatebar_asset, "updatebar cli fixture\n")
    write_fixture(@updatebar_app_asset, "updatebar app fixture\n")
    write_fixture("tag-archive.tar.gz", "github tag archive fixture\n")
    write_fake_tools
  end

  def teardown
    FileUtils.remove_entry(@temporary_directory)
  end

  def test_renders_switchtab_cask_from_a_verified_release_asset
    result = run_updater(switchtab_manifest)

    assert_success(result)
    assert_equal expected_switchtab_cask, @tap.join("Casks/switchtab.rb").binread

    calls = tool_calls
    assert_equal 1, calls.length
    call = calls.fetch(0)
    assert_equal "gh", call.fetch("tool")
    assert_equal "forwarded-token", call.fetch("gh_token")
    assert_equal [
      "release", "download", "v1.0.0",
      "--repo", "sonim1/switchtab",
      "--pattern", @switchtab_asset,
      "--dir",
    ], call.fetch("argv").first(8)
    assert Pathname(call.fetch("argv").fetch(8)).absolute?
  end

  def test_renders_all_exact_updatebar_packages_and_source_kinds
    result = run_updater(updatebar_manifest, repository: "sonim1/UpdateBar")

    assert_success(result)
    assert_equal expected_updatebar_formula, @tap.join("Formula/updatebar.rb").binread
    assert_equal expected_updatebar_app_cask, @tap.join("Casks/updatebar-app.rb").binread
    assert_equal expected_updatebar_tui_formula, @tap.join("Formula/updatebar-tui.rb").binread

    calls = tool_calls
    assert_equal %w[gh gh curl], calls.map { |call| call.fetch("tool") }
    downloaded_assets = calls.first(2).map do |call|
      call.fetch("argv").fetch(6)
    end
    assert_equal [@updatebar_asset, @updatebar_app_asset], downloaded_assets
    curl_arguments = calls.fetch(2).fetch("argv")
    assert_equal ["--fail", "--location", "--silent", "--show-error", "--output"], curl_arguments.first(5)
    assert_equal "https://github.com/sonim1/UpdateBar/archive/refs/tags/v1.0.0.tar.gz", curl_arguments.last
  end

  def test_rejects_malformed_json_without_writing_destinations
    assert_rejected("{ definitely-not-json", /manifest is not valid JSON/)
  end

  def test_rejects_an_unknown_repository_without_writing_destinations
    manifest = switchtab_manifest.merge("repository" => "attacker/project")

    assert_rejected(manifest, /unknown repository/, repository: "attacker/project")
  end

  def test_rejects_every_schema_version_other_than_integer_one
    [2, "1", 1.0, nil].each do |schema_version|
      manifest = switchtab_manifest.merge("schemaVersion" => schema_version)
      assert_rejected(manifest, /schemaVersion must be the integer 1/)
    end
  end

  def test_rejects_repository_mismatch
    manifest = switchtab_manifest.merge("repository" => "sonim1/UpdateBar")

    assert_rejected(manifest, /manifest repository does not match --repository/)
  end

  def test_rejects_tag_mismatch
    assert_rejected(switchtab_manifest, /manifest tag does not match --tag/, tag: "v1.0.1")
  end

  def test_rejects_version_mismatch
    manifest = switchtab_manifest.merge("version" => "1.0.1")

    assert_rejected(manifest, /version must exactly match tag/)
  end

  def test_rejects_non_dot_numeric_version_tags
    ["1.0.0", "v1x0", "v1.0-beta", "v", "v1..0"].each do |tag|
      manifest = switchtab_manifest.merge("tag" => tag, "version" => tag.delete_prefix("v"))
      assert_rejected(manifest, /tag must match/, tag: tag)
    end
  end

  def test_rejects_commits_that_are_not_lowercase_forty_character_hex
    ["a" * 39, "a" * 41, "A" * 40, "g" * 40, 123].each do |commit|
      manifest = switchtab_manifest.merge("commit" => commit)
      assert_rejected(manifest, /commit must be 40 lowercase hexadecimal characters/)
    end
  end

  def test_rejects_empty_or_non_array_packages
    [[], nil, {}].each do |packages|
      manifest = switchtab_manifest.merge("packages" => packages)
      assert_rejected(manifest, /packages must be a non-empty array/)
    end
  end

  def test_rejects_duplicate_tokens
    package = switchtab_manifest.fetch("packages").fetch(0)
    manifest = switchtab_manifest.merge("packages" => [package, Marshal.load(Marshal.dump(package))])

    assert_rejected(manifest, /duplicate package token: switchtab/)
  end

  def test_rejects_unknown_and_missing_tokens
    unknown = switchtab_manifest
    unknown.fetch("packages").fetch(0)["token"] = "attacker"
    assert_rejected(unknown, /unknown package token: attacker/)

    missing = updatebar_manifest
    missing["packages"] = missing.fetch("packages").reject { |package| package.fetch("token") == "updatebar-tui" }
    assert_rejected(missing, /packages must contain exactly/, repository: "sonim1/UpdateBar")
  end

  def test_rejects_wrong_package_types_and_source_kinds
    wrong_type = switchtab_manifest
    wrong_type.fetch("packages").fetch(0)["type"] = "formula"
    assert_rejected(wrong_type, /switchtab must have type cask/)

    wrong_kind = switchtab_manifest
    wrong_kind.fetch("packages").fetch(0).fetch("source")["kind"] = "github-tag-archive"
    wrong_kind.fetch("packages").fetch(0).fetch("source").delete("name")
    assert_rejected(wrong_kind, /switchtab must have source kind release-asset/)

    wrong_tui_kind = updatebar_manifest
    source = wrong_tui_kind.fetch("packages").find { |package| package.fetch("token") == "updatebar-tui" }.fetch("source")
    source["kind"] = "release-asset"
    source["name"] = "archive.tar.gz"
    assert_rejected(wrong_tui_kind, /updatebar-tui must have source kind github-tag-archive/,
                    repository: "sonim1/UpdateBar")
  end

  def test_rejects_sha256_values_that_are_not_lowercase_sixty_four_character_hex
    ["a" * 63, "a" * 65, "A" * 64, "g" * 64, 123].each do |sha256|
      manifest = switchtab_manifest
      manifest.fetch("packages").fetch(0).fetch("source")["sha256"] = sha256
      assert_rejected(manifest, /sha256 must be 64 lowercase hexadecimal characters/)
    end
  end

  def test_rejects_unsafe_release_asset_names
    ["../asset.dmg", "directory/asset.dmg", ".hidden", "asset name.dmg", "asset?.dmg", ""].each do |name|
      manifest = switchtab_manifest
      manifest.fetch("packages").fetch(0).fetch("source")["name"] = name
      assert_rejected(manifest, /release asset name must be a safe basename/)
    end
  end

  def test_rejects_noncanonical_switchtab_release_asset_names
    ["SwitchTab-2.0.0-1.dmg", "SwitchTab-1.0.0-beta.dmg", "SwitchTab-1.0.0-1.zip"].each do |name|
      manifest = switchtab_manifest
      manifest.fetch("packages").fetch(0).fetch("source")["name"] = name
      assert_rejected(manifest, /switchtab release asset name must match SwitchTab-1\.0\.0-<numeric build>\.dmg/)
    end
  end

  def test_rejects_noncanonical_updatebar_cli_release_asset_names
    ["updatebar-2.0.0-macos-arm64.tar.gz", "updatebar-1.0.0-macos-arm64.zip"].each do |name|
      manifest = updatebar_manifest
      cli_source = manifest.fetch("packages").find { |package| package.fetch("token") == "updatebar" }.fetch("source")
      cli_source["name"] = name
      assert_rejected(manifest, /updatebar release asset name must be updatebar-1\.0\.0-macos-arm64\.tar\.gz/,
                      repository: "sonim1/UpdateBar")
    end
  end

  def test_rejects_noncanonical_updatebar_app_release_asset_names
    ["UpdateBar-2.0.0-macos-arm64.dmg", "UpdateBar-1.0.0-macos-arm64.zip"].each do |name|
      manifest = updatebar_manifest
      app_source = manifest.fetch("packages").find { |package| package.fetch("token") == "updatebar-app" }.fetch("source")
      app_source["name"] = name
      assert_rejected(manifest, /updatebar-app release asset name must be UpdateBar-1\.0\.0-macos-arm64\.dmg/,
                      repository: "sonim1/UpdateBar")
    end
  end

  def test_rejects_an_asset_name_for_a_github_tag_archive
    manifest = updatebar_manifest
    tui_source = manifest.fetch("packages").find { |package| package.fetch("token") == "updatebar-tui" }.fetch("source")
    tui_source["name"] = "v1.0.0.tar.gz"

    assert_rejected(manifest, /github-tag-archive source must not contain name/,
                    repository: "sonim1/UpdateBar")
  end

  def test_rejects_unexpected_manifest_fields_instead_of_trusting_paths_or_urls
    manifest = switchtab_manifest.merge("destination" => "Formula/attacker.rb")
    manifest.fetch("packages").fetch(0).fetch("source")["url"] = "https://attacker.example/payload"

    assert_rejected(manifest, /unexpected manifest field: destination/)
  end

  def test_rejects_a_checksum_mismatch_without_writing_any_destination
    manifest = switchtab_manifest
    manifest.fetch("packages").fetch(0).fetch("source")["sha256"] = "0" * 64

    assert_rejected(manifest, /checksum mismatch for switchtab/)
  end

  def test_keeps_all_destinations_untouched_when_a_later_checksum_fails
    seed_all_destinations
    manifest = updatebar_manifest
    app_source = manifest.fetch("packages").find { |package| package.fetch("token") == "updatebar-app" }.fetch("source")
    app_source["sha256"] = "0" * 64

    assert_rejected(manifest, /checksum mismatch for updatebar-app/, repository: "sonim1/UpdateBar")
  end

  def test_keeps_all_destinations_untouched_when_gh_download_fails
    seed_all_destinations

    assert_rejected(switchtab_manifest, /failed to download release asset for switchtab/,
                    environment: { "FAKE_GH_FAIL" => "1" })
  end

  def test_keeps_all_destinations_untouched_when_curl_download_fails
    seed_all_destinations

    assert_rejected(updatebar_manifest, /failed to download tag archive for updatebar-tui/,
                    repository: "sonim1/UpdateBar", environment: { "FAKE_CURL_FAIL" => "1" })
  end

  def test_refuses_to_replace_a_destination_containing_a_newer_version
    destination = @tap.join("Casks/switchtab.rb")
    FileUtils.mkdir_p(destination.dirname)
    destination.write("cask \"switchtab\" do\n  version \"2.0.0\"\nend\n")

    assert_rejected(switchtab_manifest, /refusing to replace switchtab version 2.0.0 with older version 1.0.0/)
  end

  def test_a_byte_identical_rerun_succeeds
    first_result = run_updater(updatebar_manifest, repository: "sonim1/UpdateBar")
    assert_success(first_result)
    first_bytes = DESTINATIONS.each_with_object({}) do |relative_path, bytes_by_path|
      path = @tap.join(relative_path)
      bytes_by_path[relative_path] = path.binread if path.file?
    end

    second_result = run_updater(updatebar_manifest, repository: "sonim1/UpdateBar")

    assert_success(second_result)
    assert_equal first_bytes, first_bytes.keys.to_h { |relative_path| [relative_path, @tap.join(relative_path).binread] }
  end

  def test_verify_only_validates_without_downloading_or_writing
    result = run_updater(updatebar_manifest, repository: "sonim1/UpdateBar",
                                            environment: { "TAP_VERIFY_ONLY" => "1" })

    assert_success(result)
    assert_empty tool_calls
    DESTINATIONS.each { |relative_path| refute @tap.join(relative_path).exist? }
  end

  def test_requires_the_manifest_environment_variable_and_exact_cli_options
    missing_manifest = invoke(["--repository", "sonim1/switchtab", "--tag", "v1.0.0"],
                              "TAP_MANIFEST_FILE" => nil)
    assert_equal 64, missing_manifest.fetch(:status).exitstatus
    assert_match(/TAP_MANIFEST_FILE is required/, missing_manifest.fetch(:stderr))

    abbreviated_option = invoke(["--repo", "sonim1/switchtab", "--tag", "v1.0.0"])
    assert_equal 64, abbreviated_option.fetch(:status).exitstatus
    assert_match(/invalid option/, abbreviated_option.fetch(:stderr))
  end

  private

  def switchtab_manifest
    {
      "schemaVersion" => 1,
      "repository" => "sonim1/switchtab",
      "tag" => "v1.0.0",
      "version" => "1.0.0",
      "commit" => "a" * 40,
      "packages" => [
        {
          "type" => "cask",
          "token" => "switchtab",
          "source" => {
            "kind" => "release-asset",
            "name" => @switchtab_asset,
            "sha256" => fixture_sha256(@switchtab_asset),
          },
        },
      ],
    }
  end

  def updatebar_manifest
    {
      "schemaVersion" => 1,
      "repository" => "sonim1/UpdateBar",
      "tag" => "v1.0.0",
      "version" => "1.0.0",
      "commit" => "b" * 40,
      "packages" => [
        {
          "type" => "formula",
          "token" => "updatebar",
          "source" => {
            "kind" => "release-asset",
            "name" => @updatebar_asset,
            "sha256" => fixture_sha256(@updatebar_asset),
          },
        },
        {
          "type" => "cask",
          "token" => "updatebar-app",
          "source" => {
            "kind" => "release-asset",
            "name" => @updatebar_app_asset,
            "sha256" => fixture_sha256(@updatebar_app_asset),
          },
        },
        {
          "type" => "formula",
          "token" => "updatebar-tui",
          "source" => {
            "kind" => "github-tag-archive",
            "sha256" => fixture_sha256("tag-archive.tar.gz"),
          },
        },
      ],
    }
  end

  def run_updater(manifest, repository: "sonim1/switchtab", tag: "v1.0.0", environment: {})
    contents = manifest.is_a?(String) ? manifest : JSON.generate(manifest)
    @manifest_path.binwrite(contents)
    invoke(["--repository", repository, "--tag", tag], environment)
  end

  def invoke(arguments, environment = {})
    env = {
      "TAP_MANIFEST_FILE" => @manifest_path.to_s,
      "TAP_VERIFY_ONLY" => nil,
      "GH_BIN" => @tap.join("fake-gh").to_s,
      "CURL_BIN" => @tap.join("fake-curl").to_s,
      "GH_TOKEN" => "forwarded-token",
      "FAKE_FIXTURE_DIRECTORY" => @fixtures.to_s,
      "FAKE_TOOL_LOG" => @tool_log.to_s,
      "FAKE_GH_FAIL" => "0",
      "FAKE_CURL_FAIL" => "0",
    }.merge(environment)
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, @script.to_s, *arguments, chdir: @tap.to_s)
    { stdout: stdout, stderr: stderr, status: status }
  end

  def assert_success(result)
    assert result.fetch(:status).success?, <<~MESSAGE
      updater failed with exit #{result.fetch(:status).exitstatus}
      stdout: #{result.fetch(:stdout)}
      stderr: #{result.fetch(:stderr)}
    MESSAGE
    assert_equal "", result.fetch(:stderr)
  end

  def assert_rejected(manifest, expected_error, repository: "sonim1/switchtab", tag: "v1.0.0", environment: {})
    before = destination_snapshot
    result = run_updater(manifest, repository: repository, tag: tag, environment: environment)

    assert_equal 64, result.fetch(:status).exitstatus, result.fetch(:stderr)
    assert_match expected_error, result.fetch(:stderr)
    assert_equal before, destination_snapshot, "a rejected manifest changed an allowlisted destination"
  end

  def destination_snapshot
    DESTINATIONS.to_h do |relative_path|
      path = @tap.join(relative_path)
      [relative_path, path.file? ? [true, path.binread] : [false, nil]]
    end
  end

  def seed_all_destinations
    DESTINATIONS.each do |relative_path|
      path = @tap.join(relative_path)
      FileUtils.mkdir_p(path.dirname)
      path.write("# sentinel for #{relative_path}\nversion \"0.0.1\"\n")
    end
  end

  def write_fixture(name, contents)
    @fixtures.join(name).binwrite(contents)
  end

  def fixture_sha256(name)
    Digest::SHA256.file(@fixtures.join(name)).hexdigest
  end

  def tool_calls
    return [] unless @tool_log.file?

    @tool_log.readlines(chomp: true).map { |line| JSON.parse(line) }
  end

  def write_fake_tools
    gh = @tap.join("fake-gh")
    gh.write(<<~'RUBY')
      #!/usr/bin/env ruby
      require "fileutils"
      require "json"

      File.open(ENV.fetch("FAKE_TOOL_LOG"), "a") do |log|
        log.puts(JSON.generate("tool" => "gh", "gh_token" => ENV["GH_TOKEN"], "argv" => ARGV))
      end
      exit 42 if ENV["FAKE_GH_FAIL"] == "1"

      pattern = ARGV.fetch(ARGV.index("--pattern") + 1)
      destination = ARGV.fetch(ARGV.index("--dir") + 1)
      FileUtils.cp(File.join(ENV.fetch("FAKE_FIXTURE_DIRECTORY"), pattern), File.join(destination, pattern))
    RUBY
    FileUtils.chmod(0o755, gh)

    curl = @tap.join("fake-curl")
    curl.write(<<~'RUBY')
      #!/usr/bin/env ruby
      require "fileutils"
      require "json"

      File.open(ENV.fetch("FAKE_TOOL_LOG"), "a") do |log|
        log.puts(JSON.generate("tool" => "curl", "argv" => ARGV))
      end
      exit 43 if ENV["FAKE_CURL_FAIL"] == "1"

      output = ARGV.fetch(ARGV.index("--output") + 1)
      source = File.join(ENV.fetch("FAKE_FIXTURE_DIRECTORY"), "tag-archive.tar.gz")
      FileUtils.cp(source, output)
    RUBY
    FileUtils.chmod(0o755, curl)
  end

  def expected_switchtab_cask
    <<~RUBY
      # frozen_string_literal: true

      cask "switchtab" do
        version "1.0.0"
        sha256 "#{fixture_sha256(@switchtab_asset)}"

        url "https://github.com/sonim1/switchtab/releases/download/v1.0.0/#{@switchtab_asset}"
        name "SwitchTab"
        desc "Fast macOS application switcher"
        homepage "https://github.com/sonim1/switchtab"

        depends_on arch: :arm64
        depends_on macos: :ventura

        app "SwitchTab.app"
      end
    RUBY
  end

  def expected_updatebar_formula
    <<~RUBY
      # typed: strict
      # frozen_string_literal: true

      # Formula for UpdateBar.
      class Updatebar < Formula
        desc "CLI-first update tracker for local tools"
        homepage "https://github.com/sonim1/UpdateBar"
        url "https://github.com/sonim1/UpdateBar/releases/download/v1.0.0/#{@updatebar_asset}"
        version "1.0.0"
        sha256 "#{fixture_sha256(@updatebar_asset)}"

        depends_on arch: :arm64
        depends_on macos: :ventura

        def install
          bin.install "updatebar"
        end

        test do
          assert_match version.to_s, shell_output("\#{bin}/updatebar --version").strip
        end
      end
    RUBY
  end

  def expected_updatebar_app_cask
    <<~RUBY
      # frozen_string_literal: true

      cask "updatebar-app" do
        version "1.0.0"
        sha256 "#{fixture_sha256(@updatebar_app_asset)}"

        url "https://github.com/sonim1/UpdateBar/releases/download/v1.0.0/#{@updatebar_app_asset}"
        name "UpdateBar"
        desc "Menu bar update tracker for local tools"
        homepage "https://github.com/sonim1/UpdateBar"

        depends_on arch: :arm64
        depends_on macos: :ventura

        app "UpdateBar.app"

        zap trash: [
          "~/.updatebar",
          "~/Library/Logs/UpdateBar",
          "~/Library/Preferences/com.sonim1.UpdateBar.plist",
        ]

        caveats <<~EOS
          For the updatebar CLI, install the formula:
            brew install sonim1/tap/updatebar

          For the Open TUI menu item, install the terminal UI:
            brew install sonim1/tap/updatebar-tui
        EOS
      end
    RUBY
  end

  def expected_updatebar_tui_formula
    <<~RUBY
      # typed: strict
      # frozen_string_literal: true

      # Ink terminal UI companion formula for the UpdateBar CLI.
      class UpdatebarTui < Formula
        desc "Ink terminal UI for UpdateBar"
        homepage "https://github.com/sonim1/UpdateBar"
        url "https://github.com/sonim1/UpdateBar/archive/refs/tags/v1.0.0.tar.gz"
        version "1.0.0"
        sha256 "#{fixture_sha256("tag-archive.tar.gz")}"
        license "MIT"

        depends_on "node"

        def install
          cd "tui" do
            system "npm", "ci", *std_npm_args(prefix: false)
            system "npm", "run", "build"
            system "npm", "prune", "--omit=dev"
            libexec.install "dist", "node_modules", "package.json"
          end
          bin.install_symlink libexec/"dist/index.js" => "updatebar-tui"
        end

        def caveats
          <<~EOS
            updatebar-tui talks to the updatebar CLI. Install it with:
              brew install sonim1/tap/updatebar
          EOS
        end

        test do
          assert_predicate bin/"updatebar-tui", :executable?
        end
      end
    RUBY
  end
end
