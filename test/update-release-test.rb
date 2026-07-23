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
  UPDATE_WORKFLOW = REPOSITORY_ROOT.join(".github/workflows/update-package.yml")
  CHECKOUT_ACTION = "actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5"
  APP_TOKEN_ACTION = "actions/create-github-app-token@67018539274d69449ef7c02e8e71183d1719ab42"

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

  def test_accepts_every_switchtab_producer_build_version_shape
    %w[1 1.1 1.1.1].each do |build_version|
      asset_name = "SwitchTab-1.0.0-#{build_version}.dmg"
      write_fixture(asset_name, "switchtab #{build_version} dmg fixture\n")
      manifest = switchtab_manifest
      source = manifest.fetch("packages").fetch(0).fetch("source")
      source["name"] = asset_name
      source["sha256"] = fixture_sha256(asset_name)

      result = run_updater(manifest)

      assert_success(result)
      assert_includes @tap.join("Casks/switchtab.rb").binread, asset_name
    end
  end

  def test_rejects_build_versions_outside_the_switchtab_producer_contract
    ["", "1.1.1.1", "1.beta", "../1"].each do |build_version|
      manifest = switchtab_manifest
      manifest.fetch("packages").fetch(0).fetch("source")["name"] =
        "SwitchTab-1.0.0-#{build_version}.dmg"

      assert_rejected(manifest, /release asset name/)
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
    assert_equal %w[checkout ruby-contracts bash-contracts],
                 job.fetch("steps").map { |step| normalize_ci_step("contracts", step) }
  end

  def test_homebrew_job_fetches_main_and_runs_changed_package_checks_on_macos
    job = ci_workflow.fetch("jobs").fetch("homebrew")

    assert_equal "macos-15", job.fetch("runs-on")
    assert_equal 30, job["timeout-minutes"]
    assert_equal %w[checkout fetch-main changed-packages],
                 job.fetch("steps").map { |step| normalize_ci_step("homebrew", step) }
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

  def test_update_workflow_accepts_only_typed_release_dispatches
    workflow = update_workflow

    assert_equal "Update package", workflow.fetch("name")
    assert_equal({ "repository_dispatch" => { "types" => ["homebrew_release"] } }, workflow.fetch("on"))
    assert_equal({ "contents" => "read" }, workflow.fetch("permissions"))
    assert_equal({
      "group" => "homebrew-release-${{ github.event.client_payload.repository }}-${{ github.event.client_payload.tag }}",
      "cancel-in-progress" => false,
    }, workflow.fetch("concurrency"))
  end

  def test_update_workflow_has_one_bounded_update_job_with_read_only_default_token
    jobs = update_workflow.fetch("jobs")
    assert_equal ["update"], jobs.keys

    job = jobs.fetch("update")
    assert_equal "ubuntu-latest", job.fetch("runs-on")
    assert_equal 15, job.fetch("timeout-minutes")
    assert_equal({ "contents" => "read" }, job.fetch("permissions"))
    refute job.key?("secrets")
    assert_equal %w[validate download-manifest app-token preflight checkout prepare-branch update-packages publish-pr],
                 job.fetch("steps").map { |step| step.fetch("id") }
  end

  def test_update_workflow_uses_the_restricted_app_token_for_checkout
    app_token = update_step("app-token")
    assert_equal APP_TOKEN_ACTION, app_token.fetch("uses")
    assert_equal({
      "app-id" => "${{ vars.TAP_GITHUB_APP_ID }}",
      "private-key" => "${{ secrets.TAP_GITHUB_APP_PRIVATE_KEY }}",
      "owner" => "sonim1",
      "repositories" => "homebrew-tap",
      "permission-administration" => "read",
      "permission-contents" => "write",
      "permission-pull-requests" => "write",
    }, app_token.fetch("with"))

    checkout = update_step("checkout")
    assert_equal CHECKOUT_ACTION, checkout.fetch("uses")
    assert_equal({
      "token" => "${{ steps.app-token.outputs.token }}",
      "fetch-depth" => 0,
      "persist-credentials" => false,
    }, checkout.fetch("with"))
  end

  def test_update_workflow_separates_read_and_app_tokens
    steps = update_workflow.fetch("jobs").fetch("update").fetch("steps")
    app_token = "${{ steps.app-token.outputs.token }}"
    read_token = "${{ github.token }}"

    assert_equal %w[preflight publish-pr],
                 steps.select { |step| step.dig("env", "GH_TOKEN") == app_token }.map { |step| step.fetch("id") }
    assert_equal %w[download-manifest update-packages],
                 steps.select { |step| step.dig("env", "GH_TOKEN") == read_token }.map { |step| step.fetch("id") }
    refute_match(/https?:\/\/[^\s]*\$\{\{\s*steps\.app-token\.outputs\.token/, UPDATE_WORKFLOW.read)
    refute_match(/base64|http\.extraheader/i, UPDATE_WORKFLOW.read)
  end

  def test_update_workflow_preflight_fails_closed_on_repository_and_protection_settings
    step = update_step("preflight")
    assert_equal({ "GH_TOKEN" => "${{ steps.app-token.outputs.token }}" }, step.fetch("env"))

    script = step.fetch("run")
    assert_shell_strict(script)
    assert_includes script, "gh api repos/sonim1/homebrew-tap"
    assert_includes script, ".allow_auto_merge == true"
    assert_includes script, "repos/sonim1/homebrew-tap/branches/main/protection/required_status_checks"
    assert_includes script, '["contracts", "homebrew"]'
    assert_includes script, ".contexts"
    assert_includes script, ".checks"
    assert_includes script, "jq -e"

    step_ids = update_workflow.fetch("jobs").fetch("update").fetch("steps").map { |candidate| candidate.fetch("id") }
    assert_operator step_ids.index("preflight"), :<, step_ids.index("prepare-branch")
    assert_operator step_ids.index("preflight"), :<, step_ids.index("publish-pr")
  end

  def test_preflight_accepts_exact_required_contexts_from_both_api_schemas
    %w[contexts checks].each do |schema|
      clear_workflow_tool_state
      result = run_workflow_step("preflight", environment: { "FAKE_PROTECTION_SCHEMA" => schema })

      assert result.fetch(:status).success?, "#{schema}: #{result.fetch(:stderr)}"
    end
  end

  def test_preflight_failure_stops_the_sequence_before_any_branch_push
    repository = create_workflow_repository
    result = run_workflow_sequence(
      %w[preflight publish-pr],
      directory: repository.fetch(:worktree),
      environment: workflow_publish_environment.merge("FAKE_PROTECTION_SCHEMA" => "missing-homebrew"),
    )

    assert_equal ["preflight"], result.fetch(:steps)
    refute result.fetch(:status).success?
    assert_equal 2, remote_branch_status(repository.fetch(:remote), "release/switchtab-1.2.3")
    assert_equal %w[api api], workflow_tool_calls.map { |call| call.fetch("argv").first }
  end

  def test_preflight_rejects_false_or_missing_strict_status_check_enforcement_before_mutation
    repository = create_workflow_repository
    %w[strict-false strict-missing].each do |schema|
      clear_workflow_tool_state
      result = run_workflow_sequence(
        %w[preflight publish-pr],
        directory: repository.fetch(:worktree),
        environment: workflow_publish_environment.merge("FAKE_PROTECTION_SCHEMA" => schema),
      )

      assert_equal ["preflight"], result.fetch(:steps), schema
      refute result.fetch(:status).success?, schema
      assert_equal 2, remote_branch_status(repository.fetch(:remote), "release/switchtab-1.2.3"), schema
      assert_equal %w[api api], workflow_tool_calls.map { |call| call.fetch("argv").first }, schema
    end
  end

  def test_preflight_propagates_repository_api_failures
    [
      { "FAKE_AUTO_MERGE" => "api-error" },
      { "FAKE_PROTECTION_SCHEMA" => "api-error" },
    ].each do |environment|
      clear_workflow_tool_state
      result = run_workflow_step("preflight", environment: environment)

      refute result.fetch(:status).success?
      assert_equal 22, result.fetch(:status).exitstatus
    end
  end

  def test_preflight_rejects_disabled_auto_merge
    result = run_workflow_step("preflight", environment: { "FAKE_AUTO_MERGE" => "false" })

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "Repository auto-merge must be enabled"
  end

  def test_update_workflow_validates_inert_payload_values_and_derives_both_products
    step = update_step("validate")
    assert_equal({
      "PAYLOAD_REPOSITORY" => "${{ github.event.client_payload.repository }}",
      "PAYLOAD_TAG" => "${{ github.event.client_payload.tag }}",
    }, step.fetch("env"))

    script = step.fetch("run")
    assert_shell_strict(script)
    assert_includes script, 'SOURCE_REPOSITORY="$PAYLOAD_REPOSITORY"'
    assert_includes script, 'RELEASE_TAG="$PAYLOAD_TAG"'
    assert_match(/sonim1\/switchtab\).*?PRODUCT="switchtab"/m, script)
    assert_match(/sonim1\/UpdateBar\).*?PRODUCT="updatebar"/m, script)
    assert_includes script, '[[ ! "$RELEASE_TAG" =~ ^v[0-9]+([.][0-9]+)*$ ]]'
    assert_includes script, 'VERSION="${RELEASE_TAG#v}"'
    assert_includes script, 'RELEASE_BRANCH="release/${PRODUCT}-${VERSION}"'
    assert_includes script, '>> "$GITHUB_ENV"'
    assert_includes script, '>> "$GITHUB_OUTPUT"'
    refute_match(/\$\{\{\s*github\.event\.client_payload\./, script)
    refute_match(/\b(?:gh|git)\b/, script)
  end

  def test_update_workflow_prepares_the_deterministic_branch_before_running_the_updater
    prepare = update_step("prepare-branch").fetch("run")
    assert_shell_strict(prepare)
    assert_includes prepare, "git fetch --no-tags origin main:refs/remotes/origin/main"
    assert_includes prepare, 'git ls-remote --exit-code --heads origin "refs/heads/$RELEASE_BRANCH"'
    assert_includes prepare, 'case "$LS_REMOTE_STATUS" in'
    assert_match(/2\).*?REMOTE_BRANCH_SHA=""/m, prepare)
    assert_includes prepare, 'exit "$LS_REMOTE_STATUS"'
    assert_includes prepare,
                    'git fetch --no-tags origin "refs/heads/$RELEASE_BRANCH:refs/remotes/origin/$RELEASE_BRANCH"'
    assert_includes prepare, 'REMOTE_BRANCH_SHA="$(git rev-parse "refs/remotes/origin/$RELEASE_BRANCH")"'
    assert_includes prepare, 'git checkout -B "$RELEASE_BRANCH" origin/main'

    step_ids = update_workflow.fetch("jobs").fetch("update").fetch("steps").map { |step| step.fetch("id") }
    assert_operator step_ids.index("validate"), :<, step_ids.index("prepare-branch")
    assert_operator step_ids.index("download-manifest"), :<, step_ids.index("prepare-branch")
    assert_operator step_ids.index("prepare-branch"), :<, step_ids.index("update-packages")
  end

  def test_prepare_branch_propagates_ls_remote_auth_or_network_failures
    repository = create_workflow_repository
    fake_git_bin = write_failing_ls_remote_git

    result = run_workflow_step(
      "prepare-branch",
      directory: repository.fetch(:worktree),
      environment: workflow_publish_environment.merge(
        "PATH" => "#{fake_git_bin}:#{workflow_environment.fetch('PATH')}",
        "FAKE_LS_REMOTE_STATUS" => "73",
        "REAL_GIT" => git_executable,
      ),
    )

    refute result.fetch(:status).success?
    assert_equal 73, result.fetch(:status).exitstatus
    assert_equal "main", git_success!(repository.fetch(:worktree), "branch", "--show-current")
  end

  def test_prepare_branch_treats_ls_remote_status_two_as_absent
    repository = create_workflow_repository

    result = run_workflow_step(
      "prepare-branch",
      directory: repository.fetch(:worktree),
      environment: workflow_publish_environment,
    )

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_equal "release/switchtab-1.2.3",
                 git_success!(repository.fetch(:worktree), "branch", "--show-current")
    assert_includes @tap.join("workflow-github-env").read, "REMOTE_BRANCH_SHA=\n"
  end

  def test_update_workflow_downloads_only_the_exact_manifest_with_the_read_token
    step = update_step("download-manifest")
    assert_equal({ "GH_TOKEN" => "${{ github.token }}" }, step.fetch("env"))

    script = step.fetch("run")
    assert_shell_strict(script)
    assert_includes script, 'MANIFEST_FILE="$RUNNER_TEMP/release-manifest.json"'
    assert_includes script, '[[ -e "$MANIFEST_FILE" || -L "$MANIFEST_FILE" ]]'
    assert_includes script, 'gh release download "$RELEASE_TAG"'
    assert_includes script, '--repo "$SOURCE_REPOSITORY"'
    assert_includes script, '--pattern "release-manifest.json"'
    assert_includes script, '--dir "$RUNNER_TEMP"'
    assert_includes script, '[[ ! -f "$MANIFEST_FILE" || -L "$MANIFEST_FILE" ]]'
    refute_includes script, "${{ steps.app-token.outputs.token }}"
  end

  def test_update_workflow_runs_the_allowlisted_updater_with_only_validated_inputs
    step = update_step("update-packages")
    assert_equal({ "GH_TOKEN" => "${{ github.token }}" }, step.fetch("env"))

    script = step.fetch("run")
    assert_shell_strict(script)
    assert_includes script,
                    'TAP_MANIFEST_FILE="$MANIFEST_FILE" GH_TOKEN="$GH_TOKEN" ruby scripts/update-release.rb '
    assert_includes script, '--repository "$SOURCE_REPOSITORY" --tag "$RELEASE_TAG"'

    payload_fields = UPDATE_WORKFLOW.read.scan(/github\.event\.client_payload\.([A-Za-z0-9_-]+)/).flatten.uniq.sort
    assert_equal %w[repository tag], payload_fields
  end

  def test_update_workflow_stages_only_packages_and_safely_updates_one_pr
    step = update_step("publish-pr")
    assert_equal({ "GH_TOKEN" => "${{ steps.app-token.outputs.token }}" }, step.fetch("env"))

    script = step.fetch("run")
    assert_shell_strict(script)
    assert_match(/switchtab\).*?package_files=\("Casks\/switchtab\.rb"\)/m, script)
    assert_match(
      /updatebar\).*?package_files=\("Formula\/updatebar\.rb" "Formula\/updatebar-tui\.rb" "Casks\/updatebar-app\.rb"\)/m,
      script,
    )
    assert_includes script, "git diff --name-only -z HEAD --"
    assert_includes script, "git ls-files --others --exclude-standard -z -- Formula/ Casks/"
    assert_includes script, 'git add -- "${package_files[@]}"'
    assert_includes script, "git diff --cached --name-only -z --"
    assert_includes script, 'PUBLISH_TEMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-}}"'
    assert_includes script, 'PUBLISH_TEMP_DIR="$(mktemp -d "$PUBLISH_TEMP_ROOT/tap-publish.XXXXXX")"'
    assert_includes script, 'git diff --name-only -z HEAD -- > "$TRACKED_PATHS_FILE"'
    assert_includes script,
                    'git ls-files --others --exclude-standard -z -- Formula/ Casks/ > "$UNTRACKED_PATHS_FILE"'
    assert_includes script, 'git diff --cached --name-only -z -- > "$STAGED_PATHS_FILE"'
    assert_includes script, 'done < "$TRACKED_PATHS_FILE"'
    assert_includes script, 'done < "$UNTRACKED_PATHS_FILE"'
    assert_includes script, 'done < "$STAGED_PATHS_FILE"'
    refute_match(/done\s+<\s+<\(git\s+(?:diff|ls-files)\b/, script)
    assert_includes script,
                    'rm -f -- "$TRACKED_PATHS_FILE" "$UNTRACKED_PATHS_FILE" "$STAGED_PATHS_FILE"'
    assert_includes script, 'rmdir -- "$PUBLISH_TEMP_DIR"'
    refute_includes script, "git add -- Formula/ Casks/"
    assert_includes script, "No package changes; nothing to publish."
    assert_includes script, 'git config user.name "homebrew-release-bot[bot]"'
    assert_includes script, 'git config user.email "homebrew-release-bot[bot]@users.noreply.github.com"'
    assert_includes script, 'git commit -m "chore(${PRODUCT}): update to ${VERSION}"'
    assert_includes script, "trap cleanup_publish EXIT"
    assert_includes script, "git config --local credential.helper '!gh auth git-credential'"
    assert_includes script, "git config --local --unset-all credential.helper"
    assert_includes script, 'git push --force-with-lease="$LEASE" origin "HEAD:refs/heads/${RELEASE_BRANCH}"'
    refute_match(/git push[^\n]*--force(?:\s|$)/, script)
    assert_includes script, "gh api --method GET repos/sonim1/homebrew-tap/pulls"
    assert_includes script, '-f "head=sonim1:${RELEASE_BRANCH}"'
    refute_includes script, "gh pr list"
    assert_includes script,
                    'gh pr create --repo sonim1/homebrew-tap --base main --head "$RELEASE_BRANCH"'
    assert_includes script, 'CREATE_STATUS=$?'
    assert_operator script.scan("gh api --method GET repos/sonim1/homebrew-tap/pulls").length, :>=, 1
    assert_includes script, 'HEAD_COMMIT="$(git rev-parse HEAD)"'
    assert_includes script,
                    'gh pr merge "$PR_NUMBER" --repo sonim1/homebrew-tap --auto --squash --match-head-commit "$HEAD_COMMIT"'
    assert_operator script.index("trap cleanup_publish EXIT"), :<,
                    script.index('git diff --name-only -z HEAD -- > "$TRACKED_PATHS_FILE"')
  end

  def test_publish_propagates_tracked_diff_producer_failure
    assert_publish_propagates_git_enumeration_failure("tracked")
  end

  def test_publish_propagates_untracked_ls_files_producer_failure
    assert_publish_propagates_git_enumeration_failure("untracked")
  end

  def test_publish_propagates_staged_diff_producer_failure
    assert_publish_propagates_git_enumeration_failure("staged", package_change: true)
  end

  def test_publish_rejects_an_unexpected_untracked_package_path_nul_safely
    repository = create_workflow_repository
    worktree = repository.fetch(:worktree)
    git_success!(worktree, "checkout", "-b", "release/switchtab-1.2.3")
    worktree.join("Casks/switchtab.rb").write("switchtab v2\n")
    worktree.join("Casks/unexpected\nname.rb").write("unexpected\n")

    result = run_workflow_step(
      "publish-pr",
      directory: worktree,
      environment: workflow_publish_environment,
    )

    refute result.fetch(:status).success?
    assert_equal 2, remote_branch_status(repository.fetch(:remote), "release/switchtab-1.2.3")
    assert_empty workflow_tool_calls
  end

  def test_publish_rejects_a_tracked_package_outside_the_selected_product_allowlist
    repository = create_workflow_repository
    worktree = repository.fetch(:worktree)
    git_success!(worktree, "checkout", "-b", "release/switchtab-1.2.3")
    worktree.join("Casks/switchtab.rb").write("switchtab v2\n")
    worktree.join("Formula/updatebar.rb").write("unexpected updatebar change\n")

    result = run_workflow_step(
      "publish-pr",
      directory: worktree,
      environment: workflow_publish_environment,
    )

    refute result.fetch(:status).success?
    assert_equal 2, remote_branch_status(repository.fetch(:remote), "release/switchtab-1.2.3")
    assert_empty workflow_tool_calls
  end

  def test_publish_no_diff_exits_without_push_or_pull_request
    repository = create_workflow_repository
    worktree = repository.fetch(:worktree)
    git_success!(worktree, "checkout", "-b", "release/switchtab-1.2.3")
    original_head = git_success!(worktree, "rev-parse", "HEAD")

    result = run_workflow_step(
      "publish-pr",
      directory: worktree,
      environment: workflow_publish_environment,
    )

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_includes result.fetch(:stdout), "No package changes; nothing to publish."
    assert_equal original_head, git_success!(worktree, "rev-parse", "HEAD")
    assert_equal 2, remote_branch_status(repository.fetch(:remote), "release/switchtab-1.2.3")
    assert_empty workflow_tool_calls
    assert_no_local_credential_helper(worktree)
  end

  def test_publish_creates_an_absent_branch_with_a_lease_and_locks_merge_to_head
    repository = create_workflow_repository
    worktree = repository.fetch(:worktree)
    git_success!(worktree, "checkout", "-b", "release/switchtab-1.2.3")
    worktree.join("Casks/switchtab.rb").write("switchtab v2\n")

    result = run_workflow_step(
      "publish-pr",
      directory: worktree,
      environment: workflow_publish_environment,
    )

    assert result.fetch(:status).success?, result.fetch(:stderr)
    head = git_success!(worktree, "rev-parse", "HEAD")
    assert_equal head, remote_branch_sha(repository.fetch(:remote), "release/switchtab-1.2.3")
    merge = workflow_tool_calls.find { |call| call.fetch("argv").first(2) == %w[pr merge] }
    refute_nil merge
    assert_equal head, argument_after(merge.fetch("argv"), "--match-head-commit")
    assert workflow_tool_calls.all? { |call| call.fetch("token_present") }
    assert_no_local_credential_helper(worktree)
  end

  def test_publish_replaces_an_existing_branch_with_its_captured_lease
    repository = create_workflow_repository
    worktree = repository.fetch(:worktree)
    branch = "release/switchtab-1.2.3"
    git_success!(worktree, "checkout", "-b", branch)
    worktree.join("Casks/switchtab.rb").write("old release branch\n")
    git_success!(worktree, "add", "--", "Casks/switchtab.rb")
    git_success!(worktree, "commit", "-m", "old release")
    git_success!(worktree, "push", "origin", branch)
    old_remote_sha = remote_branch_sha(repository.fetch(:remote), branch)
    git_success!(worktree, "checkout", "main")
    git_success!(worktree, "checkout", "-B", branch, "main")
    worktree.join("Casks/switchtab.rb").write("new release branch\n")

    result = run_workflow_step(
      "publish-pr",
      directory: worktree,
      environment: workflow_publish_environment.merge("REMOTE_BRANCH_SHA" => old_remote_sha),
    )

    assert result.fetch(:status).success?, result.fetch(:stderr)
    new_head = git_success!(worktree, "rev-parse", "HEAD")
    refute_equal old_remote_sha, new_head
    assert_equal new_head, remote_branch_sha(repository.fetch(:remote), branch)
    assert_no_local_credential_helper(worktree)
  end

  def test_publish_recovers_when_parallel_pr_creation_wins_the_race
    repository = create_workflow_repository
    worktree = repository.fetch(:worktree)
    git_success!(worktree, "checkout", "-b", "release/switchtab-1.2.3")
    worktree.join("Casks/switchtab.rb").write("switchtab v2\n")

    result = run_workflow_step(
      "publish-pr",
      directory: worktree,
      environment: workflow_publish_environment.merge(
        "FAKE_PR_RESPONSES" => "[null,77]",
        "FAKE_PR_CREATE_STATUS" => "19",
      ),
    )

    assert result.fetch(:status).success?, result.fetch(:stderr)
    calls = workflow_tool_calls.map { |call| call.fetch("argv") }
    assert_equal %w[api pr api pr], calls.map(&:first)
    assert_equal ["create", "merge"], calls.select { |argv| argv.first == "pr" }.map { |argv| argv.fetch(1) }
    calls.select { |argv| argv.first == "api" }.each do |argv|
      assert_includes argv, "head=sonim1:release/switchtab-1.2.3"
    end
    merge = calls.last
    assert_equal "77", merge.fetch(2)
    assert_equal git_success!(worktree, "rev-parse", "HEAD"), argument_after(merge, "--match-head-commit")
    assert_no_local_credential_helper(worktree)
  end

  def test_publish_propagates_pr_create_failure_when_exact_head_still_has_no_pr
    repository = create_workflow_repository
    worktree = repository.fetch(:worktree)
    git_success!(worktree, "checkout", "-b", "release/switchtab-1.2.3")
    worktree.join("Casks/switchtab.rb").write("switchtab v2\n")

    result = run_workflow_step(
      "publish-pr",
      directory: worktree,
      environment: workflow_publish_environment.merge(
        "FAKE_PR_RESPONSES" => "[null, null]",
        "FAKE_PR_CREATE_STATUS" => "19",
      ),
    )

    refute result.fetch(:status).success?
    assert_equal 19, result.fetch(:status).exitstatus
    refute workflow_tool_calls.any? { |call| call.fetch("argv").first(2) == %w[pr merge] }
    assert_no_local_credential_helper(worktree)
  end

  def test_update_workflow_pins_actions_and_has_no_payload_execution_or_destructive_rollback
    workflow = update_workflow
    workflow_text = UPDATE_WORKFLOW.read

    assert_equal [APP_TOKEN_ACTION, CHECKOUT_ACTION], collect_uses(workflow)
    collect_uses(workflow).each do |uses|
      assert_match(/\Aactions\/[^@]+@[0-9a-f]{40}\z/, uses)
    end

    workflow.fetch("jobs").fetch("update").fetch("steps").each do |step|
      next unless step.key?("run")

      refute_match(/\$\{\{\s*github\.event\.client_payload\./, step.fetch("run"))
    end
    refute_match(/pull_request_target/, workflow_text)
    refute_match(/\brm\s+-rf\b|\bgit\s+(?:reset\s+--hard|clean\b)/, workflow_text)
    refute_match(/\bgh\s+release\s+(?:delete|edit|upload)\b/, workflow_text)
    assert_equal 1, workflow_text.scan(/\bgh\s+release\s+download\b/).length
  end

  private

  def ci_workflow
    assert CI_WORKFLOW.file?, "expected #{CI_WORKFLOW} to exist"

    Psych.safe_load(CI_WORKFLOW.read, aliases: false)
  end

  def update_workflow
    assert UPDATE_WORKFLOW.file?, "expected #{UPDATE_WORKFLOW} to exist"

    Psych.safe_load(UPDATE_WORKFLOW.read, aliases: false)
  end

  def update_step(id)
    steps = update_workflow.fetch("jobs").fetch("update").fetch("steps")
    step = steps.find { |candidate| candidate["id"] == id }
    refute_nil step, "expected update workflow step #{id.inspect}"
    step
  end

  def assert_shell_strict(script)
    assert_equal "set -euo pipefail", script.lines.first&.strip
  end

  def run_workflow_step(id, directory: @tap, environment: {})
    stdout, stderr, status = Open3.capture3(
      workflow_environment.merge(environment),
      "bash", "-c", update_step(id).fetch("run"),
      chdir: directory.to_s,
    )
    { stdout: stdout, stderr: stderr, status: status }
  end

  def run_workflow_sequence(ids, directory: @tap, environment: {})
    executed = []
    result = nil
    ids.each do |id|
      executed << id
      result = run_workflow_step(id, directory: directory, environment: environment)
      break unless result.fetch(:status).success?
    end
    result.merge(steps: executed)
  end

  def workflow_environment
    write_workflow_fake_gh
    {
      "PATH" => "#{@workflow_bin}:#{ENV.fetch('PATH')}",
      "TMPDIR" => @tap.to_s,
      "GH_TOKEN" => "test-app-token",
      "GITHUB_ENV" => @tap.join("workflow-github-env").to_s,
      "GITHUB_OUTPUT" => @tap.join("workflow-github-output").to_s,
      "FAKE_GH_LOG" => @workflow_gh_log.to_s,
      "FAKE_GH_STATE" => @workflow_gh_state.to_s,
      "FAKE_AUTO_MERGE" => "true",
      "FAKE_PROTECTION_SCHEMA" => "contexts",
      "FAKE_PR_RESPONSES" => "[42]",
      "FAKE_PR_CREATE_STATUS" => "0",
      "FAKE_PR_NUMBER" => "42",
    }
  end

  def workflow_publish_environment
    {
      "PRODUCT" => "switchtab",
      "VERSION" => "1.2.3",
      "RELEASE_TAG" => "v1.2.3",
      "RELEASE_BRANCH" => "release/switchtab-1.2.3",
      "SOURCE_REPOSITORY" => "sonim1/switchtab",
      "REMOTE_BRANCH_SHA" => "",
    }
  end

  def clear_workflow_tool_state
    [@workflow_gh_log, @workflow_gh_state].compact.each { |path| FileUtils.rm_f(path) }
  end

  def workflow_tool_calls
    return [] unless @workflow_gh_log&.file?

    @workflow_gh_log.readlines(chomp: true).map { |line| JSON.parse(line) }
  end

  def write_workflow_fake_gh
    return if @workflow_bin

    @workflow_bin = @tap.join("workflow-bin")
    @workflow_gh_log = @tap.join("workflow-gh-calls.jsonl")
    @workflow_gh_state = @tap.join("workflow-gh-state")
    FileUtils.mkdir_p(@workflow_bin)
    gh = @workflow_bin.join("gh")
    gh.write(<<~'RUBY')
      #!/usr/bin/env ruby
      require "json"

      log_path = ENV.fetch("FAKE_GH_LOG")
      File.open(log_path, "a") do |log|
        log.puts(JSON.generate("argv" => ARGV, "token_present" => !ENV["GH_TOKEN"].to_s.empty?))
      end

      endpoint = ARGV.find { |argument| argument.start_with?("repos/") }
      if ARGV.first == "api" && endpoint == "repos/sonim1/homebrew-tap"
        exit 22 if ENV.fetch("FAKE_AUTO_MERGE", "true") == "api-error"

        puts JSON.generate(
          "id" => 1,
          "full_name" => "sonim1/homebrew-tap",
          "allow_auto_merge" => ENV.fetch("FAKE_AUTO_MERGE", "true") == "true",
        )
      elsif ARGV.first == "api" &&
            endpoint == "repos/sonim1/homebrew-tap/branches/main/protection/required_status_checks"
        schema = ENV.fetch("FAKE_PROTECTION_SCHEMA", "contexts")
        exit 22 if schema == "api-error"

        response = case schema
                   when "contexts"
                     { "strict" => true, "contexts" => %w[contracts homebrew], "checks" => [] }
                   when "checks"
                     {
                       "strict" => true,
                       "contexts" => [],
                       "checks" => [
                         { "context" => "contracts", "app_id" => 1 },
                         { "context" => "homebrew", "app_id" => 1 },
                       ],
                     }
                   when "missing-homebrew"
                     { "strict" => true, "contexts" => ["contracts"], "checks" => [] }
                   when "strict-false"
                     { "strict" => false, "contexts" => %w[contracts homebrew], "checks" => [] }
                   when "strict-missing"
                     { "contexts" => %w[contracts homebrew], "checks" => [] }
                   else
                     { "strict" => true, "contexts" => nil, "checks" => nil }
                   end
        puts JSON.generate(response)
      elsif ARGV.first == "api" && endpoint == "repos/sonim1/homebrew-tap/pulls"
        state_path = ENV.fetch("FAKE_GH_STATE")
        call_index = File.file?(state_path) ? File.read(state_path).to_i : 0
        responses = JSON.parse(ENV.fetch("FAKE_PR_RESPONSES", "[42]"))
        response = responses.fetch([call_index, responses.length - 1].min)
        File.write(state_path, (call_index + 1).to_s)
        puts response unless response.nil?
      elsif ARGV.first(2) == %w[pr create]
        status = ENV.fetch("FAKE_PR_CREATE_STATUS", "0").to_i
        if status.zero?
          puts "https://github.com/sonim1/homebrew-tap/pull/#{ENV.fetch('FAKE_PR_NUMBER', '42')}"
        else
          warn "simulated pull request creation race"
          exit status
        end
      elsif ARGV.first(2) == %w[pr view]
        puts ENV.fetch("FAKE_PR_NUMBER", "42")
      elsif ARGV.first(2) == %w[pr merge]
        puts "merge queued"
      elsif ARGV.first(2) == %w[auth git-credential]
        STDIN.read
        puts "username=x-access-token"
        puts "password=#{ENV.fetch('GH_TOKEN')}"
      else
        warn "unexpected fake gh invocation: #{ARGV.inspect}"
        exit 97
      end
    RUBY
    FileUtils.chmod(0o755, gh)
  end

  def create_workflow_repository
    remote = @tap.join("workflow-remote.git")
    worktree = @tap.join("workflow-worktree")
    git_success!(nil, "init", "--bare", remote.to_s)
    git_success!(nil, "init", "-b", "main", worktree.to_s)
    git_success!(worktree, "config", "user.name", "Workflow Test")
    git_success!(worktree, "config", "user.email", "workflow-test@example.invalid")
    {
      "Casks/switchtab.rb" => "switchtab v1\n",
      "Casks/updatebar-app.rb" => "updatebar app v1\n",
      "Formula/updatebar.rb" => "updatebar v1\n",
      "Formula/updatebar-tui.rb" => "updatebar tui v1\n",
    }.each do |relative_path, contents|
      path = worktree.join(relative_path)
      FileUtils.mkdir_p(path.dirname)
      path.write(contents)
    end
    git_success!(worktree, "add", "--", "Casks", "Formula")
    git_success!(worktree, "commit", "-m", "initial packages")
    git_success!(worktree, "remote", "add", "origin", remote.to_s)
    git_success!(worktree, "push", "-u", "origin", "main")
    { worktree: worktree, remote: remote }
  end

  def git_success!(directory, *arguments, environment: {})
    stdout, stderr, status = if directory
                               Open3.capture3(environment, "git", *arguments, chdir: directory.to_s)
                             else
                               Open3.capture3(environment, "git", *arguments)
                             end
    return stdout.strip if status.success?

    raise "git #{arguments.join(' ')} failed (#{status.exitstatus}): #{stderr}"
  end

  def remote_branch_status(remote, branch)
    _stdout, _stderr, status = Open3.capture3(
      "git", "ls-remote", "--exit-code", "--heads", remote.to_s, "refs/heads/#{branch}"
    )
    status.exitstatus
  end

  def remote_branch_sha(remote, branch)
    output, stderr, status = Open3.capture3(
      "git", "ls-remote", "--exit-code", "--heads", remote.to_s, "refs/heads/#{branch}"
    )
    raise "cannot resolve remote branch #{branch}: #{stderr}" unless status.success?

    output.split.first
  end

  def argument_after(arguments, flag)
    position = arguments.index(flag)
    position && arguments.fetch(position + 1)
  end

  def assert_no_local_credential_helper(worktree)
    stdout, _stderr, status = Open3.capture3(
      "git", "config", "--local", "--get-all", "credential.helper", chdir: worktree.to_s
    )
    refute status.success?, "credential helper remained configured: #{stdout}"
    assert_empty stdout
  end

  def assert_publish_propagates_git_enumeration_failure(mode, package_change: false)
    repository = create_workflow_repository
    worktree = repository.fetch(:worktree)
    git_success!(worktree, "checkout", "-b", "release/switchtab-1.2.3")
    worktree.join("Casks/switchtab.rb").write("switchtab v2\n") if package_change
    original_head = git_success!(worktree, "rev-parse", "HEAD")
    fake_git_bin = write_git_enumeration_failure_wrapper

    result = run_workflow_step(
      "publish-pr",
      directory: worktree,
      environment: workflow_publish_environment.merge(
        "PATH" => "#{fake_git_bin}:#{workflow_environment.fetch('PATH')}",
        "FAKE_GIT_ENUMERATION_FAILURE" => mode,
        "REAL_GIT" => git_executable,
      ),
    )

    assert_equal 73, result.fetch(:status).exitstatus, result.fetch(:stderr)
    assert_equal original_head, git_success!(worktree, "rev-parse", "HEAD")
    assert_equal 2, remote_branch_status(repository.fetch(:remote), "release/switchtab-1.2.3")
    assert_empty workflow_tool_calls
    assert_no_local_credential_helper(worktree)
    assert_empty Dir.glob(@tap.join("tap-publish.*").to_s)
  end

  def write_git_enumeration_failure_wrapper
    directory = @tap.join("enumeration-failure-git-bin")
    FileUtils.mkdir_p(directory)
    wrapper = directory.join("git")
    wrapper.write(<<~'RUBY')
      #!/usr/bin/env ruby
      failures = {
        "tracked" => %w[diff --name-only -z HEAD --],
        "untracked" => ["ls-files", "--others", "--exclude-standard", "-z", "--", "Formula/", "Casks/"],
        "staged" => %w[diff --cached --name-only -z --],
      }
      expected = failures.fetch(ENV.fetch("FAKE_GIT_ENUMERATION_FAILURE"))
      exit 73 if ARGV == expected

      exec ENV.fetch("REAL_GIT"), *ARGV
    RUBY
    FileUtils.chmod(0o755, wrapper)
    directory
  end

  def write_failing_ls_remote_git
    directory = @tap.join("failing-git-bin")
    FileUtils.mkdir_p(directory)
    wrapper = directory.join("git")
    wrapper.write(<<~'RUBY')
      #!/usr/bin/env ruby
      if ARGV.first == "ls-remote"
        exit Integer(ENV.fetch("FAKE_LS_REMOTE_STATUS"))
      end

      exec ENV.fetch("REAL_GIT"), *ARGV
    RUBY
    FileUtils.chmod(0o755, wrapper)
    directory
  end

  def git_executable
    @git_executable ||= begin
      path, status = Open3.capture2("which", "git")
      raise "git executable not found" unless status.success?

      path.strip
    end
  end

  def normalize_ci_step(job_name, step)
    return "unexpected:shape:#{step.class}" unless step.is_a?(Hash)

    if step.keys.sort == %w[uses with] && step["uses"] == CHECKOUT_ACTION
      expected_with = case job_name
                      when "contracts" then { "persist-credentials" => false }
                      when "homebrew" then { "fetch-depth" => 0, "persist-credentials" => false }
                      end
      return "checkout" if step["with"] == expected_with
    end

    if step.keys.sort == ["run"]
      return case [job_name, step.fetch("run")]
             when ["contracts", "ruby test/update-release-test.rb"] then "ruby-contracts"
             when ["contracts", "bash test/test-changed-packages-test.sh"] then "bash-contracts"
             when ["homebrew", "git fetch --no-tags origin main:refs/remotes/origin/main"] then "fetch-main"
             when ["homebrew", "scripts/test-changed-packages.sh origin/main"] then "changed-packages"
             else "unexpected:run:#{step.fetch("run")}"
             end
    end

    if step.key?("uses")
      "unexpected:uses:#{step["uses"]}"
    elsif step.key?("run")
      "unexpected:run:#{step["run"]}"
    else
      "unexpected:shape:#{step.keys.sort.join(",")}"
    end
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
