#!/usr/bin/env bash
# Syncs .github/settings.yml to repository settings via the GitHub REST API.
# App-free alternative to probot/settings.
set -euo pipefail

if [[ -n "${DEBUG:-}" ]]; then set -x; fi

SETTINGS_PATH="${SETTINGS_PATH:-.github/settings.yml}"
DRY_RUN="${DRY_RUN:-false}"

# Token: $GITHUB_TOKEN, then $GH_TOKEN, then `gh auth token` (local runs).
GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [[ -z "$GITHUB_TOKEN" ]] && command -v gh >/dev/null 2>&1; then
  GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
  [[ -n "$GITHUB_TOKEN" ]] && echo "Using token from gh auth."
fi
if [[ -z "$GITHUB_TOKEN" ]]; then
  echo "::error::No token found. Pass the github-token input (in Actions) or set GITHUB_TOKEN." >&2
  exit 1
fi

if [[ ! -f "$SETTINGS_PATH" ]]; then
  echo "::error::Settings file not found at $SETTINGS_PATH" >&2
  exit 1
fi

# GITHUB_API_URL is set on every runner: https://api.github.com on github.com,
# https://<host>/api/v3 on GHES. Both take /repos/... appended directly.
API_BASE="${GITHUB_API_URL:-https://api.github.com}"

# Determine repository (owner/name): REPOSITORY env var, then
# GITHUB_REPOSITORY (set on Actions runners), then the origin remote of the
# current git checkout (local runs).
REPO="${REPOSITORY:-"${GITHUB_REPOSITORY:-}"}"
if [[ -z "$REPO" ]] && command -v git >/dev/null 2>&1; then
  origin_url="$(git remote get-url origin 2>/dev/null || true)"
  origin_url="${origin_url%.git}"
  if [[ "$origin_url" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
    REPO="${BASH_REMATCH[1]}"
    echo "Repository detected from origin remote: $REPO"
  fi
fi
if [[ -z "$REPO" ]]; then
  echo "::error::Could not determine repository. Set REPOSITORY=owner/repo." >&2
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
  local args=(-X "$method" -sS --fail-with-body
    -H "Authorization: Bearer $GITHUB_TOKEN"
    -H "Accept: application/vnd.github+json"
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

# shellcheck disable=SC2016 # jq source, not a shell expansion
JQ_PROJECT='def project($t):
  . as $cur
  | if ($t | type) == "object" and ($cur | type) == "object" then
      [ $t | keys_unsorted[] | . as $k
        | select($cur | has($k))
        | {key: $k, value: ($cur[$k] | project($t[$k]))} ]
      | from_entries
    elif ($t | type) == "array" and ($cur | type) == "array"
         and ($t | length) == ($cur | length) then
      [ range($t | length) as $i | ($cur[$i] | project($t[$i])) ]
    else $cur end;
'

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

  # Fetch current settings to skip fields that already match; on read failure
  # degrade to syncing everything (the writes are idempotent).
  local current=""
  current="$(api GET "$repo_path" 2>/dev/null || true)"
  if [[ -z "$current" ]]; then
    echo "::warning::Could not fetch current repository settings; syncing all fields."
  elif [[ "$patch" != "{}" ]]; then
    patch="$(jq -c --argjson cur "$current" "${JQ_PROJECT}"'
      with_entries(select(.value as $v | ($cur[.key] | project($v)) != $v))' <<<"$patch")"
  fi

  if [[ "$patch" != "{}" ]]; then
    echo "Syncing repository settings:"
    jq '.' <<<"$patch"
    mutate PATCH "$repo_path" "$patch"
  else
    echo "Repository settings already match, nothing to sync."
  fi

  # Topics: PUT /repos/{owner}/{repo}/topics
  if [[ "$topics_json" != "[]" ]]; then
    if [[ -n "$current" ]] &&
      jq -e --argjson cur "$current" '($cur.topics // [] | sort) == sort' <<<"$topics_json" >/dev/null; then
      echo "Topics already match, skipping."
    else
      echo "Syncing topics:"
      jq -r '.[]' <<<"$topics_json" | sed 's/^/  - /'
      mutate PUT "$repo_path/topics" "$(jq -c '{names: .}' <<<"$topics_json")"
    fi
  fi

  # On/off toggles with dedicated PUT/DELETE endpoints (probot schema).
  sync_toggle enable_vulnerability_alerts vulnerability-alerts
  sync_toggle enable_automated_security_fixes automated-security-fixes
}

# vulnerability-alerts answers via status code (204 on / 404 off);
# automated-security-fixes answers 200 with {"enabled": bool}.
toggle_state() {
  local endpoint="$1" response status body
  if ! response="$(curl -sS -w $'\n%{http_code}' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$API_BASE/$repo_path/$endpoint" 2>/dev/null)"; then
    echo unknown
    return 0
  fi
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  case "$status" in
    204) echo true ;;
    404) echo false ;;
    200) jq -r 'if .enabled == true then "true"
                elif .enabled == false then "false"
                else "unknown" end' <<<"$body" 2>/dev/null || echo unknown ;;
    *) echo unknown ;;
  esac
}

