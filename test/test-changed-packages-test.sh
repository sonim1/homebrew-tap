#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_SCRIPT="$REPOSITORY_ROOT/scripts/test-changed-packages.sh"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-changed-packages.XXXXXX")"
FAKE_BREW="$TEMP_ROOT/fake-brew"

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_equal() {
  expected="$1"
  actual="$2"
  message="$3"
  [ "$expected" = "$actual" ] || fail "$message (expected $(printf '%s' "$expected" | od -An -tx1), got $(printf '%s' "$actual" | od -An -tx1))"
}

assert_contains() {
  haystack="$1"
  needle="$2"
  message="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$message (missing $(printf '%s' "$needle" | od -An -tx1))" ;;
  esac
}

assert_success() {
  [ "$RUN_STATUS" -eq 0 ] || fail "script failed with exit $RUN_STATUS: $RUN_STDERR_CONTENTS"
}

assert_failure() {
  [ "$RUN_STATUS" -ne 0 ] || fail "script unexpectedly succeeded"
}

assert_brew_log() {
  expected="$1"
  actual=""
  if [ -f "$RUN_REPO/brew.log" ]; then
    actual="$(cat "$RUN_REPO/brew.log")"
  fi
  assert_equal "$expected" "$actual" "unexpected brew argv log"
}

assert_no_brew_calls() {
  if [ -f "$RUN_REPO/brew.log" ]; then
    [ ! -s "$RUN_REPO/brew.log" ] || fail "brew was called unexpectedly: $(cat "$RUN_REPO/brew.log")"
  fi
}

create_fake_brew() {
  cat > "$FAKE_BREW" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

line=""
for argument in "$@"; do
  if [ -n "$line" ]; then
    line="${line}$(printf '\t')"
  fi
  line="${line}${argument}"
done
printf '%s\n' "$line" >> "${BREW_LOG:?}"

if [ "${BREW_FAIL_LINE:-}" = "$line" ]; then
  exit "${BREW_FAIL_STATUS:-23}"
fi

if [ "${BREW_CREATE_APP:-1}" = "1" ] && [ "${1:-}" = "install" ] && [ "${2:-}" = "--cask" ]; then
  case "${3:-}" in
    ./Casks/switchtab.rb) mkdir -p "${APPLICATIONS_DIR:?}/SwitchTab.app" ;;
    ./Casks/updatebar-app.rb) mkdir -p "${APPLICATIONS_DIR:?}/UpdateBar.app" ;;
  esac
fi
BASH
  chmod +x "$FAKE_BREW"
}

create_repo() {
  repo_name="$1"
  shift
  RUN_REPO="$TEMP_ROOT/$repo_name"
  mkdir -p "$RUN_REPO"
  git -C "$RUN_REPO" init -q
  git -C "$RUN_REPO" config user.name test
  git -C "$RUN_REPO" config user.email test@example.com
  git -C "$RUN_REPO" commit --allow-empty -qm base
  RUN_BASE="$(git -C "$RUN_REPO" rev-parse HEAD)"

  for changed_path in "$@"; do
    mkdir -p "$RUN_REPO/$(dirname "$changed_path")"
    printf 'fixture\n' > "$RUN_REPO/$changed_path"
    git -C "$RUN_REPO" add -- "$changed_path"
  done
  git -C "$RUN_REPO" commit -qm change
}

run_script() {
  RUN_STDOUT="$RUN_REPO/stdout"
  RUN_STDERR="$RUN_REPO/stderr"
  : > "$RUN_STDOUT"
  : > "$RUN_STDERR"
  if (
    cd "$RUN_REPO"
    BREW_BIN="$FAKE_BREW" \
      BREW_LOG="$RUN_REPO/brew.log" \
      APPLICATIONS_DIR="$RUN_REPO/Applications" \
      BREW_FAIL_LINE="${RUN_FAIL_LINE:-}" \
      BREW_FAIL_STATUS="${RUN_FAIL_STATUS:-23}" \
      BREW_CREATE_APP="${RUN_CREATE_APP:-1}" \
      "$SOURCE_SCRIPT" "${RUN_BASE_OVERRIDE:-$RUN_BASE}"
  ) > "$RUN_STDOUT" 2> "$RUN_STDERR"; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
  RUN_STDOUT_CONTENTS="$(cat "$RUN_STDOUT")"
  RUN_STDERR_CONTENTS="$(cat "$RUN_STDERR")"
}

run_without_base() {
  RUN_STDOUT="$RUN_REPO/stdout"
  RUN_STDERR="$RUN_REPO/stderr"
  : > "$RUN_STDOUT"
  : > "$RUN_STDERR"
  if (
    cd "$RUN_REPO"
    BREW_BIN="$FAKE_BREW" \
      BREW_LOG="$RUN_REPO/brew.log" \
      APPLICATIONS_DIR="$RUN_REPO/Applications" \
      "$SOURCE_SCRIPT"
  ) > "$RUN_STDOUT" 2> "$RUN_STDERR"; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
  RUN_STDOUT_CONTENTS="$(cat "$RUN_STDOUT")"
  RUN_STDERR_CONTENTS="$(cat "$RUN_STDERR")"
}

test_changed_updatebar_formula() {
  unset RUN_FAIL_LINE RUN_BASE_OVERRIDE RUN_CREATE_APP
  create_repo formula-updatebar Formula/updatebar.rb
  run_script
  assert_success
  assert_brew_log "$(printf 'audit\t--strict\tFormula/updatebar.rb\ninstall\t--formula\t./Formula/updatebar.rb\ntest\tupdatebar')"
}

