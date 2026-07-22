#!/usr/bin/env bash
set -euo pipefail

BASE_REF="${1:?usage: scripts/test-changed-packages.sh <base-ref>}"
BREW_BIN="${BREW_BIN:-brew}"
APPLICATIONS_DIR="${APPLICATIONS_DIR:-/Applications}"
GIT_BIN="${GIT_BIN:-git}"

CHANGED_PATHS_FILE="$(mktemp "${TMPDIR:-/tmp}/test-changed-packages.XXXXXX")"
cleanup() {
  rm -f "$CHANGED_PATHS_FILE" || :
}
trap cleanup EXIT HUP INT TERM

"$GIT_BIN" diff --name-only -z "$BASE_REF"...HEAD -- > "$CHANGED_PATHS_FILE"

while IFS= read -r -d '' path; do
  case "$path" in
    Formula/updatebar.rb|Formula/updatebar-tui.rb|Casks/switchtab.rb|Casks/updatebar-app.rb)
      ;;
    Formula/*|Casks/*)
      echo "test-changed-packages: unsupported package definition: $path" >&2
      exit 64
      ;;
  esac
done < "$CHANGED_PATHS_FILE"

while IFS= read -r -d '' path; do
  case "$path" in
    Formula/updatebar.rb|Formula/updatebar-tui.rb)
      token="${path#Formula/}"
      token="${token%.rb}"
      "$BREW_BIN" audit --strict "$path"
      "$BREW_BIN" install --formula "./$path"
      "$BREW_BIN" test "$token"
      ;;
    Casks/switchtab.rb|Casks/updatebar-app.rb)
      token="${path#Casks/}"
      token="${token%.rb}"
      "$BREW_BIN" audit --cask --strict "$path"
      "$BREW_BIN" install --cask "./$path"
      case "$token" in
        switchtab) application_path="$APPLICATIONS_DIR/SwitchTab.app" ;;
        updatebar-app) application_path="$APPLICATIONS_DIR/UpdateBar.app" ;;
      esac
      if [ ! -d "$application_path" ]; then
        echo "test-changed-packages: expected application missing: $application_path" >&2
        exit 1
      fi
      ;;
  esac
done < "$CHANGED_PATHS_FILE"