# sync_toggle KEY ENDPOINT — PUT when the key is true, DELETE when false,
# no-op when absent or already in the desired state. Reads from $repo_json.
sync_toggle() {
  local key="$1" endpoint="$2" val
  val="$(jq -r --arg k "$key" 'if has($k) then .[$k] | tostring else "" end' <<<"$repo_json")"
  [[ "$val" != "true" && "$val" != "false" ]] && return 0
  if [[ "$(toggle_state "$endpoint")" == "$val" ]]; then
    echo "$key already $val, skipping."
    return 0
  fi
  if [[ "$val" == "true" ]]; then
    echo "Enabling $key"
    mutate PUT "$repo_path/$endpoint"
  else
    echo "Disabling $key"
    mutate DELETE "$repo_path/$endpoint"
  fi
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
      old_color="${old_color#\#}"
      old_color="${old_color^^}"
      color="${color#\#}"
      color="${color^^}"
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

# --- Sync rulesets -----------------------------------------------------------
sync_rulesets() {
  if ! yq -e 'has("rulesets")' "$SETTINGS_PATH" >/dev/null 2>&1; then
    echo "No rulesets: block found, skipping ruleset sync."
    return 0
  fi

  echo "Syncing rulesets:"

  local existing="[]" page=1 batch
  while :; do
    if ! batch="$(api GET "$repo_path/rulesets?per_page=100&page=$page")"; then
      if is_dry_run; then
        echo "::warning::Could not fetch existing rulesets; dry-run assumes none exist."
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
  desired="$(yq -o=json '.rulesets' "$SETTINGS_PATH")"

  local count changed=0
  count="$(jq 'length' <<<"$desired")"
  for ((i = 0; i < count; i++)); do
    local ruleset name existing_id
    ruleset="$(jq -c ".[$i]" <<<"$desired")"
    name="$(jq -r '.name' <<<"$ruleset")"
    existing_id="$(jq -r --arg n "$name" '.[] | select(.name == $n) | .id' <<<"$existing" | head -n1)"

    if [[ -n "$existing_id" ]]; then
      # The list endpoint omits rules/conditions — fetch the full ruleset and
      # compare its projection onto the desired shape; skip the PUT if equal.
      local full=""
      full="$(api GET "$repo_path/rulesets/$existing_id" 2>/dev/null || true)"
      # Sort rules by type on both sides first: GitHub canonicalizes rule
      # order on write, so YAML order must not affect the comparison.
      if [[ -n "$full" ]] &&
        jq -e --argjson cur "$full" "${JQ_PROJECT}"'
             def norm: if (.rules | type) == "array" then .rules |= sort_by(.type) else . end;
             norm as $d | ($cur | norm | project($d)) == $d' <<<"$ruleset" >/dev/null; then
        echo "  = $name (unchanged)"
        continue
      fi
      echo "  ~ $name (updating)"
      mutate PUT "$repo_path/rulesets/$existing_id" "$ruleset"
    else
      echo "  + $name (creating)"
      mutate POST "$repo_path/rulesets" "$ruleset"
    fi
    changed=$((changed + 1))
  done

  echo "Rulesets synced: $changed created or updated, $((count - changed)) unchanged."
}

echo "::group::Sync repository settings"
sync_repository
echo "::endgroup::"

echo "::group::Sync labels"
sync_labels
echo "::endgroup::"

echo "::group::Sync rulesets"
sync_rulesets
echo "::endgroup::"

echo "Settings sync complete."