test_changed_updatebar_tui_formula() {
  unset RUN_FAIL_LINE RUN_BASE_OVERRIDE RUN_CREATE_APP
  create_repo formula-updatebar-tui Formula/updatebar-tui.rb
  run_script
  assert_success
  assert_brew_log "$(printf 'audit\t--strict\tFormula/updatebar-tui.rb\ninstall\t--formula\t./Formula/updatebar-tui.rb\ntest\tupdatebar-tui')"
}

test_changed_switchtab_cask() {
  unset RUN_FAIL_LINE RUN_BASE_OVERRIDE RUN_CREATE_APP
  create_repo cask-switchtab Casks/switchtab.rb
  run_script
  assert_success
  assert_brew_log "$(printf 'audit\t--cask\t--strict\tCasks/switchtab.rb\ninstall\t--cask\t./Casks/switchtab.rb')"
  [ -d "$RUN_REPO/Applications/SwitchTab.app" ] || fail "SwitchTab.app was not verified in Applications"
}

test_changed_updatebar_app_cask() {
  unset RUN_FAIL_LINE RUN_BASE_OVERRIDE RUN_CREATE_APP
  create_repo cask-updatebar-app Casks/updatebar-app.rb
  run_script
  assert_success
  assert_brew_log "$(printf 'audit\t--cask\t--strict\tCasks/updatebar-app.rb\ninstall\t--cask\t./Casks/updatebar-app.rb')"
  [ -d "$RUN_REPO/Applications/UpdateBar.app" ] || fail "UpdateBar.app was not verified in Applications"
}

test_unrelated_paths_are_ignored_without_eval() {
  unset RUN_FAIL_LINE RUN_BASE_OVERRIDE RUN_CREATE_APP
  marker="$TEMP_ROOT/unexpected-command-executed"
  unrelated_path="docs/\$(touch $marker)"
  create_repo unrelated "$unrelated_path"
  run_script
  assert_success
  assert_no_brew_calls
  [ ! -e "$marker" ] || fail "an unrelated git path was evaluated as shell code"
}

test_unknown_formula_definition_is_rejected_before_brew() {
  unset RUN_FAIL_LINE RUN_BASE_OVERRIDE RUN_CREATE_APP
  create_repo unknown-formula Formula/unknown.rb
  run_script
  assert_equal 64 "$RUN_STATUS" "unknown Formula definition should exit 64"
  assert_contains "$RUN_STDERR_CONTENTS" "unsupported package definition" "unknown Formula error should be clear"
  assert_no_brew_calls
}

test_unknown_cask_definition_is_rejected_before_brew() {
  unset RUN_FAIL_LINE RUN_BASE_OVERRIDE RUN_CREATE_APP
  create_repo unknown-cask Casks/unknown.rb
  run_script
  assert_equal 64 "$RUN_STATUS" "unknown Cask definition should exit 64"
  assert_contains "$RUN_STDERR_CONTENTS" "unsupported package definition" "unknown Cask error should be clear"
  assert_no_brew_calls
}

test_missing_base_argument_is_clear() {
  unset RUN_FAIL_LINE RUN_BASE_OVERRIDE RUN_CREATE_APP
  create_repo missing-argument README.md
  run_without_base
  assert_failure
  assert_contains "$RUN_STDERR_CONTENTS" "usage: scripts/test-changed-packages.sh <base-ref>" "missing base argument should print usage"
  assert_no_brew_calls
}

test_missing_base_ref_propagates_git_error() {
  unset RUN_FAIL_LINE RUN_BASE_OVERRIDE RUN_CREATE_APP
  create_repo missing-ref README.md
  RUN_BASE_OVERRIDE="no-such-base-ref"
  run_script
  assert_failure
  assert_contains "$RUN_STDERR_CONTENTS" "no-such-base-ref" "missing base ref should identify the ref"
  assert_no_brew_calls
}

test_brew_failures_stop_later_commands() {
  for failed_line in \
    "$(printf 'audit\t--strict\tFormula/updatebar.rb')" \
    "$(printf 'install\t--formula\t./Formula/updatebar.rb')" \
    "$(printf 'test\tupdatebar')"; do
    unset RUN_BASE_OVERRIDE RUN_CREATE_APP
    RUN_FAIL_LINE="$failed_line"
    create_repo "failure-${#failed_line}" Formula/updatebar.rb
    run_script
    assert_equal 23 "$RUN_STATUS" "brew failure should propagate for $failed_line"
    case "$failed_line" in
      audit*) expected="$failed_line" ;;
      install*) expected="$(printf 'audit\t--strict\tFormula/updatebar.rb\n%s' "$failed_line")" ;;
      test*) expected="$(printf 'audit\t--strict\tFormula/updatebar.rb\ninstall\t--formula\t./Formula/updatebar.rb\n%s' "$failed_line")" ;;
    esac
    assert_brew_log "$expected"
  done
}

test_cask_application_must_exist() {
  unset RUN_FAIL_LINE RUN_BASE_OVERRIDE
  RUN_CREATE_APP=0
  create_repo cask-missing-app Casks/switchtab.rb
  run_script
  assert_failure
  assert_contains "$RUN_STDERR_CONTENTS" "SwitchTab.app" "missing cask application should be identified"
  assert_brew_log "$(printf 'audit\t--cask\t--strict\tCasks/switchtab.rb\ninstall\t--cask\t./Casks/switchtab.rb')"
}

create_fake_brew
test_changed_updatebar_formula
test_changed_updatebar_tui_formula
test_changed_switchtab_cask
test_changed_updatebar_app_cask
test_unrelated_paths_are_ignored_without_eval
test_unknown_formula_definition_is_rejected_before_brew
test_unknown_cask_definition_is_rejected_before_brew
test_missing_base_argument_is_clear
test_missing_base_ref_propagates_git_error
test_brew_failures_stop_later_commands
test_cask_application_must_exist

echo "test-changed-packages-test: PASS"
