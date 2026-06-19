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
###
validate_github_token() {
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
