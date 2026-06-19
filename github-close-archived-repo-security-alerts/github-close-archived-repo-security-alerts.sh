#!/bin/bash
set -euo pipefail

###
## GitHub Close Security Alerts
## Dismisses or resolves all open security alerts across all repositories
## in a GitHub organization.
##
## Supports three alert types:
##   - dependabot    : Vulnerable dependency alerts
##   - code-scanning : Static analysis / SAST findings
##   - secret-scanning: Leaked secrets
##
## Usage:
##   ./github-close-security-alerts.sh [--type <type>] [--dry-run]
##
## Options:
##   --type <type>   Alert type: dependabot | code-scanning | secret-scanning | all (default: all)
##   --dry-run       List alerts without dismissing them
##
## Environment variables:
##   GITHUB_TOKEN    Required. PAT with security_events, repo scope
##   ORG             Required. GitHub organization name
###

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

ALERT_TYPE='all'   # default, can be overridden by --type flag
DRY_RUN=false

###
## Color codes for output
###
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

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

###
## VALIDATION
###
if [ -z "${GITHUB_TOKEN}" ]; then
  print_error "GITHUB_TOKEN is empty. Please set your token and try again"
  exit 1
fi

if [ -z "${ORG}" ]; then
  print_error "ORG is empty. Please set the organization name and try again"
  exit 1
fi

if ! command -v jq &> /dev/null; then
  print_error "jq is not installed. Please install jq for JSON parsing."
  print_status "Install on macOS: brew install jq"
  print_status "Install on Ubuntu/Debian: sudo apt-get install jq"
  exit 1
fi

print_status "Validating GitHub token..."
TOKEN_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  "${API_URL_PREFIX}/user")

if [ "${TOKEN_STATUS}" -ne 200 ]; then
  print_error "GITHUB_TOKEN is invalid or does not have required permissions (HTTP ${TOKEN_STATUS})."
  exit 1
fi

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
## CLOSE DEPENDABOT ALERTS
###
close_dependabot_alerts() {
  local repo="$1"
  print_status "[dependabot] Processing ${ORG}/${repo}..."

  local alerts
  alerts=$(get_all_pages "${API_URL_PREFIX}/repos/${ORG}/${repo}/dependabot/alerts?state=open")

  local count
  count=$(echo "${alerts}" | jq 'length')

  if [ "${count}" -eq 0 ]; then
    print_status "[dependabot] No open alerts in ${repo}"
    return
  fi

  print_status "[dependabot] Found ${count} open alert(s) in ${repo}"

  for i in $(seq 0 $((count - 1))); do
    local alert_number summary
    alert_number=$(echo "${alerts}" | jq -r ".[${i}].number")
    summary=$(echo "${alerts}" | jq -r ".[${i}].security_advisory.summary // \"N/A\"")

    if [ "${DRY_RUN}" = true ]; then
      print_warning "[DRY-RUN] Would dismiss dependabot alert #${alert_number} in ${ORG}/${repo}: ${summary}"
      continue
    fi

    local http_status
    http_status=$(curl -s -o /dev/null -w "%{http_code}" \
      -X PATCH \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Content-Type: application/json" \
      -d "{\"state\":\"dismissed\",\"dismissed_reason\":\"${DEPENDABOT_REASON}\",\"dismissed_comment\":\"Bulk dismissed by repository automation\"}" \
      "${API_URL_PREFIX}/repos/${ORG}/${repo}/dependabot/alerts/${alert_number}")

    if [ "${http_status}" -eq 200 ]; then
      print_success "[dependabot] Dismissed alert #${alert_number} in ${ORG}/${repo}"
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),${ORG},${repo},dependabot,${alert_number},\"${summary}\",dismissed" >> "${REPORT_FILE}"
      TOTAL_CLOSED=$((TOTAL_CLOSED + 1))
    else
      print_error "[dependabot] Failed to dismiss alert #${alert_number} in ${ORG}/${repo} (HTTP ${http_status})"
      TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    fi

    sleep 0.2  # Respect rate limits
  done
}

