#!/usr/bin/env bash
# =============================================================================
# github-add-repo-permissions.sh
#
# Grants team-level permissions across repositories in a GitHub organisation.
# By default all repositories are processed; set REPO_NAME_FILTER to restrict
# to repos whose names start with a given prefix. Supports all five permission
# levels: admin, maintain, push,
# triage, and pull. At least one permission level must be specified.
#
# Usage:
#   export GITHUB_TOKEN=ghp_yourtoken
#   export ORG=my-org
#   export REPO_PUSH="platform-team ci-team"
#   ./github-add-repo-permissions.sh
#
# Environment variables:
#   GITHUB_TOKEN          Required. PAT with admin:org scope
#   ORG                   Required. GitHub organization name
#   REPO_NAME_FILTER      Optional. Prefix filter for repository names (default: all repos)
#   SKIP_ARCHIVED         Optional. Set to "true" to skip maintain/push/triage/pull permissions on
#                         archived repositories; admin permissions are still applied (default: false)
#   REPO_ADMIN            Optional. Space-separated team slugs to grant admin access
#   REPO_MAINTAIN         Optional. Space-separated team slugs to grant maintain access
#   REPO_PUSH             Optional. Space-separated team slugs to grant push access
#   REPO_TRIAGE           Optional. Space-separated team slugs to grant triage access
#   REPO_PULL             Optional. Space-separated team slugs to grant pull access
#   REPO_ADMIN_EXCLUDE    Optional. Space-separated repo names to skip for admin access
#   REPO_MAINTAIN_EXCLUDE Optional. Space-separated repo names to skip for maintain access
#   REPO_PUSH_EXCLUDE     Optional. Space-separated repo names to skip for push access
#   REPO_TRIAGE_EXCLUDE   Optional. Space-separated repo names to skip for triage access
#   REPO_PULL_EXCLUDE     Optional. Space-separated repo names to skip for pull access
#   API_URL_PREFIX        Optional. GitHub API base URL (default: https://api.github.com)
#
# Note: At least one of REPO_ADMIN, REPO_MAINTAIN, REPO_PUSH, REPO_TRIAGE,
#       or REPO_PULL must be set. Each REPO_*_EXCLUDE list names repositories
#       that are skipped for that permission level only.
#
# Requirements:
#   - curl
#   - jq
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/github-common.sh
source "${SCRIPT_DIR}/../../lib/github-common.sh"

### GLOBAL VARIABLES
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
REPO_NAME_FILTER=${REPO_NAME_FILTER:-''}
SKIP_ARCHIVED=${SKIP_ARCHIVED:-'false'}

# Permission-specific team variables (space-separated team slugs)
REPO_ADMIN=${REPO_ADMIN:-''}
REPO_MAINTAIN=${REPO_MAINTAIN:-''}
REPO_PUSH=${REPO_PUSH:-''}
REPO_TRIAGE=${REPO_TRIAGE:-''}
REPO_PULL=${REPO_PULL:-''}

# Permission-specific exclusion lists (space-separated repo names to skip)
REPO_ADMIN_EXCLUDE=${REPO_ADMIN_EXCLUDE:-''}
REPO_MAINTAIN_EXCLUDE=${REPO_MAINTAIN_EXCLUDE:-''}
REPO_PUSH_EXCLUDE=${REPO_PUSH_EXCLUDE:-''}
REPO_TRIAGE_EXCLUDE=${REPO_TRIAGE_EXCLUDE:-''}
REPO_PULL_EXCLUDE=${REPO_PULL_EXCLUDE:-''}

require_env_var GITHUB_TOKEN "GitHub token"
require_env_var ORG "GitHub organization"
require_command jq

# Check if at least one permission level is set
if [ -z "${REPO_ADMIN}" ] && [ -z "${REPO_MAINTAIN}" ] && [ -z "${REPO_PUSH}" ] && [ -z "${REPO_TRIAGE}" ] && [ -z "${REPO_PULL}" ]; then
  err "At least one permission level must be set. Available: REPO_ADMIN, REPO_MAINTAIN, REPO_PUSH, REPO_TRIAGE, REPO_PULL"
fi

validate_github_token

print_status "Organization: ${ORG}"
if [ -n "${REPO_NAME_FILTER}" ]; then
  print_status "Repository filter: ${REPO_NAME_FILTER}*"
