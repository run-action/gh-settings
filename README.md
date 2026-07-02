# repo-settings

A reusable GitHub Action that syncs `.github/settings.yml` to repository
settings via the GitHub REST API — no third-party app required.

A drop-in, app-free alternative to [probot/settings](https://github.com/apps/settings).

## What it syncs

- **`repository:`** — follows the [de facto probot/settings schema](https://github.com/repository-settings/app/blob/master/docs/plugins/repository.md):
  `description`, `homepage`, `topics` (array or comma-separated string),
  `private`, `has_issues`, `has_projects`, `has_wiki`, `default_branch`,
  `allow_squash_merge`, `allow_merge_commit`, `allow_rebase_merge`,
  `delete_branch_on_merge`, `enable_vulnerability_alerts`,
  `enable_automated_security_fixes`
- **`repository_extra:`** — additional [Update-a-repository API](https://docs.github.com/en/rest/repos/repos#update-a-repository)
  fields that are *not* part of the probot/settings schema, e.g.
  `visibility`, `has_discussions`, `allow_auto_merge`, `allow_update_branch`,
  `squash_merge_commit_title`, `squash_merge_commit_message`,
  `web_commit_signoff_required`. Merged over `repository:` before syncing;
  probot/settings ignores this section, so the file stays portable
- **`labels:`** — creates / updates / deletes labels to match the file

## Usage

In any repo, add a workflow:

```yaml
# .github/workflows/sync-settings.yml
name: Sync settings.yml

on:
  push:
    paths:
      - ".github/settings.yml"
      - ".github/workflows/sync-settings.yml"
  workflow_dispatch: {}

permissions: {}

jobs:
  sync:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      administration: write # required to edit repo settings & labels
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0

      - name: Sync repository settings
        uses: run-action/repo-settings@main
        with:
          settings-path: .github/settings.yml
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

## Inputs

| input           | default                | description                               |
| --------------- | ---------------------- | ----------------------------------------- |
| `settings-path` | `.github/settings.yml` | Path to the settings file                 |
| `github-token`  | `${{ github.token }}`  | Token with `administration: write` scope  |
| `dry-run`       | `false`                | Report what would change without applying |

## Running locally

Both scripts are plain bash and run fine outside Actions. The sync script is
configured through environment variables (same ones the action sets); the
token needs admin access on the target repo — `gh auth token` works:

```console
$ git clone https://github.com/run-action/repo-settings && cd repo-settings

# Preview what a sync would change (no writes), then apply it:
$ DRY_RUN=true REPOSITORY=owner/repo GITHUB_TOKEN=$(gh auth token) scripts/sync-settings.sh
$ REPOSITORY=owner/repo GITHUB_TOKEN=$(gh auth token) scripts/sync-settings.sh

# Audit any repo against the secure-OSS baseline (see below):
$ scripts/healthcheck.sh owner/repo
```

`SETTINGS_PATH` (default `.github/settings.yml`, relative to the current
directory) points the sync at the settings file to apply — set it when
running from outside the target repo's checkout. The healthcheck finds its
token by itself (`$GITHUB_TOKEN`, then `gh auth token`).

## Safety

- Uses the built-in, per-run `GITHUB_TOKEN` (rotates every run, scoped to the repo)
- No external services, no personal access tokens
- Full audit trail in the Actions log
- `dry-run: true` previews changes before applying (reads existing labels so
  the diff is accurate, but performs no writes)
- Any API error fails the run loudly instead of being silently ignored

## Repo healthcheck

`scripts/healthcheck.sh` audits a repository against a recommended baseline
for a secure open source repo — the settings this action *can't* sync:

- **Repository** — license, description, `delete_branch_on_merge`, secret
  scanning + push protection, Dependabot security updates
- **Vulnerability management** — Dependabot alerts, private vulnerability
  reporting, `.github/dependabot.yml`
- **Branch protection** — classic protection or rulesets on the default branch
- **Actions** — default `GITHUB_TOKEN` permissions read-only, Actions cannot
  approve PRs
- **Community files** — README, SECURITY.md, CODEOWNERS, code of conduct,
  contributing guide
- **Workflow hygiene** (when run inside a checkout) — actions pinned to
  commit SHAs, explicit `permissions:` blocks, `pull_request_target` usage

```console
$ scripts/healthcheck.sh              # repo inferred from origin remote
$ scripts/healthcheck.sh owner/repo   # or explicit
$ scripts/healthcheck.sh --strict     # warnings also fail
```

Auth comes from `$GITHUB_TOKEN` or `gh auth token`. Admin-only settings
(secret scanning, Actions permissions) show as warnings with a
non-admin token. Exits non-zero on any failure, so it works in CI —
see `.github/workflows/healthcheck.yml` for a copyable workflow that runs
it weekly. The `repository:` block in this repo's
[`.github/settings.yml`](.github/settings.yml) doubles as a recommended
baseline you can copy alongside it.

## Requirements

`yq` (mikefarah/yq), `jq`, and `curl` on the runner's PATH — all preinstalled
on GitHub-hosted Ubuntu runners. The healthcheck script needs only `jq` and
`curl` (plus optionally `gh` for auth).
