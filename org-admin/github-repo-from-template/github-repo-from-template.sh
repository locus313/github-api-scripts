#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/github-common.sh
source "${SCRIPT_DIR}/../../lib/github-common.sh"

### GLOBAL VARIABLES
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
GIT_URL_PREFIX=${GIT_URL_PREFIX:-'https://github.com'}
TEMPLATE_REPO=${TEMPLATE_REPO:-''}
REPO_NAME=${1:-''}
CD_USERNAME=${CD_USERNAME:-''}
CD_GITHUB_TOKEN=${CD_GITHUB_TOKEN:-''}
REPO_ADMIN=${REPO_ADMIN:-''}
REPO_WRITE=${REPO_WRITE:-''}

usage() {
  echo "Usage: $0 <repo_name>"
  echo "Required env vars: GITHUB_TOKEN, ORG, TEMPLATE_REPO, CD_USERNAME, CD_GITHUB_TOKEN"
}

require_env_var GITHUB_TOKEN "GitHub token"
require_env_var ORG "GitHub organization"
require_env_var TEMPLATE_REPO "Template repository"

if [ -z "${REPO_NAME}" ]; then
  print_error "REPO_NAME is empty. Please provide repository name as first argument"
  usage
  exit 1
fi

require_env_var CD_USERNAME "CD username"
require_command jq
validate_github_token
require_env_var CD_GITHUB_TOKEN "CD GitHub token"
validate_token CD_GITHUB_TOKEN

# Create repo from template
CREATE_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.baptiste-preview+json" "${API_URL_PREFIX}/repos/${ORG}/${TEMPLATE_REPO}/generate" -d '{"name":"'"${REPO_NAME}"'", "owner":"'"${ORG}"'", "private":true, "include_all_branches":true}')

if [ "${CREATE_RESPONSE}" -ne 201 ]; then
  echo "Error: failed to create ${ORG}/${REPO_NAME} from template ${TEMPLATE_REPO} (HTTP ${CREATE_RESPONSE})"
  exit 1
fi

# Give internal teams permissions on the new repo
for ADMIN_TEAM in ${REPO_ADMIN}; do
  ADMIN_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/orgs/${ORG}/teams/${ADMIN_TEAM}/repos/${ORG}/${REPO_NAME}" -d '{"permission":"admin"}')

  if [ "${ADMIN_RESPONSE}" -ne 204 ]; then
    echo "Warning: failed to grant admin to ${ADMIN_TEAM} (HTTP ${ADMIN_RESPONSE})"
  fi
  
  # Add delay to prevent hitting GitHub rate limit
  sleep 5
done

for WRITE_TEAM in ${REPO_WRITE}; do
  WRITE_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/orgs/${ORG}/teams/${WRITE_TEAM}/repos/${ORG}/${REPO_NAME}" -d '{"permission":"push"}')

  if [ "${WRITE_RESPONSE}" -ne 204 ]; then
    echo "Warning: failed to grant push to ${WRITE_TEAM} (HTTP ${WRITE_RESPONSE})"
  fi
  
  # Add delay to prevent hitting GitHub rate limit
  sleep 5
done

# Give CD user write permissions on the new repo
COLLAB_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/repos/${ORG}/${REPO_NAME}/collaborators/${CD_USERNAME}" -d '{"permission":"push"}')

if [ "${COLLAB_RESPONSE}" -ne 201 ] && [ "${COLLAB_RESPONSE}" -ne 204 ]; then
  echo "Error: failed to add ${CD_USERNAME} as collaborator (HTTP ${COLLAB_RESPONSE})"
  exit 1
fi

# Accept the invite automatically (poll for up to 60s)
invite_id=''
for _ in $(seq 1 12); do
  CD_INVITES=$(curl -s -H "Authorization: token ${CD_GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/user/repository_invitations")
  invite_id=$(echo "${CD_INVITES}" | jq -r --arg REPO_NAME "${REPO_NAME}" '.[] | select(.repository.name==$REPO_NAME) | .id' | head -1)

  if [ -n "${invite_id}" ] && [ "${invite_id}" != "null" ]; then
    break
  fi

  sleep 5
done

if [ -n "${invite_id}" ] && [ "${invite_id}" != "null" ]; then
  ACCEPT_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH -H "Authorization: token ${CD_GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/user/repository_invitations/${invite_id}")
  if [ "${ACCEPT_RESPONSE}" -ne 204 ]; then
    echo "Warning: failed to accept invite ${invite_id} (HTTP ${ACCEPT_RESPONSE})"
  fi
else
  echo "Warning: no invitation found for ${CD_USERNAME} on ${ORG}/${REPO_NAME}"
fi

echo "Repository created from template: ${ORG}/${REPO_NAME}"
