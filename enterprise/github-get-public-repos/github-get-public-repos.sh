#!/usr/bin/env bash
# =============================================================================
# github-get-public-repos.sh
#
# Lists all repositories with public visibility across every organisation in a
# GitHub Enterprise account and writes a timestamped CSV report.
#
# Usage:
#   export GITHUB_TOKEN=ghp_yourtoken
#   export ENTERPRISE=my-enterprise
#   ./github-get-public-repos.sh
#
# Environment variables:
#   GITHUB_TOKEN    Required. PAT with read:org and repo scope
#   ENTERPRISE      Required. GitHub Enterprise slug
#   API_URL_PREFIX  Optional. GitHub API base URL (default: https://api.github.com)
#   REPORT_DIR      Optional. Output directory (default: ./reports)
#   ORGS            Optional. Comma-separated org list; skips enterprise lookup
#   ORG_FILTER      Optional. ERE regex to keep only matching org names
#   ORG_EXCLUDE     Optional. ERE regex to drop matching org names
#
# Requirements:
#   - curl
#   - jq
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/github-common.sh
source "${SCRIPT_DIR}/../../lib/github-common.sh"
# Redirect status output to stderr — stdout is reserved for CSV data
print_status()  { echo -e "${BLUE}[INFO]${NC}    $1" >&2; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }
print_error()   { echo -e "${RED}[ERROR]${NC}   $1" >&2; }

###
## GLOBAL VARIABLES
###
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ENTERPRISE=${ENTERPRISE:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
ORGS_OVERRIDE=${ORGS:-''}
ORG_FILTER=${ORG_FILTER:-''}
ORG_EXCLUDE=${ORG_EXCLUDE:-''}
REPORT_DIR=${REPORT_DIR:-'./reports'}

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_CSV="${REPORT_DIR}/public_repos_${TIMESTAMP}.csv"

###
## Temp file management
###
TEMP_DIR=$(mktemp -d)
ROWS_TEMP="${TEMP_DIR}/rows.csv"

cleanup() {
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

###
## Prerequisite checks
###
check_prerequisites() {
  print_status "Checking prerequisites..."
  require_command curl
  require_command jq
  require_env_var GITHUB_TOKEN "GITHUB_TOKEN"
  print_success "Prerequisites OK"
}

###
## resolve_orgs
## Returns the final deduplicated list of org logins to scan.
###
resolve_orgs() {
  local raw_orgs

  if [ -n "${ORGS_OVERRIDE}" ]; then
    print_status "Using ORGS override: ${ORGS_OVERRIDE}"
    raw_orgs=$(echo "${ORGS_OVERRIDE}" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  else
    raw_orgs=$(get_enterprise_orgs)
  fi

  # Apply ORG_FILTER include regex
  if [ -n "${ORG_FILTER}" ]; then
    local _rc=0
    echo "" | grep -qE "${ORG_FILTER}" 2>/dev/null || _rc=$?
    if [ "${_rc}" -eq 2 ]; then
      print_error "ORG_FILTER is not a valid ERE regex: ${ORG_FILTER}"
      exit 1
    fi
    raw_orgs=$(echo "${raw_orgs}" | grep -E "${ORG_FILTER}" || true)
  fi

  # Apply ORG_EXCLUDE regex
  if [ -n "${ORG_EXCLUDE}" ]; then
    local _rc=0
    echo "" | grep -qE "${ORG_EXCLUDE}" 2>/dev/null || _rc=$?
    if [ "${_rc}" -eq 2 ]; then
      print_error "ORG_EXCLUDE is not a valid ERE regex: ${ORG_EXCLUDE}"
      exit 1
    fi
    raw_orgs=$(echo "${raw_orgs}" | grep -Ev "${ORG_EXCLUDE}" || true)
  fi

  echo "${raw_orgs}" | sort -u | grep -v '^$'
}

###
## get_public_repos_for_org <org>
## Appends CSV rows (no header) for every public repo in the org to ROWS_TEMP.
## Fetches all repos and filters by visibility=="public" in jq rather than
## using the ?type=public query param, which can silently return [] for
## enterprise-managed orgs even when public repos exist.
###
get_public_repos_for_org() {
  local org="$1"
  local page=1
  local total=0

  while true; do
    local resp raw_count repos_on_page

    # Fetch all repos — do NOT use ?type=public here; it is unreliable for
    # enterprise-managed orgs and can return an empty array for orgs that
    # genuinely have public repositories.
    resp=$(gh_api "/orgs/${org}/repos?per_page=100&page=${page}&sort=full_name")

    if [[ "${resp}" == "__404__" || "${resp}" == "__422__" || -z "${resp}" ]]; then
      print_warning "  Could not access repos for org '${org}'. Skipping."
      return 0
    fi

    # Use raw repo count for pagination decisions (not filtered public count).
    raw_count=$(echo "${resp}" | jq 'length' 2>/dev/null || echo 0)

    if [ "${raw_count}" -eq 0 ]; then
      break
    fi

    # Filter to public visibility only, then format as CSV.
    repos_on_page=$(echo "${resp}" | jq -r '
      [.[] | select(.visibility == "public")] |
      .[] | [
        .owner.login,
        .name,
        .full_name,
        .visibility,
        .html_url,
        (.description // "" | gsub("[,\"\n\r]"; " ")),
        .default_branch,
        (.fork | tostring),
        (.archived | tostring),
        .pushed_at,
        .created_at,
        .updated_at
      ] | @csv
    ' 2>/dev/null || true)

    if [ -n "${repos_on_page}" ]; then
      echo "${repos_on_page}" >> "${ROWS_TEMP}"
      local count
      count=$(echo "${repos_on_page}" | wc -l)
      total=$(( total + count ))
    fi

    # Stop when the page is not full — no more pages to fetch.
    if [ "${raw_count}" -lt 100 ]; then
      break
    fi
    page=$(( page + 1 ))
  done

  if [ "${total}" -gt 0 ]; then
    print_status "  Found ${total} public repo(s) in '${org}'"
  else
    print_status "  No public repos in '${org}'"
  fi
}

###
## Main
###
main() {
  check_prerequisites
  validate_github_token

  mkdir -p "${REPORT_DIR}"

  # Resolve org list
  local orgs
  orgs=$(resolve_orgs)

  if [ -z "${orgs}" ]; then
    print_error "No organisations found. Check your ENTERPRISE/ORGS/ORG_FILTER settings."
    exit 1
  fi

  local org_count
  org_count=$(echo "${orgs}" | wc -l)
  print_success "Found ${org_count} organisation(s) to scan."

  # Scan each org
  local scanned=0
  while IFS= read -r org; do
    scanned=$(( scanned + 1 ))
    print_status "[${scanned}/${org_count}] Scanning org: ${org}"
    get_public_repos_for_org "${org}"
  done <<< "${orgs}"

  # Write final CSV
  local total_repos=0
  echo "org,repo_name,full_name,visibility,html_url,description,default_branch,fork,archived,pushed_at,created_at,updated_at" > "${REPORT_CSV}"

  if [ -f "${ROWS_TEMP}" ] && [ -s "${ROWS_TEMP}" ]; then
    sort -t, -k3 "${ROWS_TEMP}" >> "${REPORT_CSV}"
    total_repos=$(wc -l < "${ROWS_TEMP}")
  fi

  print_success "-------------------------------------------"
  print_success "Scan complete."
  print_success "  Orgs scanned : ${org_count}"
  print_success "  Public repos : ${total_repos}"
  print_success "  Report       : ${REPORT_CSV}"
  print_success "-------------------------------------------"
}

main
