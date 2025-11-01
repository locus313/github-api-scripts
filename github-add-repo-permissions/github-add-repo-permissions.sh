#!/usr/bin/env /bin/bash
set -euo pipefail

### GLOBAL VARIABLES
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
GIT_URL_PREFIX=${GIT_URL_PREFIX:-'https://github.com'}

# Permission-specific team variables (space-separated team slugs)
REPO_ADMIN=${REPO_ADMIN:-''}
REPO_MAINTAIN=${REPO_MAINTAIN:-''}
REPO_PUSH=${REPO_PUSH:-''}
REPO_TRIAGE=${REPO_TRIAGE:-''}
REPO_PULL=${REPO_PULL:-''}

# Check if GITHUB_TOKEN is set
if [ -z "${GITHUB_TOKEN}" ]; then
  echo "GITHUB_TOKEN is empty. Please set your token and try again"
  exit 1
fi

# Check if ORG is set
if [ -z "${ORG}" ]; then
  echo "ORG is empty. Please set your organization and try again"
  exit 1
fi

# Check if at least one permission level is set
if [ -z "${REPO_ADMIN}" ] && [ -z "${REPO_MAINTAIN}" ] && [ -z "${REPO_PUSH}" ] && [ -z "${REPO_TRIAGE}" ] && [ -z "${REPO_PULL}" ]; then
  echo "Error: At least one permission level must be set."
  echo "Available variables: REPO_ADMIN, REPO_MAINTAIN, REPO_PUSH, REPO_TRIAGE, REPO_PULL"
  exit 1
fi

# Validate GITHUB_TOKEN by calling GitHub API
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token ${GITHUB_TOKEN}" "${API_URL_PREFIX}/user")

if [ "${RESPONSE}" -ne 200 ]; then
  echo "Error: GITHUB_TOKEN is invalid or does not have required permissions."
  exit 1
fi

get_repo_pagination () {
    repo_pages=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" -I "${API_URL_PREFIX}/orgs/${ORG}/repos?per_page=100" | grep -Eo '&page=[0-9]+' | grep -Eo '[0-9]+' | tail -1;)
    echo "${repo_pages:-1}"
}

limit_repo_pagination () {
  seq "$(get_repo_pagination)"
}

apply_team_permissions () {
  local REPO_NAME=$1
  local PERMISSION=$2
  local TEAM_SLUGS=$3
  
  # Loop through space-separated team slugs
  for TEAM in ${TEAM_SLUGS}; do
    echo "  Granting ${PERMISSION} permission to team ${TEAM}"
    curl -s -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/orgs/${ORG}/teams/${TEAM}/repos/${ORG}/${REPO_NAME}" -d "{\"permission\":\"${PERMISSION}\"}"
  done
}

process_repos () {
  for PAGE in $(limit_repo_pagination); do
    for REPO in $(curl -s -H "Authorization: token ${GITHUB_TOKEN}" "${API_URL_PREFIX}/orgs/${ORG}/repos?page=${PAGE}&per_page=100&sort=full_name" | jq -r 'sort_by(.name) | .[] | .name'); do
      echo "Processing repo ${REPO}"
      
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
    done
  done
}

process_repos
