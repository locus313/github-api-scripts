#!/bin/bash
# =============================================================================
# github-common.sh
#
# Shared utility functions for GitHub API scripts. Source this library from
# any script; do not execute it directly.
#
# Usage (from a script two directory levels deep):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=../../lib/github-common.sh
#   source "${SCRIPT_DIR}/../../lib/github-common.sh"
#
# Provides:
#   print_status / print_success / print_warning / print_error
#   require_env_var <VAR> [description]  — exit if variable is unset/empty
#   require_command <cmd>                — exit if command not found
#   validate_github_token [bearer]       — verify token via /user endpoint
#   validate_token <VAR_NAME>            — verify a secondary token variable
#   validate_slug <value> [label]        — exit if value contains unsafe chars
#   gh_api <path|url> [curl args...]     — Bearer-auth REST helper with retry
#   _paginate_orgs_endpoint <filter> <url_tpl>  — page through an org list
#   _graphql_enterprise_orgs             — GraphQL cursor-based enterprise orgs
#   get_enterprise_orgs                  — three-tier enterprise org resolver
# =============================================================================

###
## COLOR CODES
###
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

###
## PRINT FUNCTIONS
###
print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }

###
## require_env_var <VAR_NAME> [description]
## Exits with status 1 if the named variable is empty or unset.
###
require_env_var() {
  local var_name="$1"
  local description="${2:-${var_name}}"
  local var_value
  var_value="${!var_name}"
  if [ -z "${var_value}" ]; then
    print_error "${description} is empty. Please set ${var_name} and try again"
    exit 1
  fi
}

###
## require_command <cmd> [install_hint]
## Exits with status 1 if the command is not found in PATH.
###
require_command() {
  local cmd="$1"
  local hint="${2:-${cmd}}"
  if ! command -v "${cmd}" > /dev/null 2>&1; then
    print_error "${cmd} is not installed. Please install ${hint} and try again"
    exit 1
  fi
}

###
## validate_token <TOKEN_VAR_NAME> [bearer]
## Validates the token stored in the named variable by calling the /user endpoint.
## Pass "bearer" as second argument to use Bearer auth scheme (default: token).
## Requires API_URL_PREFIX to be set.
###
validate_token() {
  local token_var="$1"
  local auth_scheme="token"
  [ "${2:-}" = "bearer" ] && auth_scheme="Bearer"
  local token_value
  token_value="${!token_var}"
  local response
  response=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: ${auth_scheme} ${token_value}" \
    "${API_URL_PREFIX}/user")
  if [ "${response}" -ne 200 ]; then
    print_error "${token_var} is invalid or does not have required permissions (HTTP ${response})"
    exit 1
  fi
}

###
## validate_github_token [bearer]
## Convenience wrapper: validates GITHUB_TOKEN via the /user endpoint.
## Also warns if API_URL_PREFIX does not look like a GitHub endpoint.
###
validate_github_token() {
  case "${API_URL_PREFIX}" in
    https://api.github.com*|https://*.github.com*) ;;
    *)
      print_warning "API_URL_PREFIX '${API_URL_PREFIX}' does not look like a GitHub API endpoint."
      ;;
  esac
  validate_token GITHUB_TOKEN "${1:-}"
}

###
## get_repo_page_count <url>
## Returns the total number of pages for a paginated GitHub API list endpoint.
## Example: get_repo_page_count "${API_URL_PREFIX}/orgs/${ORG}/repos?per_page=100"
###
get_repo_page_count() {
  local url="$1"
  local pages
  pages=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" -I "${url}" \
    | grep -Eo '&page=[0-9]+' | grep -Eo '[0-9]+' | tail -1)
  echo "${pages:-1}"
}

###
## validate_slug <value> <label>
## Exits with status 1 if the value contains characters other than
## alphanumeric, hyphen, or underscore (guards URL path injection).
###
validate_slug() {
  local val="$1"
  local label="${2:-value}"
  if [[ ! "${val}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    print_error "Invalid ${label} '${val}': only alphanumeric, hyphen, and underscore are allowed"
    exit 1
  fi
}

###
## gh_api <path_or_full_url> [extra curl args...]
## GitHub REST/GraphQL API helper with Bearer auth and rate-limit retries.
## Prepends API_URL_PREFIX when the first argument starts with /.
## Returns __404__ / __422__ for those status codes rather than failing.
## Any extra arguments after the URL are passed directly to curl (e.g. -X POST -d ...).
###
gh_api() {
  local url="$1"
  shift
  [[ "${url}" == http* ]] || url="${API_URL_PREFIX}${url}"

  local attempt
  for attempt in 1 2 3 4 5; do
    local http_code body
    body=$(curl -s -w "\n%{http_code}" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$@" "${url}")
    http_code=$(echo "${body}" | tail -1)
    body=$(echo "${body}" | head -n -1)

    case "${http_code}" in
      200) echo "${body}"; return 0 ;;
      404) echo "__404__"; return 0 ;;
      422) echo "__422__"; return 0 ;;
      403|429)
        print_warning "Rate limited (HTTP ${http_code}). Sleeping 60s before retry ${attempt}/5..."
        sleep 60
        ;;
      *)
        print_warning "HTTP ${http_code} for ${url} (attempt ${attempt}/5)"
        sleep 5
        ;;
    esac
  done

  print_error "Failed to reach ${url} after 5 attempts"
  return 1
}

###
## _paginate_orgs_endpoint <jq_filter> <url_template>
## Internal helper: pages through an org-list REST endpoint, printing one
## login per line. Replace the literal string PAGE in url_template with the
## current page number on each iteration.
## Example:
##   _paginate_orgs_endpoint '.[].login' "/user/orgs?per_page=100&page=PAGE"
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
## Queries GraphQL for all organizations in ENTERPRISE using cursor-based
## pagination. Works for enterprise members (not just owners).
## Prints one org login per line. Returns 1 on any HTTP or GraphQL error.
## Requires: ENTERPRISE, GITHUB_TOKEN, API_URL_PREFIX
###
_graphql_enterprise_orgs() {
  local cursor="null"
  while true; do
    local query resp http_code body gql_errors has_next end_cursor

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

    gql_errors=$(echo "${body}" | jq -r '.errors // empty' 2>/dev/null || true)
    if [ -n "${gql_errors}" ]; then
      return 1
    fi

    echo "${body}" | jq -r '.data.enterprise.organizations.nodes[].login' 2>/dev/null || true

    has_next=$(echo "${body}" | jq -r '.data.enterprise.organizations.pageInfo.hasNextPage')
    end_cursor=$(echo "${body}" | jq -r '.data.enterprise.organizations.pageInfo.endCursor')

    if [[ "${has_next}" != "true" ]]; then
      break
    fi
    cursor="\"${end_cursor}\""
  done
}

###
## get_enterprise_orgs
## Prints one org login per line using a three-tier strategy:
##   1. REST /enterprises/{slug}/organizations  (enterprise-owner token)
##   2. GraphQL enterprise(slug).organizations  (enterprise member token)
##   3. /user/orgs fallback                     (any read:org token)
## Requires: ENTERPRISE, GITHUB_TOKEN, API_URL_PREFIX
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
