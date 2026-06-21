#!/bin/bash
# =============================================================================
# github-add-repo-collaborators-by-pattern.sh
#
# Adds one or more individual collaborators to all repositories in an
# organisation whose names match a given regex pattern.
#
# Usage:
#   export GITHUB_TOKEN=ghp_yourtoken
#   export ORG=my-org
#   export COLLABORATORS=alice,bob
#   export REPO_NAME_REGEX='^service-'
#   ./github-add-repo-collaborators-by-pattern.sh
#
# Environment variables:
#   GITHUB_TOKEN        Required. PAT with repo and admin:org scope
#   ORG                 Required. GitHub organization name
#   COLLABORATORS       Required. Comma-separated GitHub usernames
#   REPO_NAME_REGEX     Required. ERE regex to match repository names
#   PERMISSION          Optional. Permission level: pull|triage|push|maintain|admin (default: push)
#   REPO_EXCLUDE_REGEX  Optional. ERE regex to exclude matching repository names
#   API_URL_PREFIX      Optional. GitHub API base URL (default: https://api.github.com)
#
# Requirements:
#   - curl
#   - jq
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/github-common.sh
source "${SCRIPT_DIR}/../../lib/github-common.sh"

###
## GLOBAL VARIABLES
###
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
COLLABORATORS=${COLLABORATORS:-''}   # Comma-separated usernames, e.g. alice,bob
PERMISSION=${PERMISSION:-'push'}      # pull|triage|push|maintain|admin
REPO_NAME_REGEX=${REPO_NAME_REGEX:-''}
REPO_EXCLUDE_REGEX=${REPO_EXCLUDE_REGEX:-''}

###
## FUNCTIONS
###
usage() {
  echo "Usage: ORG=<org> GITHUB_TOKEN=<token> COLLABORATORS=<u1,u2> REPO_NAME_REGEX=<regex> $0"
  echo "Optional: PERMISSION=push REPO_EXCLUDE_REGEX=<regex> API_URL_PREFIX=<url>"
}

get_repo_pagination() {
  local repo_pages
  repo_pages=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" -I "${API_URL_PREFIX}/orgs/${ORG}/repos?per_page=100" | grep -Eo '&page=[0-9]+' | grep -Eo '[0-9]+' | tail -1)
  echo "${repo_pages:-1}"
}

limit_repo_pagination() {
  seq "$(get_repo_pagination)"
}

validate() {
  require_env_var GITHUB_TOKEN "GitHub token"
  require_env_var ORG "GitHub organization"
  require_env_var COLLABORATORS "Collaborators list"
  require_env_var REPO_NAME_REGEX "Repo name regex"
  case "${PERMISSION}" in
    pull|triage|push|maintain|admin) ;;
    *)
      print_error "Invalid PERMISSION '${PERMISSION}'. Must be one of: pull, triage, push, maintain, admin"
      exit 1
      ;;
  esac
  require_command jq
  validate_github_token
}

get_matching_repos() {
  local page repos_json
  for page in $(limit_repo_pagination); do
    repos_json=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/json" "${API_URL_PREFIX}/orgs/${ORG}/repos?type=all&per_page=100&page=${page}&sort=full_name")

    if [ -n "${REPO_EXCLUDE_REGEX}" ]; then
      while IFS= read -r repo_name; do
        [ -n "${repo_name}" ] && echo "${repo_name}"
      done < <(echo "${repos_json}" | jq -r --arg include "${REPO_NAME_REGEX}" --arg exclude "${REPO_EXCLUDE_REGEX}" '.[] | select(has("name") and (.name | test($include)) and (.name | test($exclude) | not)) | .name')
    else
      while IFS= read -r repo_name; do
        [ -n "${repo_name}" ] && echo "${repo_name}"
      done < <(echo "${repos_json}" | jq -r --arg include "${REPO_NAME_REGEX}" '.[] | select(has("name") and (.name | test($include))) | .name')
    fi
  done
}

add_collaborators_to_repos() {
  local repo collaborator response
  local collaborators_space
  collaborators_space=$(echo "${COLLABORATORS}" | tr ',' ' ')

  while IFS= read -r repo; do
    [ -z "${repo}" ] && continue
    for collaborator in ${collaborators_space}; do
      _payload=$(jq -n --arg perm "${PERMISSION}" '{"permission":$perm}')
      response=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/repos/${ORG}/${repo}/collaborators/${collaborator}" -d "${_payload}")
      if [[ "${response}" =~ ^2 ]]; then
        echo "Added '${collaborator}' to '${repo}' with '${PERMISSION}' permission"
      else
        echo "Failed to add '${collaborator}' to '${repo}' (HTTP ${response})"
      fi
    done
  done < <(get_matching_repos)
}

###
## MAIN PROGRAM
###
validate
echo "Matching repositories:"
get_matching_repos

echo "Applying collaborator permissions..."
add_collaborators_to_repos

echo "Done"
