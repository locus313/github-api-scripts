#!/usr/bin/env bash
set -euo pipefail

###
## GLOBAL VARIABLES
###
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
REPO_ADMIN=${REPO_ADMIN:-''}

# Check if GITHUB_TOKEN is set
if [ -z "${GITHUB_TOKEN}" ]; then
  echo "GITHUB_TOKEN is empty. Please set your token and try again"
  exit 1
fi

# Validate GITHUB_TOKEN by calling GitHub API
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token ${GITHUB_TOKEN}" "${API_URL_PREFIX}/user")

if [ "${RESPONSE}" -ne 200 ]; then
  echo "Error: GITHUB_TOKEN is invalid or does not have required permissions."
  exit 1
fi

get_repo_pagination () {
    repo_pages=$(curl -H "Authorization: token ${GITHUB_TOKEN}" -I "${API_URL_PREFIX}/orgs/${ORG}/repos?per_page=100" | grep -Eo '&page=[0-9]+' | grep -Eo '[0-9]+' | tail -1;)
    echo "${repo_pages:-1}"
}

limit_repo_pagination () {
  seq "$(get_repo_pagination)"
}

process_repos () {
  for PAGE in $(limit_repo_pagination); do
  
    for i in $(curl -H "Authorization: token ${GITHUB_TOKEN}" -s "${API_URL_PREFIX}/orgs/${ORG}/repos?page=${PAGE}&per_page=100&sort=full_name" | jq -r 'sort_by(.name) | .[] | .name'); do

      echo "processing repo ${i}"
      
      # Give internal repo admin team permissions on the repo
      curl -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/orgs/${ORG}/teams/${REPO_ADMIN}/repos/${ORG}/${i}" -d '{"permission":"admin"}';

      # Add delay to prevent hitting github rate limit
      sleep 5
      
    done
  done
}

process_repos
