# gh-repo-settings

Syncs `.github/settings.yml` to repository settings via the GitHub REST API —
a CLI first, and a GitHub Action for PR previews and drift detection. A
drop-in, app-free alternative to [probot/settings](https://github.com/apps/settings).

## What it syncs

- **`repository:`** — the [probot/settings schema](https://github.com/repository-settings/app/blob/master/docs/plugins/repository.md):
  `description`, `homepage`, `topics`, `private`, `has_issues`, `has_projects`,
  `has_wiki`, `default_branch`, the merge-strategy toggles,
  `delete_branch_on_merge`, `enable_vulnerability_alerts`,
  `enable_automated_security_fixes`, plus `enable_secret_scanning`,
  `enable_secret_scanning_push_protection`, `enable_private_vulnerability_reporting`,
  and `enable_immutable_releases` (translated to the `security_and_analysis`
  PATCH shape and the private-vulnerability-reporting / immutable-releases
  toggle endpoints respectively — not part of the probot/settings schema, but
  accepted here for a single-file secure baseline)
- **`repository_extra:`** — any other
  [Update-a-repository](https://docs.github.com/en/rest/repos/repos#update-a-repository)
  field (e.g. `visibility`, `has_discussions`, `allow_auto_merge`). Merged
  over `repository:`; probot/settings ignores it, so the file stays portable
- **`labels:`** — creates / updates / deletes labels to match the file
- **`rulesets:`** — creates / updates branch or tag rulesets, matched by
  `name`. Not part of the probot/settings schema, so this mirrors the
  [Create/update a repository ruleset](https://docs.github.com/en/rest/repos/rules#create-a-repository-ruleset)
  API shape directly. Rulesets removed from the file are left alone —
  unrelated rulesets may exist on the repo

## CLI

Recommended flow: preview in CI (below), apply from your machine with the
admin access you already have — no admin credential ever sits in CI. Target
and auth are auto-detected: the repository from an `owner/repo` argument,
`$REPOSITORY` / `$GITHUB_REPOSITORY`, or the `origin` remote of the current
checkout; the token from `$GITHUB_TOKEN`, `$GH_TOKEN`, or `gh auth token`.
Syncing needs admin on the target repo.

```console
$ gh-repo-settings init              # write a recommended settings.yml to start from
$ gh-repo-settings sync --dry-run    # preview against the current checkout
$ gh-repo-settings sync              # apply
$ gh-repo-settings sync owner/repo --settings path/to/settings.yml
$ gh-repo-settings check [owner/repo] [--strict]    # read-only audit (below)
```

`init` refuses to overwrite an existing file. It writes the recommended
secure baseline (the same one this repo uses), seeding `description`,
`homepage`, and `topics` from the live repository when it can read them, so
the first `sync` doesn't blank out metadata you already set.

`scripts/sync-settings.sh` and `scripts/healthcheck.sh` are standalone bash —
copy them anywhere; they take the same values as environment variables
(`REPOSITORY`, `SETTINGS_PATH`, `DRY_RUN`).

To install as a [gh extension](https://cli.github.com/manual/gh_extension)
(`gh repo-settings sync`), gh requires the repository to be *named*
`gh-repo-settings` — fork/rename, then
`gh extension install <owner>/gh-repo-settings`.

### Nix

The flake packages the CLI with its dependencies (`yq`, `jq`, `curl`, `gh`):

```console
$ nix run github:run-action/gh-repo-settings -- sync --dry-run
$ nix run github:run-action/gh-repo-settings -- check
$ nix profile install github:run-action/gh-repo-settings
```

`nix develop` opens a dev shell with every linter CI runs plus
[zizmor](https://docs.zizmor.sh); run `lint` to run them all.

## GitHub Action

A dry-run only reads, so PR previews work with the built-in token — no
secrets to provision, and fork PRs (which get no secrets and a read-only
token) stay safe:

```yaml
# .github/workflows/settings-preview.yml
name: Preview settings changes

on:
  pull_request:
    paths:
      - ".github/settings.yml"

permissions: {}

jobs:
  preview:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
        with:
          persist-credentials: false

      - name: Preview settings sync
        uses: run-action/gh-repo-settings@main
        with:
          dry-run: "true"
          github-token: ${{ github.token }}
```

Actually *applying* needs the **Administration: write** repository
permission, which the workflow `GITHUB_TOKEN` can never be granted. To
auto-apply anyway (e.g. converging a fleet of org repos), prefer a
short-lived [GitHub App installation token](https://github.com/actions/create-github-app-token):

```yaml
jobs:
  sync:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
        with:
          persist-credentials: false

      - uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        id: app-token
        with:
          app-id: ${{ vars.SETTINGS_APP_ID }}
          private-key: ${{ secrets.SETTINGS_APP_PRIVATE_KEY }}

      - name: Sync repository settings
        uses: run-action/gh-repo-settings@main
        with:
          github-token: ${{ steps.app-token.outputs.token }}
```

A [fine-grained PAT](https://github.com/settings/personal-access-tokens)
scoped to the target repo with *Administration: Read and write* also works,
but it is a standing admin credential — scope it tightly and set an expiry.
This repo's [`sync-settings.yml`](.github/workflows/sync-settings.yml) shows
the hybrid: preview on PRs with the built-in token, apply on `main` with the
stored token.

### Inputs

| input           | default                | description                                       |
| --------------- | ---------------------- | ------------------------------------------------- |
| `settings-path` | `.github/settings.yml` | Path to the settings file                         |
| `github-token`  | *(required)*           | Token with the `Administration: write` repo scope |
| `dry-run`       | `false`                | Report what would change without applying         |

## Repo healthcheck

`gh-repo-settings check` audits a repository against a secure-OSS baseline —
including settings the sync *can't* manage: Dependabot, Actions token defaults, community
files (SECURITY.md, CODEOWNERS, …), and workflow hygiene (SHA-pinned actions,
explicit `permissions:`, `pull_request_target` usage). Admin-only checks
degrade to warnings without an admin token; `--strict` makes warnings fail
too. Dependabot malware alerts get a reminder line rather than a real check —
GitHub exposes no REST API to read or set that toggle, so it can only be
enabled by hand under Settings > Advanced Security. Exits non-zero on failure, so it works in CI — see
[`healthcheck.yml`](.github/workflows/healthcheck.yml) for a copyable weekly
workflow. This repo's [`.github/settings.yml`](.github/settings.yml) doubles
as a copyable baseline.

## Requirements

`yq` (mikefarah/yq), `jq`, and `curl` — all preinstalled on GitHub-hosted
Ubuntu runners, and bundled by the Nix package. The healthcheck needs only
`jq` and `curl` (plus optionally `gh` for auth).
