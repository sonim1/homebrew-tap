# sonim1 Homebrew tap

This tap publishes checksum-verified Homebrew formulae and casks for
Apple-silicon macOS releases of UpdateBar and (once its cask is generated)
SwitchTab.

## Install

Tap the repository once:

```sh
brew tap sonim1/tap
```

The currently published packages are:

```sh
brew install sonim1/tap/updatebar
brew install sonim1/tap/updatebar-tui
brew install --cask sonim1/tap/updatebar-app
```

The `switchtab` cask is intentionally not installable until
`Casks/switchtab.rb` exists in a merged tap revision. After that file is
published, install it with:

```sh
brew install --cask sonim1/tap/switchtab
```

The updater is restricted to this exact repository/token/path allowlist:

| Source repository | Token | Definition |
| --- | --- | --- |
| `sonim1/switchtab` | `switchtab` | `Casks/switchtab.rb` |
| `sonim1/UpdateBar` | `updatebar` | `Formula/updatebar.rb` |
| `sonim1/UpdateBar` | `updatebar-app` | `Casks/updatebar-app.rb` |
| `sonim1/UpdateBar` | `updatebar-tui` | `Formula/updatebar-tui.rb` |

## Release notification contract

The update workflow accepts only the typed `homebrew_release`
`repository_dispatch` event. It reads only `repository` and `tag` from
`client_payload`; extra keys are ignored and are not trusted (no caller-supplied
version, package, URL, checksum, or branch is used). For example:

```json
{
  "event_type": "homebrew_release",
  "client_payload": {
    "repository": "sonim1/switchtab",
    "tag": "v1.2.3"
  }
}
```

Only `sonim1/switchtab` and `sonim1/UpdateBar` with a `v`-prefixed numeric
release tag are accepted. The workflow downloads the public
`release-manifest.json` from that GitHub Release, then runs
`scripts/update-release.rb`.

The updater reads the manifest from `TAP_MANIFEST_FILE` and:

- validates the exact schema, repository/tag/version, lowercase 40-hex commit
  metadata, package set, and canonical release-asset names;
- reconstructs URLs for the allowlisted release assets or the allowlisted Git
  tag archive, fetches those public sources, and recalculates SHA-256;
- refuses unknown repositories/packages, malformed or unsafe asset/path data,
  downgrades, and checksum mismatches; and
- renders only the allowlisted definitions through a staged, backed-up,
  transactional replace, rolling back if a commit step fails.

The manifest `commit` field is format-checked metadata only; the updater does
not query GitHub to prove that it is the commit associated with the release
tag. Repository/tag/version validation and the downloaded source checks are the
authoritative updater checks.

Identical rendered bytes are a no-op. Retrying the same release notification is
therefore byte-identical and produces no package commit, push, or pull request
when nothing changed. Release branches are deterministic
(`release/switchtab-1.2.3` or `release/updatebar-1.2.3`), rebuilt from
`origin/main`, and pushed with a captured `--force-with-lease`. An existing open
PR for that branch is reused; otherwise one is created and queued for squash
auto-merge at the exact generated commit. This automation never deletes or
rolls back a public GitHub Release, feed, or tag: the source app GitHub Release
and its manifest remain authoritative.

## Required live configuration (post-merge)

These are deployment prerequisites, not settings claimed to be configured by
this repository. Before enabling release dispatches:

1. Create a GitHub App installed only on `sonim1/homebrew-tap` for this
   workflow. Grant the minimum runtime permissions: **Administration: read**
   (repository auto-merge preflight), **Contents: read/write** (checkout and
   release-branch push), and **Pull requests: read/write** (find/create and
   merge the PR).
2. Add the App ID as repository variable `TAP_GITHUB_APP_ID` and store its
   private key as repository secret `TAP_GITHUB_APP_PRIVATE_KEY`. Never commit
   the key or any other credential.
3. Enable **Allow auto-merge** in the repository settings.
4. Protect `main` with strict required status checks
   (`required_status_checks.strict == true`) and require the exact contexts
   `contracts` and `homebrew`; strict protection keeps branches up to date
   before merging.

The update workflow performs a fail-closed preflight for auto-merge, strict
up-to-date enforcement, and both required contexts before checkout, branch
mutation, or publishing. Missing or non-strict configuration intentionally
fails the run before any mutation.

## Pull-request CI

Every PR must pass both checks before merge:

- `contracts` on Ubuntu runs the Ruby updater contract tests and shell package
  tests.
- `homebrew` on macOS audits each changed allowlisted formula/cask, installs it,
  runs formula tests, and verifies the expected application for casks.

Do not bypass these checks or merge an unverified package definition.

## Recovery and retries

For a pre-publication draft or artifact problem, repair the draft/source
artifact before it is published or consumed. For an already public or consumed
release, never edit or replace its bytes, checksum, or tag; publish a correction
under a new version/tag instead. For an unchanged public source release, fix
the deterministic PR/check or live configuration and rerun only that same
release notification. Do not blind-force a branch, hand-edit checksums, or
manually manufacture a tap version. The source app GitHub Release remains
authoritative.

## Local verification

Run these commands from the tap checkout:

```sh
ruby test/update-release-test.rb
bash test/test-changed-packages-test.sh
bash -n scripts/test-changed-packages.sh test/test-changed-packages-test.sh
ruby -rpsych -e 'Psych.load_file(".github/workflows/ci.yml"); Psych.load_file(".github/workflows/update-package.yml")'
ruby -c scripts/update-release.rb
ruby -c test/update-release-test.rb
git diff --check
```

All tests must pass. The suites use temporary repositories, fixtures, and fake
download/Homebrew tools; they do not mutate live GitHub settings, releases,
branches, PRs, or local Homebrew installations. Credentials are not needed for
local verification.
