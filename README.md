# repo-settings

A reusable GitHub Action that syncs `.github/settings.yml` to repository
settings via the GitHub REST API — no third-party app required.

A drop-in, app-free alternative to [probot/settings](https://github.com/apps/settings).

## What it syncs

- **`repository:`** — `description`, `topics`, `homepage`, `visibility`,
  `has_issues`, `has_projects`, `has_wiki`, `has_discussions`,
  `default_branch`, `delete_branch_on_merge`, `allow_squash_merge`,
  `allow_merge_commit`, `allow_auto_merge`, `allow_update_branch`,
  `squash_merge_commit_title`, `squash_merge_commit_message`
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
      repository-projects: read
      administration: write      # required to edit repo settings & labels
      statuses: write            # required to post a status check
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0

      - name: Sync repository settings
        uses: run-action/repo-settings@main
        with:
          settings-path: .github/settings.yml
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

## Inputs

| input | default | description |
| --- | --- | --- |
| `settings-path` | `.github/settings.yml` | Path to the settings file |
| `github-token` | `${{ github.token }}` | Token with `administration: write` scope |
| `dry-run` | `false` | Report what would change without applying |

## Safety

- Uses the built-in, per-run `GITHUB_TOKEN` (rotates every run, scoped to the repo)
- No external services, no personal access tokens
- Full audit trail in the Actions log
- `dry-run: true` previews changes before applying
