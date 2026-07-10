#!/usr/bin/env bash
# Writes a recommended .github/settings.yml if none exists, seeding
# description, homepage, and topics from the live repository when readable.
set -euo pipefail

if [[ -n "${DEBUG:-}" ]]; then set -x; fi

SETTINGS_PATH="${SETTINGS_PATH:-.github/settings.yml}"

if [[ -f "$SETTINGS_PATH" ]]; then
  echo "::error::$SETTINGS_PATH already exists; edit it instead." >&2
  exit 1
fi

for tool in yq jq curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "::error::$tool is required but not found on PATH." >&2
    exit 1
  fi
done

API_BASE="${GITHUB_API_URL:-https://api.github.com}"

# Repository detection mirrors sync-settings.sh, but is optional here: with
# no repository (or no API access) the file is still written, just unseeded.
REPO="${REPOSITORY:-"${GITHUB_REPOSITORY:-}"}"
if [[ -z "$REPO" ]] && command -v git >/dev/null 2>&1; then
  origin_url="$(git remote get-url origin 2>/dev/null || true)"
  origin_url="${origin_url%.git}"
  if [[ "$origin_url" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
    REPO="${BASH_REMATCH[1]}"
  fi
fi

TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [[ -z "$TOKEN" ]] && command -v gh >/dev/null 2>&1; then
  TOKEN="$(gh auth token 2>/dev/null || true)"
fi

# Current metadata worth carrying into the file, as indented YAML.
seed_yaml=""
if [[ -n "$REPO" ]]; then
  AUTH=()
  if [[ -n "$TOKEN" ]]; then AUTH=(-H "Authorization: Bearer $TOKEN"); fi
  if response="$(curl -sS --fail "${AUTH[@]}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$API_BASE/repos/$REPO" 2>/dev/null)"; then
    seed_json="$(jq -c '{description: (.description // ""), homepage: (.homepage // ""), topics: (.topics // [])}
      | with_entries(select(.value != "" and .value != []))' <<<"$response")"
    if [[ "$seed_json" != "{}" ]]; then
      seed_yaml="$(yq -P <<<"$seed_json" | sed 's/^/  /')"
      echo "Seeded description/homepage/topics from $REPO."
    fi
  else
    echo "::warning::Could not read repos/$REPO; writing an unseeded file."
  fi
fi

mkdir -p "$(dirname "$SETTINGS_PATH")"
{
  cat <<'EOF'
# Repository settings, synced by run-action/gh-settings
# (https://github.com/run-action/gh-settings). Written by
# `gh-settings init` as a recommended secure baseline; review and adjust.

repository:
EOF
  if [[ -n "$seed_yaml" ]]; then
    printf '%s\n' "$seed_yaml"
  else
    cat <<'EOF'
  # description: ""
  # homepage: ""
  # topics: [my-topic, another-topic]
EOF
  fi
  cat <<'EOF'
  # All keys in this block follow the de facto probot/settings schema
  # (https://github.com/repository-settings/app/blob/master/docs/plugins/repository.md).
  # Visibility is left unmanaged by default; uncomment to enforce it.
  # private: false
  delete_branch_on_merge: true
  allow_squash_merge: true
  allow_merge_commit: false
  enable_vulnerability_alerts: true
  enable_automated_security_fixes: true
  enable_secret_scanning: true
  enable_secret_scanning_push_protection: true
  enable_private_vulnerability_reporting: true
  enable_immutable_releases: true

# Extra "Update a repository" API fields that are NOT part of the de facto
# probot/settings schema. gh-settings merges them over repository:;
# probot/settings ignores this section.
repository_extra:
  allow_auto_merge: true
  allow_update_branch: true

# Default GITHUB_TOKEN permissions for workflows; mirrors the "Set default
# workflow permissions for a repository" API
# (https://docs.github.com/en/rest/actions/permissions#set-default-workflow-permissions-for-a-repository).
# probot/settings ignores this section.
actions:
  default_workflow_permissions: read
  can_approve_pull_request_reviews: false

# labels:
#   - name: bug
#     color: B60205
#     description: Something is not working

# Branch/tag rulesets mirror the "Create/update a repository ruleset" API
# shape (https://docs.github.com/en/rest/repos/rules#create-a-repository-ruleset),
# matched and updated by name. Rulesets removed from this list are NOT
# deleted from the repo.
rulesets:
  - name: default branch protection
    target: branch
    enforcement: active
    conditions:
      ref_name:
        include: ["~DEFAULT_BRANCH"]
        exclude: []
    rules:
      - type: deletion
      - type: non_fast_forward
      - type: pull_request
        parameters:
          # Reviews are not required by default so solo maintainers can merge
          # their own PRs; set to 1 or more to require approving reviews.
          required_approving_review_count: 0
          dismiss_stale_reviews_on_push: true
          require_code_owner_review: false
          require_last_push_approval: false
          required_review_thread_resolution: true
EOF
} >"$SETTINGS_PATH"

echo "Wrote $SETTINGS_PATH. Preview the sync with: gh-settings sync --dry-run"
