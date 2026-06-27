#!/usr/bin/env bash
# =============================================================================
# github-close-archived-repo-security-alerts.sh
#
# Dismisses or resolves all open security alerts (Dependabot, code scanning,
# and secret scanning) across all repositories in a GitHub organisation.
#
# Usage:
#   export GITHUB_TOKEN=ghp_yourtoken
#   export ORG=my-org
#   ./github-close-archived-repo-security-alerts.sh [--type <type>] [--dry-run]
#
# Options:
#   --type <type>   Alert type: dependabot | code-scanning | secret-scanning | all (default: all)
#   --dry-run       List alerts without dismissing them
#
# Environment variables:
#   GITHUB_TOKEN                   Required. PAT with security_events and repo scope
#   ORG                            Required. GitHub organization name
#   API_URL_PREFIX                 Optional. GitHub API base URL (default: https://api.github.com)
#   DEPENDABOT_REASON              Optional. Dismiss reason for Dependabot alerts (default: tolerable_risk)
#   CODE_SCANNING_REASON           Optional. Dismiss reason for code scanning (default: won't fix)
#   SECRET_SCANNING_RESOLUTION     Optional. Resolution for secret scanning (default: wont_fix)
#
# Requirements:
#   - curl
#   - jq
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/github-common.sh
source "${SCRIPT_DIR}/../../lib/github-common.sh"

###
## GLOBAL VARIABLES
###
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORTS_DIR="$(dirname "$0")/reports"
REPORT_FILE="${REPORTS_DIR}/security_alerts_closed_${TIMESTAMP}.csv"

# Dismiss/resolve reasons — override via env if needed
DEPENDABOT_REASON=${DEPENDABOT_REASON:-'tolerable_risk'}       # fix_started | inaccurate | no_bandwidth | not_used | tolerable_risk
CODE_SCANNING_REASON=${CODE_SCANNING_REASON:-"won't fix"}      # false positive | won't fix | used in tests
SECRET_SCANNING_RESOLUTION=${SECRET_SCANNING_RESOLUTION:-'wont_fix'}  # false_positive | wont_fix | revoked | used_in_tests

ALERT_TYPE='all'
DRY_RUN=false

###
## ARGUMENT PARSING
###
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)
      ALERT_TYPE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      print_error "Unknown argument: $1"
      echo "Usage: $0 [--type dependabot|code-scanning|secret-scanning|all] [--dry-run]"
      exit 1
      ;;
  esac
done

# Validate alert type
case "$ALERT_TYPE" in
  dependabot|code-scanning|secret-scanning|all) ;;
  *)
    print_error "Invalid --type value: '${ALERT_TYPE}'. Must be one of: dependabot, code-scanning, secret-scanning, all"
    exit 1
    ;;
esac

# Validate dismiss/resolve reason values
case "${DEPENDABOT_REASON}" in
  fix_started|inaccurate|no_bandwidth|not_used|tolerable_risk) ;;
  *)
    print_error "Invalid DEPENDABOT_REASON '${DEPENDABOT_REASON}'. Must be one of: fix_started, inaccurate, no_bandwidth, not_used, tolerable_risk"
    exit 1
    ;;
esac

case "${SECRET_SCANNING_RESOLUTION}" in
  false_positive|wont_fix|revoked|used_in_tests) ;;
  *)
    print_error "Invalid SECRET_SCANNING_RESOLUTION '${SECRET_SCANNING_RESOLUTION}'. Must be one of: false_positive, wont_fix, revoked, used_in_tests"
    exit 1
    ;;
esac

###
## VALIDATION
###
require_env_var GITHUB_TOKEN "GitHub token"
require_env_var ORG "GitHub organization"
require_command jq
validate_github_token
print_success "GitHub token validated"
print_status "Organization : ${ORG}"
print_status "Alert type   : ${ALERT_TYPE}"
print_status "Dry run      : ${DRY_RUN}"
echo ""

###
## COUNTERS
###
TOTAL_CLOSED=0
TOTAL_ERRORS=0

###
## CSV REPORT HEADER
###
if [ "${DRY_RUN}" = false ]; then
  mkdir -p "${REPORTS_DIR}"
  echo "timestamp,org,repo,alert_type,alert_number,alert_summary,action" > "${REPORT_FILE}"
fi

