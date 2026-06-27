#!/usr/bin/env bash
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
#   require_env_var <VAR> [description]       — exit if variable is unset/empty
#   require_command <cmd>                     — exit if command not found
#   configure_gh_auth [scope_hint]            — bridge GITHUB_TOKEN→GH_TOKEN or verify gh session
#   validate_github_token [bearer]            — verify GITHUB_TOKEN via /user endpoint
#   validate_token <VAR_NAME>                 — verify a secondary token variable
#   validate_slug <value> [label]             — exit if value contains unsafe chars
#   gh_api <path|url> [curl args...]          — Bearer-auth REST helper with retry;
#                                               returns "__404__"/"__422__" (exit 0) for those codes
#   gh_api_paginate <path> [filter] [version] — paginated REST, follows Link headers;
#                                               silently returns empty output on 404/422
#   get_repo_page_count <url>                 — total page count for a paginated REST endpoint
#   _paginate_orgs_endpoint <filter> <url_tpl> — page through an org list (internal)
#   _graphql_enterprise_orgs                  — GraphQL cursor-based enterprise orgs (internal)
#   get_enterprise_orgs                       — three-tier enterprise org resolver
#
# Token auto-resolution (at source time):
#   If GITHUB_TOKEN is unset and gh CLI is available, the token is automatically
#   resolved from the active gh auth session so curl-based scripts work with
#   either a GITHUB_TOKEN env var or a gh CLI session. GH_TOKEN is also kept
#   in sync with GITHUB_TOKEN so gh CLI calls use the same credential.
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
## configure_gh_auth [scope_hint]
## Bridges GITHUB_TOKEN into the gh CLI so scripts can accept either a token
## or an active gh auth session interchangeably.
##
## When GITHUB_TOKEN is set: exports it as GH_TOKEN (gh CLI reads this env var).
## When GITHUB_TOKEN is not set: verifies gh auth status and exits with an error
## if no session is active. scope_hint is appended to the error message.
##
## Usage:
##   configure_gh_auth "gh auth login"
##   configure_gh_auth 'gh auth refresh --scopes "read:enterprise,manage_billing:enterprise"'
###
configure_gh_auth() {
  local scope_hint="${1:-gh auth login}"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    export GH_TOKEN="$GITHUB_TOKEN"
  elif ! gh auth status >/dev/null 2>&1; then
    print_error "Not authenticated. Set GITHUB_TOKEN or run: ${scope_hint}"
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
    body=$(echo "${body}" | sed '$d')

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
## gh_api_paginate <path_or_url> [jq_filter] [api_version]
## Paginated GitHub REST API helper using Link-header following.
## Outputs each page's items (filtered by jq_filter) to stdout, one item per
## line. Pipe the output to: jq -s '.'       to get a JSON array of all items.
##                           jq -s '. // []' to get [] when the endpoint 404s.
## jq_filter defaults to .[] (one item per array element).
## api_version defaults to 2022-11-28.
## Returns 0 silently on 404/422 (empty output); returns 1 after 5 failed attempts.
###
gh_api_paginate() {
  local url="$1"
  local jq_filter="${2:-.[]}"
  local api_version="${3:-2022-11-28}"
  [[ "${url}" == http* ]] || url="${API_URL_PREFIX}${url}"

  local _tmp_headers _tmp_body _http_code _attempt _next_url
  _tmp_headers=$(mktemp)
  _tmp_body=$(mktemp)

  while [[ -n "${url}" ]]; do
    _http_code=""
    for _attempt in 1 2 3 4 5; do
      _http_code=$(curl -s \
        -D "${_tmp_headers}" \
        -o "${_tmp_body}" \
        -w "%{http_code}" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: ${api_version}" \
        "${url}")
      case "${_http_code}" in
        200) break ;;
        404|422)
          rm -f "${_tmp_headers}" "${_tmp_body}"
          return 0
          ;;
        403|429)
          print_warning "Rate limited (HTTP ${_http_code}). Sleeping 60s before retry ${_attempt}/5..."
          sleep 60
          ;;
        *)
          print_warning "HTTP ${_http_code} for ${url} (attempt ${_attempt}/5)"
          sleep 5
          ;;
      esac
    done

    if [[ "${_http_code}" != "200" ]]; then
      rm -f "${_tmp_headers}" "${_tmp_body}"
      print_error "Failed to fetch ${url} after 5 attempts"
      return 1
    fi

    jq -rc "${jq_filter}" "${_tmp_body}" 2>/dev/null || true

    # Follow Link: <next-url>; rel="next" to the next page
    _next_url=$(grep -i "^link:" "${_tmp_headers}" \
      | grep -o '<[^>]*>; rel="next"' \
      | sed 's/<\([^>]*\)>.*/\1/' \
      || true)
    url="${_next_url}"
  done

  rm -f "${_tmp_headers}" "${_tmp_body}"
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
    body=$(echo "${resp}" | sed '$d')

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

###
## Token auto-resolution (runs once at source time)
## If GITHUB_TOKEN is not set, attempt to derive it from an active gh CLI
## auth session. This allows scripts that use GITHUB_TOKEN with curl to work
## with gh CLI auth as an alternative to an explicit token.
## Scripts should still call require_env_var GITHUB_TOKEN or
## validate_github_token to fail fast with a clear message if neither source
## provides a token.
###
if [[ -z "${GITHUB_TOKEN:-}" ]] && command -v gh &>/dev/null; then
  _gh_resolved_token=$(gh auth token 2>/dev/null) || true
  if [[ -n "${_gh_resolved_token:-}" ]]; then
    GITHUB_TOKEN="$_gh_resolved_token"
    export GITHUB_TOKEN
  fi
  unset _gh_resolved_token
fi
# Keep GH_TOKEN in sync with GITHUB_TOKEN so that any script can call
# 'gh api' directly (e.g. for endpoints that require scopes beyond what
# a raw token carries, or simply to reuse the gh CLI auth session).
# Only set when gh CLI is present and GH_TOKEN is not already provided.
if [[ -n "${GITHUB_TOKEN:-}" ]] && command -v gh &>/dev/null && [[ -z "${GH_TOKEN:-}" ]]; then
  GH_TOKEN="$GITHUB_TOKEN"
  export GH_TOKEN
fi
