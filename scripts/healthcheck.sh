#!/usr/bin/env bash
# Checks that a GitHub repository follows a recommended baseline for a
# secure open source repository. Read-only — performs GET requests only.
#
# Usage: healthcheck.sh [OWNER/REPO] [--strict]
#
# The repository defaults to $GITHUB_REPOSITORY, then the origin remote of
# the current git checkout. With --strict, warnings also fail the run.
#
# Auth: $GITHUB_TOKEN, then $GH_TOKEN, then `gh auth token`. Checks that need
# admin access (secret scanning status, Actions token permissions, ...)
# degrade to warnings when the token cannot see them.
set -euo pipefail

if [[ -n "${DEBUG:-}" ]]; then set -x; fi

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

REPO="" STRICT=false
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=true ;;
    -h | --help)
      usage
      exit 0
      ;;
    */*) REPO="$arg" ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for tool in jq curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "::error::$tool is required but not found on PATH." >&2
    exit 1
  fi
done

# Resolve OWNER/REPO of the current checkout's origin remote, if any.
local_repo=""
if command -v git >/dev/null 2>&1; then
  origin_url="$(git remote get-url origin 2>/dev/null || true)"
  origin_url="${origin_url%.git}"
  if [[ "$origin_url" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
    local_repo="${BASH_REMATCH[1]}"
  fi
fi

REPO="${REPO:-${GITHUB_REPOSITORY:-$local_repo}}"
if [[ -z "$REPO" ]]; then
  echo "::error::Could not determine repository. Pass OWNER/REPO." >&2
  exit 2
fi

API_BASE="${GITHUB_API_URL:-https://api.github.com}"

TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [[ -z "$TOKEN" ]] && command -v gh >/dev/null 2>&1; then
  TOKEN="$(gh auth token 2>/dev/null || true)"
fi
AUTH=()
if [[ -n "$TOKEN" ]]; then
  AUTH=(-H "Authorization: Bearer $TOKEN")
fi

# --- Reporting ---------------------------------------------------------------
if [[ -t 1 ]]; then
  C_PASS=$'\033[32m' C_FAIL=$'\033[31m' C_WARN=$'\033[33m' C_DIM=$'\033[90m' C_OFF=$'\033[0m'
else
  C_PASS="" C_FAIL="" C_WARN="" C_DIM="" C_OFF=""
fi
PASSES=0 WARNS=0 FAILS=0
pass() {
  printf '  %sPASS%s  %s\n' "$C_PASS" "$C_OFF" "$1"
  PASSES=$((PASSES + 1))
}
fail() {
  printf '  %sFAIL%s  %s\n' "$C_FAIL" "$C_OFF" "$1"
  FAILS=$((FAILS + 1))
}
warn() {
  printf '  %sWARN%s  %s\n' "$C_WARN" "$C_OFF" "$1"
  WARNS=$((WARNS + 1))
}
skip() { printf '  %sSKIP%s  %s\n' "$C_DIM" "$C_OFF" "$1"; }
section() { printf '\n%s\n' "$1"; }

# check CONDITION PASS_MSG FAIL_MSG [LEVEL] — LEVEL is fail (default) or warn.
check() {
  local cond="$1" ok="$2" bad="$3" level="${4:-fail}"
  if [[ "$cond" == "true" ]]; then pass "$ok"; else "$level" "$bad"; fi
}

# --- GitHub API helper -------------------------------------------------------
# api_get PATH — sets STATUS (HTTP code) and BODY. Never fails the script.
STATUS="" BODY=""
api_get() {
  local out
  if ! out="$(curl -sS -w $'\n%{http_code}' "${AUTH[@]}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$API_BASE/$1" 2>&1)"; then
    STATUS=000 BODY=""
    return 0
  fi
  STATUS="${out##*$'\n'}"
  BODY="${out%$'\n'*}"
}

# path_exists PATH... — true if any of the given repo content paths exist.
path_exists() {
  local p
  for p in "$@"; do
    api_get "repos/$REPO/contents/$p"
    if [[ "$STATUS" == 200 ]]; then return 0; fi
  done
  return 1
}

echo "Healthcheck for $REPO"
if [[ -z "$TOKEN" ]]; then
  warn "no token found (GITHUB_TOKEN or gh auth) — admin-only checks will be inconclusive"
fi

# --- Repository settings -----------------------------------------------------
section "Repository settings"
api_get "repos/$REPO"
if [[ "$STATUS" != 200 ]]; then
  echo "::error::GET repos/$REPO returned HTTP $STATUS: $BODY" >&2
  exit 1
fi
repo_json="$BODY"
jqr() { jq -r "$1" <<<"$repo_json"; }

default_branch="$(jqr '.default_branch')"
is_private="$(jqr '.private')"
is_admin="$(jqr '.permissions.admin == true')"

check "$(jqr '.description != null and .description != ""')" \
  "description is set" "description is empty" warn
if [[ "$is_private" == "true" ]]; then
  skip "license check (private repository)"
else
  check "$(jqr '.license != null')" \
    "license detected ($(jqr '.license.spdx_id // .license.key'))" \
    "no license detected — add a LICENSE file"
fi
check "$(jqr '.delete_branch_on_merge == true')" \
  "delete_branch_on_merge enabled" "delete_branch_on_merge disabled" warn

# security_and_analysis is only present when the token has admin access.
if [[ "$(jqr '.security_and_analysis != null')" == "true" ]]; then
  check "$(jqr '.security_and_analysis.secret_scanning.status == "enabled"')" \
    "secret scanning enabled" "secret scanning disabled"
  check "$(jqr '.security_and_analysis.secret_scanning_push_protection.status == "enabled"')" \
    "secret scanning push protection enabled" "secret scanning push protection disabled"
  check "$(jqr '.security_and_analysis.dependabot_security_updates.status == "enabled"')" \
    "Dependabot security updates enabled" "Dependabot security updates disabled" warn
else
  warn "secret scanning status not visible — token lacks admin access"
fi

# --- Dependabot & vulnerability reporting ------------------------------------
section "Vulnerability management"
# 404 means disabled OR no admin read access — only trust it as "disabled"
# when the token actually has admin on the repo.
api_get "repos/$REPO/vulnerability-alerts"
if [[ "$STATUS" == 204 ]]; then
  pass "Dependabot alerts enabled"
elif [[ "$STATUS" == 404 && "$is_admin" == "true" ]]; then
  fail "Dependabot alerts disabled"
else
  warn "Dependabot alerts status not visible (HTTP $STATUS) — needs admin token"
fi

if [[ "$is_private" == "true" ]]; then
  skip "private vulnerability reporting (private repository)"
else
  api_get "repos/$REPO/private-vulnerability-reporting"
  if [[ "$STATUS" == 200 ]]; then
    check "$(jq -r '.enabled == true' <<<"$BODY")" \
      "private vulnerability reporting enabled" "private vulnerability reporting disabled"
  else
    warn "private vulnerability reporting status not visible (HTTP $STATUS)"
  fi
fi

if path_exists .github/dependabot.yml .github/dependabot.yaml; then
  pass ".github/dependabot.yml present (version updates)"
else
  warn "no .github/dependabot.yml — Dependabot version updates not configured"
fi

# --- Default branch protection -----------------------------------------------
section "Branch protection ($default_branch)"
api_get "repos/$REPO/branches/$default_branch"
protected="false"
if [[ "$STATUS" == 200 ]]; then
  protected="$(jq -r '.protected' <<<"$BODY")"
fi
rules="[]"
api_get "repos/$REPO/rules/branches/$default_branch"
if [[ "$STATUS" == 200 ]]; then rules="$BODY"; fi
rule_types="$(jq -r '[.[].type] | unique | join(", ")' <<<"$rules")"

if [[ "$protected" == "true" || "$(jq 'length' <<<"$rules")" -gt 0 ]]; then
  pass "default branch is protected${rule_types:+ (ruleset rules: $rule_types)}"
else
  fail "no branch protection or rulesets on default branch"
fi

# --- Actions configuration ----------------------------------------------------
section "GitHub Actions"
api_get "repos/$REPO/actions/permissions/workflow"
if [[ "$STATUS" == 200 ]]; then
  check "$(jq -r '.default_workflow_permissions == "read"' <<<"$BODY")" \
    "default GITHUB_TOKEN workflow permissions are read-only" \
    "default GITHUB_TOKEN workflow permissions are read-write — set to read-only"
  check "$(jq -r '.can_approve_pull_request_reviews == false' <<<"$BODY")" \
    "Actions cannot approve pull requests" \
    "Actions can create/approve pull requests — disable unless needed" warn
else
  warn "Actions workflow permissions not visible (HTTP $STATUS) — needs admin token"
fi

# --- Community health files ---------------------------------------------------
section "Community health files"
if [[ "$is_private" == "true" ]]; then
  skip "community profile (private repository)"
else
  api_get "repos/$REPO/community/profile"
  if [[ "$STATUS" == 200 ]]; then
    check "$(jq -r '.files.readme != null' <<<"$BODY")" "README present" "no README"
    check "$(jq -r '.files.code_of_conduct != null or .files.code_of_conduct_file != null' <<<"$BODY")" \
      "code of conduct present" "no code of conduct" warn
    check "$(jq -r '.files.contributing != null' <<<"$BODY")" \
      "contributing guide present" "no CONTRIBUTING guide" warn
  else
    warn "community profile not available (HTTP $STATUS)"
  fi
fi
if path_exists SECURITY.md .github/SECURITY.md docs/SECURITY.md; then
  pass "SECURITY.md present"
else
  warn "no SECURITY.md — add one (or provide it via the org-level .github repository)"
fi
if path_exists CODEOWNERS .github/CODEOWNERS docs/CODEOWNERS; then
  pass "CODEOWNERS present"
else
  warn "no CODEOWNERS file"
fi

# --- Local workflow checks (only when this checkout is the target repo) -------
wf_dir=".github/workflows"
if [[ -d "$wf_dir" && "${local_repo,,}" == "${REPO,,}" ]]; then
  section "Workflow hygiene (local checkout)"

  unpinned=()
  while IFS= read -r use; do
    [[ "$use" != *@* ]] && continue # local actions (./...) have no ref
    ref="${use##*@}"
    action="${use%@*}"
    if [[ ! "$ref" =~ ^[0-9a-f]{40}$ && "$ref" != sha256:* ]]; then
      unpinned+=("$action@$ref")
    fi
  done < <(grep -RhoE "uses:[[:space:]]*[^[:space:]#\"']+" "$wf_dir" 2>/dev/null |
    sed -E 's/uses:[[:space:]]*//' | sort -u)
  if [[ "${#unpinned[@]}" -eq 0 ]]; then
    pass "all actions pinned to a full commit SHA"
  else
    fail "actions not pinned to a commit SHA: ${unpinned[*]}"
  fi

  no_perms=()
  for wf in "$wf_dir"/*.yml "$wf_dir"/*.yaml; do
    [[ -f "$wf" ]] || continue
    if ! grep -Eq '^[[:space:]]*permissions:' "$wf"; then
      no_perms+=("${wf##*/}")
    fi
  done
  if [[ "${#no_perms[@]}" -eq 0 ]]; then
    pass "all workflows declare explicit permissions"
  else
    warn "workflows without an explicit permissions block: ${no_perms[*]}"
  fi

  if grep -Rq 'pull_request_target' "$wf_dir"; then
    warn "pull_request_target used — ensure untrusted PR code is never checked out and run"
  else
    pass "no pull_request_target triggers"
  fi
else
  section "Workflow hygiene"
  skip "current directory is not a checkout of $REPO — local checks skipped"
fi

# --- Summary -------------------------------------------------------------------
printf '\nSummary: %d passed, %d warnings, %d failed\n' "$PASSES" "$WARNS" "$FAILS"
if [[ "$FAILS" -gt 0 ]]; then
  exit 1
fi
if [[ "$STRICT" == "true" && "$WARNS" -gt 0 ]]; then
  echo "(--strict: treating warnings as failures)"
  exit 1
fi
