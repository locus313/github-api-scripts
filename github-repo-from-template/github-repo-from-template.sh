#!/bin/bash
set -euo pipefail

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

# Check if TEMPLATE_REPO is set
if [ -z "${TEMPLATE_REPO}" ]; then
  echo "TEMPLATE_REPO is empty. Please set your template repository and try again"
  exit 1
fi

# Check if REPO_NAME is set
if [ -z "${REPO_NAME}" ]; then
  echo "REPO_NAME is empty. Please provide repository name as first argument"
  usage
  exit 1
fi

# Check if CD_USERNAME is set
if [ -z "${CD_USERNAME}" ]; then
  echo "CD_USERNAME is empty. Please set your CD username and try again"
  exit 1
fi

if ! command -v jq > /dev/null 2>&1; then
  echo "jq is not installed. Please install jq and try again"
  exit 1
fi

# Validate GITHUB_TOKEN by calling GitHub API
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token ${GITHUB_TOKEN}" "${API_URL_PREFIX}/user")

if [ "${RESPONSE}" -ne 200 ]; then
  echo "Error: GITHUB_TOKEN is invalid or does not have required permissions."
  exit 1
fi

# Check if CD_GITHUB_TOKEN is set
if [ -z "${CD_GITHUB_TOKEN}" ]; then
  echo "CD_GITHUB_TOKEN is empty. Please set your token and try again"
  exit 1
fi

# Validate CD_GITHUB_TOKEN by calling GitHub API
CD_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token ${CD_GITHUB_TOKEN}" "${API_URL_PREFIX}/user")

if [ "${CD_RESPONSE}" -ne 200 ]; then
  echo "Error: CD_GITHUB_TOKEN is invalid or does not have required permissions."
  exit 1
fi

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
