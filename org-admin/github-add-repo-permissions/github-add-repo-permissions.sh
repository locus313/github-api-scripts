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
#   GITHUB_TOKEN       Required. PAT with admin:org scope
#   ORG                Required. GitHub organization name
#   REPO_NAME_FILTER   Optional. Prefix filter for repository names (default: all repos)
#   REPO_ADMIN         Optional. Space-separated team slugs to grant admin access
#   REPO_MAINTAIN      Optional. Space-separated team slugs to grant maintain access
#   REPO_PUSH          Optional. Space-separated team slugs to grant push access
#   REPO_TRIAGE        Optional. Space-separated team slugs to grant triage access
#   REPO_PULL          Optional. Space-separated team slugs to grant pull access
#   API_URL_PREFIX     Optional. GitHub API base URL (default: https://api.github.com)
#
# Note: At least one of REPO_ADMIN, REPO_MAINTAIN, REPO_PUSH, REPO_TRIAGE,
#       or REPO_PULL must be set.
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

# Permission-specific team variables (space-separated team slugs)
REPO_ADMIN=${REPO_ADMIN:-''}
REPO_MAINTAIN=${REPO_MAINTAIN:-''}
REPO_PUSH=${REPO_PUSH:-''}
REPO_TRIAGE=${REPO_TRIAGE:-''}
REPO_PULL=${REPO_PULL:-''}

require_env_var GITHUB_TOKEN "GitHub token"
require_env_var ORG "GitHub organization"
require_command jq

# Check if at least one permission level is set
if [ -z "${REPO_ADMIN}" ] && [ -z "${REPO_MAINTAIN}" ] && [ -z "${REPO_PUSH}" ] && [ -z "${REPO_TRIAGE}" ] && [ -z "${REPO_PULL}" ]; then
  print_error "At least one permission level must be set."
  print_error "Available variables: REPO_ADMIN, REPO_MAINTAIN, REPO_PUSH, REPO_TRIAGE, REPO_PULL"
  exit 1
fi

validate_github_token

print_status "Organization: ${ORG}"
if [ -n "${REPO_NAME_FILTER}" ]; then
  print_status "Repository filter: ${REPO_NAME_FILTER}*"
fi

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
      print_error "$(echo "${repos_json}" | jq -r '.message // "unknown error"')"
      exit 1
    fi

    while IFS= read -r REPO; do
      [ -z "${REPO}" ] && continue
      print_status "Processing repo ${REPO}"
      
      # Apply admin permissions
      if [ -n "${REPO_ADMIN}" ]; then
        apply_team_permissions "${REPO}" "admin" "${REPO_ADMIN}"
      fi
      
      # Apply maintain permissions
      if [ -n "${REPO_MAINTAIN}" ]; then
        apply_team_permissions "${REPO}" "maintain" "${REPO_MAINTAIN}"
      fi
      
      # Apply push (write) permissions
      if [ -n "${REPO_PUSH}" ]; then
        apply_team_permissions "${REPO}" "push" "${REPO_PUSH}"
      fi
      
      # Apply triage permissions
      if [ -n "${REPO_TRIAGE}" ]; then
        apply_team_permissions "${REPO}" "triage" "${REPO_TRIAGE}"
      fi
      
      # Apply pull (read) permissions
      if [ -n "${REPO_PULL}" ]; then
        apply_team_permissions "${REPO}" "pull" "${REPO_PULL}"
      fi
      
      # Add delay to prevent hitting GitHub rate limit
      sleep 5
    done < <(echo "${repos_json}" | jq -r --arg filter "${REPO_NAME_FILTER}" 'sort_by(.name) | .[] | select(.name | startswith($filter)) | .name')
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
