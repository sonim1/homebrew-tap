# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "pathname"
require "psych"
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
  CI_WORKFLOW = REPOSITORY_ROOT.join(".github/workflows/ci.yml")
  CHECKOUT_ACTION = "actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5"
  CI_CHECKOUT_WITH_KEYS = {
    "contracts" => ["persist-credentials"],
    "homebrew" => ["fetch-depth", "persist-credentials"],
  }.freeze
  CI_STEP_SEQUENCES = {
    "contracts" => %w[checkout ruby-contracts bash-contracts],
    "homebrew" => %w[checkout fetch-main changed-packages],
  }.freeze

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

  def test_rolls_back_every_updatebar_destination_when_the_second_commit_rename_fails
    old_bytes = {
      "Formula/updatebar.rb" => "# old updatebar\nversion \"0.9.0\"\n",
      "Casks/updatebar-app.rb" => "# old updatebar app\nversion \"0.9.0\"\n",
      "Formula/updatebar-tui.rb" => "# old updatebar tui\nversion \"0.9.0\"\n",
    }
    old_bytes.each { |relative_path, contents| write_destination(relative_path, contents) }
    rename_failure_preload = write_rename_failure_preload
    rename_log = @tap.join("rename-calls.log")

    result = run_updater(
      updatebar_manifest,
      repository: "sonim1/UpdateBar",
      environment: {
        "RUBYOPT" => "-r#{rename_failure_preload}",
        "FAKE_RENAME_FAILURE_PATH" => @tap.join("Casks/updatebar-app.rb").to_s,
        "FAKE_RENAME_LOG" => rename_log.to_s,
      },
    )

    refute result.fetch(:status).success?, "rename calls: #{rename_log.file? ? rename_log.read : 'preload not loaded'}"
    old_bytes.each do |relative_path, contents|
      assert_equal contents, @tap.join(relative_path).binread,
                   "#{relative_path} was not rolled back; stderr: #{result.fetch(:stderr)}"
    end
    assert_match(/transactional destination update failed/, result.fetch(:stderr))
    assert_equal %w[gh gh curl], tool_calls.map { |call| call.fetch("tool") }
    assert_empty Dir.glob(@tap.join("{Formula,Casks}/.update-release-*").to_s)
  end

  def test_refuses_to_replace_a_destination_containing_a_newer_version
    destination = @tap.join("Casks/switchtab.rb")
    FileUtils.mkdir_p(destination.dirname)
    destination.write("cask \"switchtab\" do\n  version \"2.0.0\"\nend\n")

    assert_rejected(switchtab_manifest, /refusing to replace switchtab version 2.0.0 with older version 1.0.0/)
  end

  def test_refuses_installed_1_0_1_as_newer_than_incoming_1_0
    write_destination("Casks/switchtab.rb", "cask \"switchtab\" do\n  version \"1.0.1\"\nend\n")

    assert_rejected(switchtab_manifest_for_version("1.0"),
                    /refusing to replace switchtab version 1.0.1 with older version 1.0/,
                    tag: "v1.0")
  end

  def test_allows_incoming_1_0_1_over_installed_1_0
    write_destination("Casks/switchtab.rb", "cask \"switchtab\" do\n  version \"1.0\"\nend\n")

    result = run_updater(switchtab_manifest_for_version("1.0.1"), tag: "v1.0.1")

    assert_success(result)
    assert_includes @tap.join("Casks/switchtab.rb").binread, 'version "1.0.1"'
  end

  def test_treats_1_0_and_1_0_0_as_equivalent_versions
    write_destination("Casks/switchtab.rb", "cask \"switchtab\" do\n  version \"1.0\"\nend\n")

    result = run_updater(switchtab_manifest)

    assert_success(result)
    assert_includes @tap.join("Casks/switchtab.rb").binread, 'version "1.0.0"'
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

  def test_ci_workflow_triggers_only_for_pull_requests_with_read_permissions
    workflow = ci_workflow

    assert_equal({ "pull_request" => nil }, workflow.fetch("on"))
    assert_equal({ "contents" => "read" }, workflow.fetch("permissions"))
  end

  def test_ci_workflow_declares_contracts_and_homebrew_jobs
    jobs = ci_workflow.fetch("jobs")

    assert_equal %w[contracts homebrew], jobs.keys.sort
  end

  def test_contracts_job_runs_pinned_contract_checks_on_linux
    job = ci_workflow.fetch("jobs").fetch("contracts")

    assert_equal "ubuntu-latest", job.fetch("runs-on")
    assert_equal 10, job["timeout-minutes"]
    steps = job.fetch("steps")
    assert_step_sequence("contracts", steps)
    checkout = find_step_with_uses(steps, CHECKOUT_ACTION)
    assert_equal false, checkout.fetch("with").fetch("persist-credentials")
    assert_run_step(steps, "ruby test/update-release-test.rb")
    assert_run_step(steps, "bash test/test-changed-packages-test.sh")
  end

  def test_homebrew_job_fetches_main_and_runs_changed_package_checks_on_macos
    job = ci_workflow.fetch("jobs").fetch("homebrew")

    assert_equal "macos-15", job.fetch("runs-on")
    assert_equal 30, job["timeout-minutes"]
    steps = job.fetch("steps")
    assert_step_sequence("homebrew", steps)
    checkout = find_step_with_uses(steps, CHECKOUT_ACTION)
    assert_equal 0, checkout.fetch("with").fetch("fetch-depth")
    assert_equal false, checkout.fetch("with").fetch("persist-credentials")
    assert_run_step(steps, "git fetch --no-tags origin main:refs/remotes/origin/main")
    assert_run_step(steps, "scripts/test-changed-packages.sh origin/main")
  end

  def test_ci_step_sequence_contracts_reject_reordering_and_extra_steps
    jobs = ci_workflow.fetch("jobs")

    CI_STEP_SEQUENCES.each_key do |job_name|
      steps = jobs.fetch(job_name).fetch("steps")
      assert_raises(Minitest::Assertion) do
        assert_step_sequence(job_name, steps.rotate)
      end
      assert_raises(Minitest::Assertion) do
        assert_step_sequence(job_name, steps + [{ "run" => "echo unexpected" }])
      end
    end
  end

  def test_ci_workflow_has_no_job_secrets_or_write_permissions_and_pins_every_action
    workflow = ci_workflow

    refute workflow.key?("secrets")
    workflow.fetch("jobs").each do |job_name, job|
      refute job.key?("permissions"), "#{job_name} must not override permissions"
      refute job.key?("secrets"), "#{job_name} must not receive secrets"
    end

    collect_uses(workflow).each do |uses|
      assert_match(/\Aactions\/[^@]+@[0-9a-f]{40}\z/, uses)
    end
    refute_match(/\bsecrets\./, CI_WORKFLOW.read)
    refute_match(/\bwrite\b/, workflow.fetch("permissions").values.join(" "))
  end

  private

  def ci_workflow
    assert CI_WORKFLOW.file?, "expected #{CI_WORKFLOW} to exist"

    Psych.safe_load(CI_WORKFLOW.read, aliases: false)
  end

  def find_step_with_uses(steps, uses)
    steps.find { |step| step["uses"] == uses } || flunk("expected a step using #{uses}")
  end

  def assert_step_sequence(job_name, steps)
    assert_equal CI_STEP_SEQUENCES.fetch(job_name), semantic_step_sequence(job_name, steps)
  end

  def semantic_step_sequence(job_name, steps)
    steps.map { |step| semantic_step_signature(job_name, step) }
  end

  def semantic_step_signature(job_name, step)
    return "unexpected:shape:#{step.class}" unless step.is_a?(Hash)

    if checkout_step_shape?(job_name, step)
      return "checkout"
    end
    if step.key?("uses")
      return "unexpected:uses:#{step["uses"]}"
    end
    if step.key?("run")
      return run_step_signature(job_name, step) if step.keys.sort == ["run"]

      return "unexpected:run:#{step["run"]}"
    end

    "unexpected:shape:#{step.keys.sort.join(",")}"
  end

  def checkout_step_shape?(job_name, step)
    step.keys.sort == %w[uses with] &&
      step["uses"] == CHECKOUT_ACTION &&
      step["with"].is_a?(Hash) &&
      step["with"].keys.sort == CI_CHECKOUT_WITH_KEYS.fetch(job_name).sort
  end

  def run_step_signature(job_name, step)
    {
      ["contracts", "ruby test/update-release-test.rb"] => "ruby-contracts",
      ["contracts", "bash test/test-changed-packages-test.sh"] => "bash-contracts",
      ["homebrew", "git fetch --no-tags origin main:refs/remotes/origin/main"] => "fetch-main",
      ["homebrew", "scripts/test-changed-packages.sh origin/main"] => "changed-packages",
    }.fetch([job_name, step.fetch("run")], "unexpected:run:#{step.fetch("run")}")
  end

  def assert_run_step(steps, command)
    assert steps.any? { |step| step["run"] == command }, "expected a step running #{command}"
  end

  def collect_uses(value)
    case value
    when Hash
      value.flat_map { |key, child| key == "uses" ? [child] : collect_uses(child) }
    when Array
      value.flat_map { |child| collect_uses(child) }
    else
      []
    end
  end

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

  def switchtab_manifest_for_version(version)
    asset_name = "SwitchTab-#{version}-1.dmg"
    write_fixture(asset_name, "switchtab #{version} dmg fixture\n")
    manifest = switchtab_manifest
    manifest["tag"] = "v#{version}"
    manifest["version"] = version
    source = manifest.fetch("packages").fetch(0).fetch("source")
    source["name"] = asset_name
    source["sha256"] = fixture_sha256(asset_name)
    manifest
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

  def write_destination(relative_path, contents)
    path = @tap.join(relative_path)
    FileUtils.mkdir_p(path.dirname)
    path.binwrite(contents)
  end

  def write_rename_failure_preload
    preload = @tap.join("fail-destination-rename.rb")
    preload.write(<<~'RUBY')
      class << File
        alias_method :update_release_original_rename, :rename

        def rename(source, destination)
          if ENV["FAKE_RENAME_LOG"]
            File.open(ENV.fetch("FAKE_RENAME_LOG"), "a") { |log| log.puts("#{source}\t#{destination}") }
          end
          failure_path = ENV["FAKE_RENAME_FAILURE_PATH"]
          normalized_destination = File.join(File.realpath(File.dirname(destination.to_s)), File.basename(destination.to_s))
          normalized_failure_path = if failure_path
                                      File.join(File.realpath(File.dirname(failure_path)), File.basename(failure_path))
                                    end
          if !@update_release_rename_failed && failure_path &&
             normalized_destination == normalized_failure_path
            @update_release_rename_failed = true
            raise Errno::EACCES, destination.to_s
          end

          update_release_original_rename(source, destination)
        end
      end
    RUBY
    preload
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
