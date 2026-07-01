#!/usr/bin/env bash
# Syncs .github/settings.yml to repository settings via the GitHub REST API.
# App-free alternative to probot/settings.
set -euo pipefail

if [[ -n "${DEBUG:-}" ]]; then set -x; fi

SETTINGS_PATH="${SETTINGS_PATH:-.github/settings.yml}"
DRY_RUN="${DRY_RUN:-false}"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "::error::GITHUB_TOKEN is not set. Pass github-token input." >&2
  exit 1
fi

if [[ ! -f "$SETTINGS_PATH" ]]; then
  echo "::error::Settings file not found at $SETTINGS_PATH" >&2
  exit 1
fi

# Derive API base from GH_HOST (defaults to github.com).
API_BASE="${GH_HOST:-https://api.github.com}"
# github.api_url is https://api.github.com for github.com;
# for GHES it is https://<host>/api/v3. Strip a trailing /api/v3 for repo URL.
REPO_API="$API_BASE"

# Determine repository (owner/name) from GITHUB_REPOSITORY if available,
# otherwise let the user override via REPOSITORY env var.
REPO="${REPOSITORY:-"${GITHUB_REPOSITORY:-}"}"
if [[ -z "$REPO" ]]; then
  echo "::error::REPOSITORY or GITHUB_REPOSITORY must be set." >&2
  exit 1
fi

# Detect yq. GitHub-hosted ubuntu runners ship mikefarah/yq (Go).
if ! command -v yq >/dev/null 2>&1; then
  echo "::error::yq is required but not found on PATH." >&2
  exit 1
fi

# Normalize dry-run to a boolean.
is_dry_run() { [[ "$DRY_RUN" == "true" || "$DRY_RUN" == "1" ]]; }

# URL-encode a string (for label names in API paths).
urlencode() { jq -nr --arg v "$1" '$v | @uri'; }

