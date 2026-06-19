#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/github-common.sh
source "${SCRIPT_DIR}/../lib/github-common.sh"
# Redirect status output to stderr — stdout is reserved for CSV data
print_status()  { echo -e "${BLUE}[INFO]${NC}    $1" >&2; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }
print_error()   { echo -e "${RED}[ERROR]${NC}   $1" >&2; }

###
## GitHub Enterprise Public Repo Discovery
## Lists all repositories with public visibility across every organisation
## in a GitHub Cloud Enterprise account and writes a timestamped CSV report.
##
## Usage:
##   export GITHUB_TOKEN=ghp_yourtoken
##   export ENTERPRISE=my-enterprise
##   ./github-get-public-repos.sh
##
## Optional env vars:
##   API_URL_PREFIX  - GitHub API base URL (default: https://api.github.com)
##   REPORT_DIR      - Output directory    (default: ./reports)
##   ORGS            - Comma-separated org list; skips enterprise org lookup
##   ORG_FILTER      - ERE regex to keep only matching org names (e.g. '^my-enterprise-prefix')
##   ORG_EXCLUDE     - ERE regex to drop matching org names
###

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
## GitHub REST API helper — handles rate-limit retries (up to 5 attempts).
## Usage: gh_api <path_or_full_url>
## Outputs response body; returns __404__ or __422__ for those status codes.
###
gh_api() {
  local url="$1"
  [[ "${url}" == http* ]] || url="${API_URL_PREFIX}${url}"

  local attempt
  for attempt in 1 2 3 4 5; do
    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${url}")
    http_code=$(echo "${response}" | tail -1)
    body=$(echo "${response}" | head -n -1)

    case "${http_code}" in
      200) echo "${body}"; return 0 ;;
      404) echo "__404__"; return 0 ;;
      422) echo "__422__"; return 0 ;;
      403|429)
        print_warning "Rate limited (HTTP ${http_code}). Sleeping 60s before retry ${attempt}/5..." >&2
        sleep 60
        ;;
      *)
        print_warning "HTTP ${http_code} for ${url} (attempt ${attempt}/5)" >&2
        sleep 5
        ;;
    esac
  done

  print_error "Failed to GET ${url} after 5 attempts"
  return 1
}

###
## Validate token and print authenticated user
###
validate_token() {
  print_status "Validating GitHub token..."
  local resp login
  resp=$(gh_api "/user")
  login=$(echo "${resp}" | jq -r '.login // empty')
  if [ -z "${login}" ]; then
    print_error "GITHUB_TOKEN is invalid or lacks required scopes."
    exit 1
  fi
  print_success "Token valid — authenticated as: ${login}"
}

###
## _paginate_orgs_endpoint <jq_filter> <url_template_with_PAGE_placeholder>
## Paginates an org-list endpoint, prints one login per line.
###
_paginate_orgs_endpoint() {
  local jq_filter="$1"
  local url_template="$2"
  local page=1
  while true; do
    local url resp orgs_on_page count
    url="${url_template/PAGE/${page}}"
    resp=$(gh_api "${url}")
    if [[ "${resp}" == "__404__" || "${resp}" == "__422__" || -z "${resp}" ]]; then
      break
    fi
    orgs_on_page=$(echo "${resp}" | jq -r "${jq_filter}" 2>/dev/null || true)
    if [ -z "${orgs_on_page}" ]; then
      break
    fi
    echo "${orgs_on_page}"
    count=$(echo "${orgs_on_page}" | wc -l)
    if [ "${count}" -lt 100 ]; then
      break
    fi
    page=$(( page + 1 ))
  done
}

###
## _graphql_enterprise_orgs
## Queries GraphQL for enterprise orgs with cursor-based pagination.
## Prints one org login per line.
###
_graphql_enterprise_orgs() {
  local cursor="null"
  while true; do
    local query resp http_code body has_next end_cursor

    query=$(printf '{ "query": "{ enterprise(slug: \\"%s\\") { organizations(first: 100, after: %s) { nodes { login } pageInfo { hasNextPage endCursor } } } }" }' \
      "${ENTERPRISE}" "${cursor}")

    resp=$(curl -s -w "\n%{http_code}" \
      -X POST \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Content-Type: application/json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${API_URL_PREFIX}/graphql" \
      -d "${query}")

    http_code=$(echo "${resp}" | tail -1)
    body=$(echo "${resp}" | head -n -1)

    if [[ "${http_code}" != "200" ]]; then
      return 1
    fi

    local gql_errors
    gql_errors=$(echo "${body}" | jq -r '.errors // empty' 2>/dev/null || true)
    if [ -n "${gql_errors}" ]; then
      return 1
    fi

    echo "${body}" | jq -r '.data.enterprise.organizations.nodes[].login' 2>/dev/null || true

    has_next=$(echo "${body}"  | jq -r '.data.enterprise.organizations.pageInfo.hasNextPage')
    end_cursor=$(echo "${body}" | jq -r '.data.enterprise.organizations.pageInfo.endCursor')

    if [[ "${has_next}" != "true" ]]; then
      break
    fi
    cursor="\"${end_cursor}\""
  done
}

###
## get_enterprise_orgs
## Prints one org login per line.
## Strategy:
##   1. REST /enterprises/{slug}/organizations  (enterprise-owner token)
##   2. GraphQL enterprise(slug).organizations  (enterprise member token)
##   3. Fallback to /user/orgs                  (any read:org token)
###
get_enterprise_orgs() {
  print_status "Fetching organisations for enterprise '${ENTERPRISE}'..."

  # -- Attempt 1: REST enterprise endpoint ---------------------------------
  local probe
  probe=$(gh_api "/enterprises/${ENTERPRISE}/organizations?per_page=1&page=1")
  if [[ "${probe}" != "__404__" && "${probe}" != "__422__" && -n "${probe}" ]]; then
    print_status "Using REST enterprise API endpoint."
    _paginate_orgs_endpoint \
      '.organizations[].login' \
      "/enterprises/${ENTERPRISE}/organizations?per_page=100&page=PAGE"
    return 0
  fi

  # -- Attempt 2: GraphQL enterprise query ---------------------------------
  print_warning "REST enterprise endpoint unavailable — trying GraphQL enterprise query..."
  local gql_orgs
  gql_orgs=$(_graphql_enterprise_orgs 2>/dev/null || true)
  if [ -n "${gql_orgs}" ]; then
    print_status "Using GraphQL enterprise endpoint."
    echo "${gql_orgs}"
    return 0
  fi

  # -- Attempt 3: /user/orgs fallback --------------------------------------
  print_warning "GraphQL enterprise query unavailable — falling back to /user/orgs."
  print_warning "Set ORG_FILTER env var to restrict results to enterprise orgs only."
  print_status  "  Example: export ORG_FILTER='^my-enterprise-prefix'"
  _paginate_orgs_endpoint \
    '.[].login' \
    "/user/orgs?per_page=100&page=PAGE"
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
    raw_orgs=$(echo "${raw_orgs}" | grep -E "${ORG_FILTER}" || true)
  fi

  # Apply ORG_EXCLUDE regex
  if [ -n "${ORG_EXCLUDE}" ]; then
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
  validate_token

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
