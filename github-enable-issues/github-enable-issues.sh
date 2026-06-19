#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/github-common.sh
source "${SCRIPT_DIR}/../lib/github-common.sh"

###
## GitHub Enable Issues
## Enables the Issues feature on every repository in a GitHub organization
## that currently has it disabled.
##
## Skips archived repositories (issues cannot be enabled on them).
##
## Usage:
##   export GITHUB_TOKEN=ghp_yourtoken
##   export ORG=my-org
##   ./github-enable-issues.sh [--dry-run]
##
## Options:
##   --dry-run    List repos that would be updated without making any changes
##
## Environment variables:
##   GITHUB_TOKEN    Required. PAT with repo or admin:org scope
##   ORG             Required. GitHub organization name
##   API_URL_PREFIX  Optional. GitHub API base URL (default: https://api.github.com)
###

###
## GLOBAL VARIABLES
###
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
DRY_RUN=false

###
## ARGUMENT PARSING
###
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--dry-run]"
      echo ""
      echo "Environment variables:"
      echo "  GITHUB_TOKEN   Required. PAT with repo scope"
      echo "  ORG            Required. GitHub organization name"
      echo "  API_URL_PREFIX Optional. API base URL (default: https://api.github.com)"
      exit 0
      ;;
    *)
      print_error "Unknown argument: $1"
      echo "Usage: $0 [--dry-run]"
      exit 1
      ;;
  esac
done

###
## VALIDATION
###
require_env_var GITHUB_TOKEN "GitHub token"
require_env_var ORG "GitHub organization"
validate_github_token
print_success "GitHub token validated"
print_status "Organization : ${ORG}"
if [ "${DRY_RUN}" = true ]; then
  print_warning "DRY RUN mode — no changes will be made"
fi

###
## PAGINATION HELPER
## Returns the total number of pages for the org's full repo list.
###
get_repo_pagination() {
  local pages
  pages=$(curl -s -I \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "${API_URL_PREFIX}/orgs/${ORG}/repos?per_page=100" \
    | grep -i '^link:' \
    | grep -Eo 'page=[0-9]+' \
    | grep -Eo '[0-9]+' \
    | tail -1)
  echo "${pages:-1}"
}

###
## MAIN LOGIC
###
TOTAL_PAGES=$(get_repo_pagination)
print_status "Total pages of repos: ${TOTAL_PAGES}"

COUNT_UPDATED=0
COUNT_SKIPPED=0
COUNT_ARCHIVED=0
COUNT_ERRORS=0

for PAGE in $(seq 1 "${TOTAL_PAGES}"); do
  print_status "Processing page ${PAGE} of ${TOTAL_PAGES}..."

  REPOS=$(curl -s \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "${API_URL_PREFIX}/orgs/${ORG}/repos?per_page=100&page=${PAGE}&sort=full_name" \
    | jq -c '.[] | {name: .name, has_issues: .has_issues, archived: .archived}')

  while IFS= read -r REPO_JSON; do
    REPO_NAME=$(echo "${REPO_JSON}" | jq -r '.name')
    HAS_ISSUES=$(echo "${REPO_JSON}" | jq -r '.has_issues')
    IS_ARCHIVED=$(echo "${REPO_JSON}" | jq -r '.archived')

    # Skip archived repos — GitHub does not allow enabling issues on them
    if [ "${IS_ARCHIVED}" = "true" ]; then
      print_warning "  SKIP (archived)  ${REPO_NAME}"
      COUNT_ARCHIVED=$((COUNT_ARCHIVED + 1))
      continue
    fi

    # Skip repos that already have issues enabled
    if [ "${HAS_ISSUES}" = "true" ]; then
      print_status "  SKIP (already enabled)  ${REPO_NAME}"
      COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
      continue
    fi

    if [ "${DRY_RUN}" = true ]; then
      print_warning "  DRY RUN — would enable issues on: ${REPO_NAME}"
      COUNT_UPDATED=$((COUNT_UPDATED + 1))
      continue
    fi

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      -X PATCH \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github.v3+json" \
      -H "Content-Type: application/json" \
      "${API_URL_PREFIX}/repos/${ORG}/${REPO_NAME}" \
      -d '{"has_issues": true}')

    if [ "${HTTP_CODE}" -eq 200 ]; then
      print_success "  ENABLED issues on: ${REPO_NAME}"
      COUNT_UPDATED=$((COUNT_UPDATED + 1))
    else
      print_error "  FAILED to enable issues on: ${REPO_NAME} (HTTP ${HTTP_CODE})"
      COUNT_ERRORS=$((COUNT_ERRORS + 1))
    fi

    # Brief pause to avoid hitting secondary rate limits
    sleep 0.5

  done <<< "${REPOS}"
done

###
## SUMMARY
###
echo ""
echo "========================================"
print_success "Done!"
if [ "${DRY_RUN}" = true ]; then
  print_warning "Summary (DRY RUN — no changes made):"
  echo "  Would enable : ${COUNT_UPDATED}"
else
  print_status "Summary:"
  echo "  Enabled      : ${COUNT_UPDATED}"
  echo "  Errors       : ${COUNT_ERRORS}"
fi
echo "  Already on   : ${COUNT_SKIPPED}"
echo "  Archived     : ${COUNT_ARCHIVED}"
echo "========================================"