# --- GitHub API helpers ---------------------------------------------------
api() {
  local method="$1" path="$2"
  shift 2
  local url="$REPO_API/$path"
  local args=(-X "$method" -sS \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28")
  if [[ "$#" -gt 0 ]]; then
    args+=(-d "$1")
  fi
  if is_dry_run; then
    echo "[dry-run] curl $method $url ${1:+--data "$1"}"
  else
    curl "${args[@]}" "$url"
  fi
}

# Extract the owner/repo for the /repos endpoint.
repo_path="repos/$REPO"

# --- Sync repository metadata --------------------------------------------
sync_repository() {
  if ! yq -e 'has("repository")' "$SETTINGS_PATH" >/dev/null 2>&1; then
    echo "No repository: block found, skipping repository sync."
    return 0
  fi

  # Extract the repository block as JSON, then cherry-pick supported keys.
  # Topics are an array — handled separately via the topics endpoint.
  local repo_json patch topics_json
  repo_json="$(yq -o=json '.repository' "$SETTINGS_PATH")"
  topics_json="$(jq -c '.topics // []' <<<"$repo_json")"

  # Build a patch object containing only present, non-null scalar keys.
  patch="$(jq -c '
    del(.topics)
    | to_entries
    | map(select(.value != null))
    | from_entries
  ' <<<"$repo_json")"

  if [[ "$patch" != "{}" ]]; then
    echo "Syncing repository settings:"
    jq '.' <<<"$patch"
    api PATCH "$repo_path" "$patch" >/dev/null
  else
    echo "No repository fields to sync."
  fi

  # Topics: PUT /repos/{owner}/{repo}/topics
  if [[ "$topics_json" != "[]" ]]; then
    local names
    names="$(jq -c '{names: [.[]]}' <<<"$topics_json")"
    echo "Syncing topics:"
    jq -r '.names[]' <<<"$names" | sed 's/^/  - /'
    if is_dry_run; then
      echo "[dry-run] PUT $repo_path/topics $names"
    else
      curl -X PUT -sS \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -d "$names" \
        "$REPO_API/$repo_path/topics" >/dev/null
    fi
  fi
}

# --- Sync labels ----------------------------------------------------------
sync_labels() {
  if ! yq -e 'has("labels")' "$SETTINGS_PATH" >/dev/null 2>&1; then
    echo "No labels: block found, skipping label sync."
    return 0
  fi

  echo "Syncing labels:"

  # Fetch existing labels (paginate).
  local existing
  if is_dry_run; then
    existing="[]"
  else
    existing="$(curl -sS \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "$REPO_API/$repo_path/labels?per_page=100&page=1")"
    # Handle pagination if more than 100 labels.
    local page=2
    while [[ "$(echo "$existing" | jq 'length')" -ge 100 ]] 2>/dev/null; do
      local more
      more="$(curl -sS \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "$REPO_API/$repo_path/labels?per_page=100&page=$page")"
      [[ "$(echo "$more" | jq 'length')" -eq 0 ]] && break
      existing="$(jq -s '.[0] + .[1]' <<<"$existing"$'\n'"$more")"
      page=$((page + 1))
    done
  fi

  local desired
  desired="$(yq -o=json '.labels' "$SETTINGS_PATH")"

  # Build lookup maps.
  declare -A existing_map desired_map
  while IFS=$'\t' read -r name color desc; do
    existing_map["$name"]="$color"$'\t'"$desc"
  done < <(jq -r '.[] | [.name, .color, .description] | @tsv' <<<"$existing")

  # Create or update desired labels.
  local count=0
  while IFS=$'\t' read -r name color desc; do
    [[ -z "$name" ]] && continue
    desired_map["$name"]=1
    local body
    body="$(jq -nc --arg n "$name" --arg c "$color" --arg d "$desc" \
      '{new_name: $n, color: $c, description: $d}')"

    if [[ -n "${existing_map["$name"]:-}" ]]; then
      # Compare — only PATCH if something changed.
      local old_color old_desc
      old_color="$(printf '%s' "${existing_map["$name"]}" | cut -f1)"
      old_desc="$(printf '%s' "${existing_map["$name"]}" | cut -f2)"
      # Normalize colors (strip leading #, uppercase).
      old_color="${old_color#\#}"; old_color="${old_color^^}"
      color="${color#\#}"; color="${color^^}"
      if [[ "$old_color" == "$color" && "$old_desc" == "$desc" ]]; then
        echo "  = $name (unchanged)"
        continue
      fi
      echo "  ~ $name (updating)"
      if ! is_dry_run; then
        local enc; enc="$(urlencode "$name")"
        curl -X PATCH -sS \
          -H "Authorization: Bearer $GITHUB_TOKEN" \
          -H "Accept: application/vnd.github+json" \
          -d "$body" \
          "$REPO_API/$repo_path/labels/$enc" >/dev/null
      fi
    else
      echo "  + $name (creating)"
      if ! is_dry_run; then
        local create_body
        create_body="$(jq -nc --arg n "$name" --arg c "$color" --arg d "$desc" \
          '{name: $n, color: $c, description: $d}')"
        curl -X POST -sS \
          -H "Authorization: Bearer $GITHUB_TOKEN" \
          -H "Accept: application/vnd.github+json" \
          -d "$create_body" \
          "$REPO_API/$repo_path/labels" >/dev/null
      fi
    fi
    count=$((count + 1))
  done < <(jq -r '.[] | [.name, .color, (.description // "")] | @tsv' <<<"$desired")

  # Delete labels not in the desired set.
  for name in "${!existing_map[@]}"; do
    if [[ -z "${desired_map["$name"]:-}" ]]; then
      echo "  - $name (deleting)"
      if ! is_dry_run; then
        local enc; enc="$(urlencode "$name")"
        curl -X DELETE -sS \
          -H "Authorization: Bearer $GITHUB_TOKEN" \
          -H "Accept: application/vnd.github+json" \
          "$REPO_API/$repo_path/labels/$enc" >/dev/null
      fi
    fi
  done

  echo "Labels synced: $count desired."
}

echo "::group::Sync repository settings"
sync_repository
echo "::endgroup::"

echo "::group::Sync labels"
sync_labels
echo "::endgroup::"

echo "Settings sync complete."