###
## CLOSE CODE SCANNING ALERTS
###
close_code_scanning_alerts() {
  local repo="$1"
  print_status "[code-scanning] Processing ${ORG}/${repo}..."

  local alerts
  alerts=$(get_all_pages "${API_URL_PREFIX}/repos/${ORG}/${repo}/code-scanning/alerts?state=open")

  local count
  count=$(echo "${alerts}" | jq 'length')

  if [ "${count}" -eq 0 ]; then
    print_status "[code-scanning] No open alerts in ${repo}"
    return
  fi

  print_status "[code-scanning] Found ${count} open alert(s) in ${repo}"

  for i in $(seq 0 $((count - 1))); do
    local alert_number summary
    alert_number=$(echo "${alerts}" | jq -r ".[${i}].number")
    summary=$(echo "${alerts}" | jq -r ".[${i}].rule.description // \"N/A\"")

    if [ "${DRY_RUN}" = true ]; then
      print_warning "[DRY-RUN] Would dismiss code-scanning alert #${alert_number} in ${ORG}/${repo}: ${summary}"
      continue
    fi

    local dismissed_reason_json
    dismissed_reason_json=$(printf '%s' "${CODE_SCANNING_REASON}" | jq -Rs '.')

    local http_status
    http_status=$(curl -s -o /dev/null -w "%{http_code}" \
      -X PATCH \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Content-Type: application/json" \
      -d "{\"state\":\"dismissed\",\"dismissed_reason\":${dismissed_reason_json},\"dismissed_comment\":\"Bulk dismissed by repository automation\"}" \
      "${API_URL_PREFIX}/repos/${ORG}/${repo}/code-scanning/alerts/${alert_number}")

    if [ "${http_status}" -eq 200 ]; then
      print_success "[code-scanning] Dismissed alert #${alert_number} in ${ORG}/${repo}"
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),${ORG},${repo},code-scanning,${alert_number},\"${summary}\",dismissed" >> "${REPORT_FILE}"
      TOTAL_CLOSED=$((TOTAL_CLOSED + 1))
    else
      print_error "[code-scanning] Failed to dismiss alert #${alert_number} in ${ORG}/${repo} (HTTP ${http_status})"
      TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    fi

    sleep 0.2
  done
}

###
## CLOSE SECRET SCANNING ALERTS
###
close_secret_scanning_alerts() {
  local repo="$1"
  print_status "[secret-scanning] Processing ${ORG}/${repo}..."

  local alerts
  alerts=$(get_all_pages "${API_URL_PREFIX}/repos/${ORG}/${repo}/secret-scanning/alerts?state=open")

  local count
  count=$(echo "${alerts}" | jq 'length')

  if [ "${count}" -eq 0 ]; then
    print_status "[secret-scanning] No open alerts in ${repo}"
    return
  fi

  print_status "[secret-scanning] Found ${count} open alert(s) in ${repo}"

  for i in $(seq 0 $((count - 1))); do
    local alert_number secret_type
    alert_number=$(echo "${alerts}" | jq -r ".[${i}].number")
    secret_type=$(echo "${alerts}" | jq -r ".[${i}].secret_type_display_name // \"N/A\"")

    if [ "${DRY_RUN}" = true ]; then
      print_warning "[DRY-RUN] Would resolve secret-scanning alert #${alert_number} in ${ORG}/${repo}: ${secret_type}"
      continue
    fi

    local http_status
    http_status=$(curl -s -o /dev/null -w "%{http_code}" \
      -X PATCH \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Content-Type: application/json" \
      -d "{\"state\":\"resolved\",\"resolution\":\"${SECRET_SCANNING_RESOLUTION}\"}" \
      "${API_URL_PREFIX}/repos/${ORG}/${repo}/secret-scanning/alerts/${alert_number}")

    if [ "${http_status}" -eq 200 ]; then
      print_success "[secret-scanning] Resolved alert #${alert_number} in ${ORG}/${repo}"
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),${ORG},${repo},secret-scanning,${alert_number},\"${secret_type}\",resolved" >> "${REPORT_FILE}"
      TOTAL_CLOSED=$((TOTAL_CLOSED + 1))
    else
      print_error "[secret-scanning] Failed to resolve alert #${alert_number} in ${ORG}/${repo} (HTTP ${http_status})"
      TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    fi

    sleep 0.2
  done
}

###
## FETCH ARCHIVED REPOS IN ORG
###
print_status "Fetching archived repositories in ${ORG}..."
REPOS=()
page=1

while true; do
  response=$(curl -s \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API_URL_PREFIX}/orgs/${ORG}/repos?type=all&per_page=100&page=${page}")

  if echo "${response}" | jq -e '.message' &>/dev/null; then
    print_error "Failed to fetch repositories: $(echo "${response}" | jq -r '.message')"
    exit 1
  fi

  count=$(echo "${response}" | jq 'length')
  if [ "${count}" -eq 0 ]; then
    break
  fi

  while IFS= read -r repo; do
    REPOS+=("${repo}")
  done < <(echo "${response}" | jq -r '.[] | select(.archived == true) | .name')

  page=$((page + 1))
done

REPO_COUNT=${#REPOS[@]}
print_success "Found ${REPO_COUNT} archived repositories"

if [ "${DRY_RUN}" = true ]; then
  print_warning "DRY-RUN mode enabled — no alerts will be dismissed"
fi
echo ""

###
## MAIN LOOP — iterate over all repos
###
for repo in "${REPOS[@]}"; do
  case "${ALERT_TYPE}" in
    dependabot)
      close_dependabot_alerts "${repo}"
      ;;
    code-scanning)
      close_code_scanning_alerts "${repo}"
      ;;
    secret-scanning)
      close_secret_scanning_alerts "${repo}"
      ;;
    all)
      close_dependabot_alerts "${repo}"
      close_code_scanning_alerts "${repo}"
      close_secret_scanning_alerts "${repo}"
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
