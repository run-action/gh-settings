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

# GITHUB_API_URL is set on every runner: https://api.github.com on github.com,
# https://<host>/api/v3 on GHES. Both take /repos/... appended directly.
API_BASE="${GITHUB_API_URL:-https://api.github.com}"

# Determine repository (owner/name) from GITHUB_REPOSITORY if available,
# otherwise let the user override via REPOSITORY env var.
REPO="${REPOSITORY:-"${GITHUB_REPOSITORY:-}"}"
if [[ -z "$REPO" ]]; then
  echo "::error::REPOSITORY or GITHUB_REPOSITORY must be set." >&2
  exit 1
fi
repo_path="repos/$REPO"

# GitHub-hosted ubuntu runners ship mikefarah/yq (Go) and jq.
for tool in yq jq curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "::error::$tool is required but not found on PATH." >&2
    exit 1
  fi
done

# Normalize dry-run to a boolean.
is_dry_run() { [[ "$DRY_RUN" == "true" || "$DRY_RUN" == "1" ]]; }

# URL-encode a string (for label names in API paths).
urlencode() { jq -nr --arg v "$1" '$v | @uri'; }

# --- GitHub API helpers ----------------------------------------------------
# api METHOD PATH [BODY] — always executes, fails loudly on HTTP errors.
api() {
  local method="$1" path="$2" body="${3:-}"
  local url="$API_BASE/$path"
  local args=(-X "$method" -sS --fail-with-body \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28")
  if [[ -n "$body" ]]; then
    args+=(-d "$body")
  fi
  local response
  if ! response="$(curl "${args[@]}" "$url")"; then
    echo "::error::$method $url failed: $response" >&2
    return 1
  fi
  printf '%s\n' "$response"
}

# mutate METHOD PATH [BODY] — like api, but only reports the request in dry-run.
mutate() {
  if is_dry_run; then
    echo "[dry-run] $1 $API_BASE/$2${3:+ --data $3}"
  else
    api "$@" >/dev/null
  fi
}

# --- Sync repository metadata ----------------------------------------------
# repository: follows the de facto probot/settings schema; repository_extra:
# holds additional "Update a repository" API fields outside that schema and
# is merged over repository: before the PATCH.
sync_repository() {
  if ! yq -e 'has("repository") or has("repository_extra")' "$SETTINGS_PATH" >/dev/null 2>&1; then
    echo "No repository: or repository_extra: block found, skipping repository sync."
    return 0
  fi

  # Extract the repository block as JSON, then cherry-pick supported keys.
  # Topics are an array — handled separately via the topics endpoint. The
  # probot/settings schema also allows a comma-separated string; accept both.
  local repo_json patch topics_json
  repo_json="$(yq -o=json '(.repository // {}) * (.repository_extra // {})' "$SETTINGS_PATH")"
  topics_json="$(jq -c '.topics // []
    | if type == "string" then split(",") | map(gsub("^\\s+|\\s+$"; "")) else . end' <<<"$repo_json")"

  # enable_vulnerability_alerts / enable_automated_security_fixes (probot
  # schema) are dedicated endpoints, not PATCH fields — handled separately.
  # Build a patch object containing only present, non-null keys.
  patch="$(jq -c 'del(.topics, .enable_vulnerability_alerts, .enable_automated_security_fixes)
    | with_entries(select(.value != null))' <<<"$repo_json")"

  if [[ "$patch" != "{}" ]]; then
    echo "Syncing repository settings:"
    jq '.' <<<"$patch"
    mutate PATCH "$repo_path" "$patch"
  else
    echo "No repository fields to sync."
  fi

  # Topics: PUT /repos/{owner}/{repo}/topics
  if [[ "$topics_json" != "[]" ]]; then
    echo "Syncing topics:"
    jq -r '.[]' <<<"$topics_json" | sed 's/^/  - /'
    mutate PUT "$repo_path/topics" "$(jq -c '{names: .}' <<<"$topics_json")"
  fi

  # On/off toggles with dedicated PUT/DELETE endpoints (probot schema).
  sync_toggle enable_vulnerability_alerts vulnerability-alerts
  sync_toggle enable_automated_security_fixes automated-security-fixes
}

# sync_toggle KEY ENDPOINT — PUT when the key is true, DELETE when false,
# no-op when absent. Reads from $repo_json.
sync_toggle() {
  local key="$1" endpoint="$2" val
  val="$(jq -r --arg k "$key" 'if has($k) then .[$k] | tostring else "" end' <<<"$repo_json")"
  case "$val" in
    true)
      echo "Enabling $key"
      mutate PUT "$repo_path/$endpoint"
      ;;
    false)
      echo "Disabling $key"
      mutate DELETE "$repo_path/$endpoint"
      ;;
  esac
}

# --- Sync labels ------------------------------------------------------------
sync_labels() {
  if ! yq -e 'has("labels")' "$SETTINGS_PATH" >/dev/null 2>&1; then
    echo "No labels: block found, skipping label sync."
    return 0
  fi

  echo "Syncing labels:"

  # Fetch existing labels (paginated). Reads also run in dry-run mode so the
  # reported diff is accurate; if the token cannot read labels, degrade to an
  # empty baseline instead of failing the preview.
  local existing="[]" page=1 batch
  while :; do
    if ! batch="$(api GET "$repo_path/labels?per_page=100&page=$page")"; then
      if is_dry_run; then
        echo "::warning::Could not fetch existing labels; dry-run diff assumes none exist."
        existing="[]"
        break
      fi
      return 1
    fi
    existing="$(jq -c --argjson batch "$batch" '. + $batch' <<<"$existing")"
    if [[ "$(jq 'length' <<<"$batch")" -lt 100 ]]; then
      break
    fi
    page=$((page + 1))
  done

  local desired
  desired="$(yq -o=json '.labels' "$SETTINGS_PATH")"

  # Build lookup maps.
  declare -A existing_map desired_map
  while IFS=$'\t' read -r name color desc; do
    existing_map["$name"]="$color"$'\t'"$desc"
  done < <(jq -r '.[] | [.name, .color, (.description // "")] | @tsv' <<<"$existing")

  # Create or update desired labels.
  local count=0
  while IFS=$'\t' read -r name color desc; do
    [[ -z "$name" ]] && continue
    desired_map["$name"]=1

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
      local body
      body="$(jq -nc --arg n "$name" --arg c "$color" --arg d "$desc" \
        '{new_name: $n, color: $c, description: $d}')"
      mutate PATCH "$repo_path/labels/$(urlencode "$name")" "$body"
    else
      echo "  + $name (creating)"
      local create_body
      create_body="$(jq -nc --arg n "$name" --arg c "$color" --arg d "$desc" \
        '{name: $n, color: $c, description: $d}')"
      mutate POST "$repo_path/labels" "$create_body"
    fi
    count=$((count + 1))
  done < <(jq -r '.[] | [.name, .color, (.description // "")] | @tsv' <<<"$desired")

  # Delete labels not in the desired set.
  for name in "${!existing_map[@]}"; do
    if [[ -z "${desired_map["$name"]:-}" ]]; then
      echo "  - $name (deleting)"
      mutate DELETE "$repo_path/labels/$(urlencode "$name")"
    fi
  done

  echo "Labels synced: $count created or updated."
}

echo "::group::Sync repository settings"
sync_repository
echo "::endgroup::"

echo "::group::Sync labels"
sync_labels
echo "::endgroup::"

echo "Settings sync complete."
