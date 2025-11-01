#!/usr/bin/env bash
set -euo pipefail

###
# GLOBAL VARIABLES
###
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
TEMPLATE_REPO=${TEMPLATE_REPO:-''}
REPO_NAME=${1:-''}
CD_USERNAME=${CD_USERNAME:-''}
CD_GITHUB_TOKEN=${CD_GITHUB_TOKEN:-''}
REPO_ADMIN=${REPO_ADMIN:-''}
REPO_WRITE=${REPO_WRITE:-''}

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
  exit 1
fi

# Check if CD_USERNAME is set
if [ -z "${CD_USERNAME}" ]; then
  echo "CD_USERNAME is empty. Please set your CD username and try again"
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
curl -s -X POST -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.baptiste-preview+json" "${API_URL_PREFIX}/repos/${ORG}/${TEMPLATE_REPO}/generate" -d '{"name":"'"${REPO_NAME}"'", "owner":"'"${ORG}"'", "private":true, "include_all_branches":true}'

# Give internal teams permissions on the new repo
for ADMIN_TEAM in ${REPO_ADMIN}; do
    curl -s -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/orgs/${ORG}/teams/${ADMIN_TEAM}/repos/${ORG}/${REPO_NAME}" -d '{"permission":"admin"}'
done

for WRITE_TEAM in ${REPO_WRITE}; do
    curl -s -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/orgs/${ORG}/teams/${WRITE_TEAM}/repos/${ORG}/${REPO_NAME}" -d '{"permission":"push"}'
done

# Give cd user write permissions on the new repo
curl -s -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/repos/${ORG}/${REPO_NAME}/collaborators/${CD_USERNAME}" -d '{"permission":"push"}'

# Accept the invite automatically 
CD_INVITES=$(curl -s -H "Authorization: token ${CD_GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/user/repository_invitations")
CD_INVITES_INVITE_ID=$(echo "${CD_INVITES}" | jq -r --arg REPO_NAME "${REPO_NAME}" 'select(.[].repository.name==$REPO_NAME) | .[].id')
curl -s -X PATCH -H "Authorization: token ${CD_GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/user/repository_invitations/${CD_INVITES_INVITE_ID}"
