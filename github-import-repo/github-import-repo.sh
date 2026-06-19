#!/bin/bash
set -euo pipefail

### GLOBAL VARIABLES
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
GIT_URL_PREFIX=${GIT_URL_PREFIX:-'https://github.com'}
SRC_REPO=${1:-''}
DEST_REPO=${2:-''}
OWNER_USERNAME=${OWNER_USERNAME:-''}
WORKDIR=''

usage() {
  echo "Usage: $0 <source_repo_name> <destination_repo_name>"
  echo "Required env vars: GITHUB_TOKEN, ORG, OWNER_USERNAME"
}

cleanup() {
  if [ -n "${WORKDIR}" ] && [ -d "${WORKDIR}" ]; then
    rm -rf "${WORKDIR}"
  fi
}

trap cleanup EXIT

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

# Check if SRC_REPO is set
if [ -z "${SRC_REPO}" ]; then
  echo "SRC_REPO is empty. Please provide source repository as first argument"
  usage
  exit 1
fi

# Check if DEST_REPO is set
if [ -z "${DEST_REPO}" ]; then
  echo "DEST_REPO is empty. Please provide destination repository as second argument"
  usage
  exit 1
fi

# Check if OWNER_USERNAME is set
if [ -z "${OWNER_USERNAME}" ]; then
  echo "OWNER_USERNAME is empty. Please set your owner username and try again"
  exit 1
fi

if ! command -v git > /dev/null 2>&1; then
  echo "git is not installed. Please install git and try again"
  exit 1
fi

# Validate GITHUB_TOKEN by calling GitHub API
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token ${GITHUB_TOKEN}" "${API_URL_PREFIX}/user")

if [ "${RESPONSE}" -ne 200 ]; then
  echo "Error: GITHUB_TOKEN is invalid or does not have required permissions."
  exit 1
fi

# Create repo
CREATE_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.nebula-preview+json" "${API_URL_PREFIX}/orgs/${ORG}/repos" -d '{"name":"'"${DEST_REPO}"'", "visibility":"internal"}')

if [ "${CREATE_RESPONSE}" -ne 201 ] && [ "${CREATE_RESPONSE}" -ne 422 ]; then
  echo "Error: failed to create repository ${ORG}/${DEST_REPO} (HTTP ${CREATE_RESPONSE})"
  exit 1
fi

# Grant admin permissions on new repo
OWNER_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/repos/${ORG}/${DEST_REPO}/collaborators/${OWNER_USERNAME}" -d '{"permission":"admin"}')

if [ "${OWNER_RESPONSE}" -ne 201 ] && [ "${OWNER_RESPONSE}" -ne 204 ]; then
  echo "Error: failed to grant admin to ${OWNER_USERNAME} on ${DEST_REPO} (HTTP ${OWNER_RESPONSE})"
  exit 1
fi

WORKDIR=$(mktemp -d)
cd "${WORKDIR}"

# Clone old repo locally
git clone --bare "${GIT_URL_PREFIX}/${ORG}/${SRC_REPO}.git"

# Push to new repo
cd "${SRC_REPO}.git"
git push --mirror "${GIT_URL_PREFIX}/${ORG}/${DEST_REPO}.git"

echo "Repository import complete: ${SRC_REPO} -> ${DEST_REPO}"