###
## HELPER: paginate a GET endpoint and collect all JSON array items
###
get_all_pages() {
  local url="$1"
  local page=1
  local results='[]'

  while true; do
    local response
    response=$(curl -s \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${url}&per_page=100&page=${page}")

    # Empty body — feature not available for this repo
    if [ -z "${response}" ]; then
      break
    fi

    # Not valid JSON at all (e.g. HTML redirect page)
    if ! echo "${response}" | jq -e '.' &>/dev/null; then
      break
    fi

    # Response is an error object, not an array
    if ! echo "${response}" | jq -e 'type == "array"' &>/dev/null; then
      local msg
      msg=$(echo "${response}" | jq -r '.message // "unknown error"')
      # Silently skip expected "not enabled / not found" responses
      local msg_lower
      msg_lower=$(echo "${msg}" | tr '[:upper:]' '[:lower:]')
      if [[ "${msg_lower}" != *"not enabled"* ]] && \
         [[ "${msg_lower}" != *"advanced security"* ]] && \
         [[ "${msg_lower}" != *"not found"* ]] && \
         [[ "${msg_lower}" != *"disabled"* ]]; then
        print_warning "API message: ${msg}" >&2
      fi
      break
    fi

    local count
    count=$(echo "${response}" | jq 'length')
    if [ "${count}" -eq 0 ]; then
      break
    fi

    results=$(echo "${results} ${response}" | jq -s '.[0] + .[1]')
    page=$((page + 1))
  done

  echo "${results}"
}

###
## close_alerts <type> <repo> <summary_jq> <action> <payload>
## Generic alert-closer: fetches all open alerts on the given type endpoint,
## then dismisses/resolves each one.
##   type        — endpoint segment and display label (dependabot, code-scanning, secret-scanning)
##   repo        — repository name (without org prefix)
##   summary_jq  — jq expression to extract a human-readable alert summary from one alert object
##   action      — verb for messages and CSV (dismissed | resolved)
##   payload     — pre-built JSON body for the PATCH request
###
close_alerts() {
  local type="$1" repo="$2" summary_jq="$3" action="$4" payload="$5"
  local base_path="/repos/${ORG}/${repo}/${type}/alerts"

  print_status "[${type}] Processing ${ORG}/${repo}..."
  local alerts count
  alerts=$(get_all_pages "${API_URL_PREFIX}${base_path}?state=open")
  count=$(echo "${alerts}" | jq 'length')

  if [ "${count}" -eq 0 ]; then
    print_status "[${type}] No open alerts in ${repo}"
    return
  fi
  print_status "[${type}] Found ${count} open alert(s) in ${repo}"

  for i in $(seq 0 $((count - 1))); do
    local alert_number summary
    alert_number=$(echo "${alerts}" | jq -r ".[${i}].number")
    summary=$(echo "${alerts}" | jq -r ".[${i}] | ${summary_jq}")

    if [ "${DRY_RUN}" = true ]; then
      print_warning "[DRY-RUN] Would ${action} ${type} alert #${alert_number} in ${ORG}/${repo}: ${summary}"
      continue
    fi

    local http_status
    http_status=$(curl -s -o /dev/null -w "%{http_code}" \
      -X PATCH \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Content-Type: application/json" \
      -d "${payload}" \
      "${API_URL_PREFIX}${base_path}/${alert_number}")

    if [ "${http_status}" -eq 200 ]; then
      print_success "[${type}] ${action^} alert #${alert_number} in ${ORG}/${repo}"
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),${ORG},${repo},${type},${alert_number},\"${summary}\",${action}" >> "${REPORT_FILE}"
      TOTAL_CLOSED=$((TOTAL_CLOSED + 1))
    else
      print_error "[${type}] Failed to ${action} alert #${alert_number} in ${ORG}/${repo} (HTTP ${http_status})"
      TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    fi

    sleep 0.2
  done
}

###
## FETCH ARCHIVED REPOS IN ORG
###
print_status "Fetching archived repositories in ${ORG}..."
mapfile -t REPOS < <(gh_api_paginate "/orgs/${ORG}/repos?type=all&per_page=100" '.[] | select(.archived == true) | .name')
REPO_COUNT=${#REPOS[@]}
print_success "Found ${REPO_COUNT} archived repositories"

if [ "${DRY_RUN}" = true ]; then
  print_warning "DRY-RUN mode enabled — no alerts will be dismissed"
fi
echo ""

###
## MAIN LOOP — iterate over all repos
###
_DEP_PAYLOAD=$(jq -n --arg r "${DEPENDABOT_REASON}" \
  '{"state":"dismissed","dismissed_reason":$r,"dismissed_comment":"Bulk dismissed by repository automation"}')
_CS_PAYLOAD=$(jq -n --arg r "${CODE_SCANNING_REASON}" \
  '{"state":"dismissed","dismissed_reason":$r,"dismissed_comment":"Bulk dismissed by repository automation"}')
_SS_PAYLOAD=$(jq -n --arg r "${SECRET_SCANNING_RESOLUTION}" \
  '{"state":"resolved","resolution":$r}')

for repo in "${REPOS[@]}"; do
  case "${ALERT_TYPE}" in
    dependabot)
      close_alerts "dependabot"     "${repo}" '.security_advisory.summary // "N/A"' "dismissed" "${_DEP_PAYLOAD}"
      ;;
    code-scanning)
      close_alerts "code-scanning"  "${repo}" '.rule.description // "N/A"'          "dismissed" "${_CS_PAYLOAD}"
      ;;
    secret-scanning)
      close_alerts "secret-scanning" "${repo}" '.secret_type_display_name // "N/A"' "resolved"  "${_SS_PAYLOAD}"
      ;;
    all)
      close_alerts "dependabot"     "${repo}" '.security_advisory.summary // "N/A"' "dismissed" "${_DEP_PAYLOAD}"
      close_alerts "code-scanning"  "${repo}" '.rule.description // "N/A"'          "dismissed" "${_CS_PAYLOAD}"
      close_alerts "secret-scanning" "${repo}" '.secret_type_display_name // "N/A"' "resolved"  "${_SS_PAYLOAD}"
      ;;
  esac
  echo ""
done

###
## SUMMARY
###
echo "=========================================="
if [ "${DRY_RUN}" = true ]; then
  print_warning "DRY-RUN complete. No alerts were modified."
else
  print_success "Done! Alerts closed : ${TOTAL_CLOSED}"
  if [ "${TOTAL_ERRORS}" -gt 0 ]; then
    print_warning "Errors encountered  : ${TOTAL_ERRORS}"
  fi
  print_status "Report saved to     : ${REPORT_FILE}"
fi
echo "=========================================="