fi
if [ "${SKIP_ARCHIVED}" = "true" ]; then
  print_status "Skipping non-admin permissions on archived repositories"
fi

is_excluded () {
  local REPO_NAME=$1
  local EXCLUDE_LIST=$2
  local EXCLUDED

  for EXCLUDED in ${EXCLUDE_LIST}; do
    if [ "${EXCLUDED}" = "${REPO_NAME}" ]; then
      return 0
    fi
  done
  return 1
}

apply_level () {
  local REPO_NAME=$1
  local PERMISSION=$2
  local TEAM_SLUGS=$3
  local EXCLUDE_LIST=$4

  [ -z "${TEAM_SLUGS}" ] && return 0

  if is_excluded "${REPO_NAME}" "${EXCLUDE_LIST}"; then
    print_status "  Skipping ${PERMISSION} on ${REPO_NAME} (excluded)"
    return 0
  fi

  apply_team_permissions "${REPO_NAME}" "${PERMISSION}" "${TEAM_SLUGS}"
}

apply_team_permissions () {
  local REPO_NAME=$1
  local PERMISSION=$2
  local TEAM_SLUGS=$3
  local TEAM
  local response
  
  # Loop through space-separated team slugs
  for TEAM in ${TEAM_SLUGS}; do
    validate_slug "${TEAM}" "team slug"
    print_status "  Granting ${PERMISSION} permission to team ${TEAM}"
    response=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/orgs/${ORG}/teams/${TEAM}/repos/${ORG}/${REPO_NAME}" -d "{\"permission\":\"${PERMISSION}\"}")

    if [ "${response}" -eq 204 ]; then
      print_success "  Applied ${PERMISSION} to ${TEAM} on ${REPO_NAME}"
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
      print_warning "  Failed ${PERMISSION} to ${TEAM} on ${REPO_NAME} (HTTP ${response})"
      FAILURE_COUNT=$((FAILURE_COUNT + 1))
    fi
  done
}

process_repos () {
  local PAGE
  local REPO
  local repos_json

  for PAGE in $(seq "$(get_repo_page_count "${API_URL_PREFIX}/orgs/${ORG}/repos?per_page=100")"); do
    repos_json=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" "${API_URL_PREFIX}/orgs/${ORG}/repos?page=${PAGE}&per_page=100&sort=full_name")

    if ! echo "${repos_json}" | jq -e 'type == "array"' > /dev/null 2>&1; then
      print_error "Unexpected API response for page ${PAGE}"
      err "$(echo "${repos_json}" | jq -r '.message // "unknown error"')"
    fi

    while IFS=$'\t' read -r REPO ARCHIVED; do
      [ -z "${REPO}" ] && continue
      print_status "Processing repo ${REPO}"

      # Admin access is always granted, even on archived repos (e.g. so
      # platform teams retain settings access after archival).
      apply_level "${REPO}" "admin" "${REPO_ADMIN}" "${REPO_ADMIN_EXCLUDE}"

      if [ "${SKIP_ARCHIVED}" = "true" ] && [ "${ARCHIVED}" = "true" ]; then
        print_status "  Skipping non-admin permissions on ${REPO} (archived)"
      else
        apply_level "${REPO}" "maintain" "${REPO_MAINTAIN}" "${REPO_MAINTAIN_EXCLUDE}"
        apply_level "${REPO}" "push" "${REPO_PUSH}" "${REPO_PUSH_EXCLUDE}"
        apply_level "${REPO}" "triage" "${REPO_TRIAGE}" "${REPO_TRIAGE_EXCLUDE}"
        apply_level "${REPO}" "pull" "${REPO_PULL}" "${REPO_PULL_EXCLUDE}"
      fi

      # Add delay to prevent hitting GitHub rate limit
      sleep 5
    done < <(echo "${repos_json}" | jq -r --arg filter "${REPO_NAME_FILTER}" 'sort_by(.name) | .[] | select(.name | startswith($filter)) | [.name, (.archived // false | tostring)] | @tsv')
  done
}

SUCCESS_COUNT=0
FAILURE_COUNT=0

process_repos

print_success "Completed permission updates"
print_status "Successful changes: ${SUCCESS_COUNT}"
if [ "${FAILURE_COUNT}" -gt 0 ]; then
  print_warning "Failed changes: ${FAILURE_COUNT}"
else
  print_status "Failed changes: 0"
fi
