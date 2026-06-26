#!/usr/bin/env bash
# =============================================================================
# github-import-repo.sh
#
# Imports an existing repository into a GitHub organisation as a new internal
# repository by performing a bare clone and mirror push. Grants admin access
# to a specified owner account.
#
# Usage:
#   export GITHUB_TOKEN=ghp_yourtoken
#   export ORG=my-org
#   export OWNER_USERNAME=admin-user
#   ./github-import-repo.sh <source_repo> <destination_repo>
#
# Arguments:
#   source_repo       Name of the existing repository to clone
#   destination_repo  Name of the new repository to create
#
# Environment variables:
#   GITHUB_TOKEN    Required. PAT with repo scope
#   ORG             Required. GitHub organization name
#   OWNER_USERNAME  Required. GitHub username to grant admin on the new repo
#   API_URL_PREFIX  Optional. GitHub API base URL (default: https://api.github.com)
#   GIT_URL_PREFIX  Optional. GitHub base URL for git operations (default: https://github.com)
#
# Requirements:
#   - curl
#   - git
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/github-common.sh
source "${SCRIPT_DIR}/../../lib/github-common.sh"

### GLOBAL VARIABLES
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
GIT_URL_PREFIX=${GIT_URL_PREFIX:-'https://github.com'}
SRC_REPO=${1:-''}
DEST_REPO=${2:-''}
OWNER_USERNAME=${OWNER_USERNAME:-''}
WORKDIR=''
_cred_script=''

usage() {
  echo "Usage: $0 <source_repo_name> <destination_repo_name>"
  echo "Required env vars: GITHUB_TOKEN, ORG, OWNER_USERNAME"
}

cleanup() {
  [ -n "${_cred_script}" ] && rm -f "${_cred_script}"
  if [ -n "${WORKDIR}" ] && [ -d "${WORKDIR}" ]; then
    rm -rf "${WORKDIR}"
  fi
}

trap cleanup EXIT

require_env_var GITHUB_TOKEN "GitHub token"
require_env_var ORG "GitHub organization"

if [ -z "${SRC_REPO}" ]; then
  echo "SRC_REPO is empty. Please provide source repository as first argument"
  usage
  exit 1
fi

if [ -z "${DEST_REPO}" ]; then
  echo "DEST_REPO is empty. Please provide destination repository as second argument"
  usage
  exit 1
fi

require_env_var OWNER_USERNAME "Owner username"
require_command git
require_command jq
validate_github_token

# Validate GIT_URL_PREFIX is a recognised GitHub host to prevent credential leakage
# via GIT_ASKPASS, which provides GITHUB_TOKEN to any host git connects to
case "${GIT_URL_PREFIX}" in
  https://github.com|https://*.github.com|https://*.ghe.com|https://*.githubenterprise.com)
    ;;
  *)
    print_error "GIT_URL_PREFIX '${GIT_URL_PREFIX}' is not a recognised GitHub host. \
Refusing to run git operations that would expose GITHUB_TOKEN to an unverified host."
    exit 1
    ;;
esac

validate_slug "${SRC_REPO}"       "source repository name"
validate_slug "${DEST_REPO}"      "destination repository name"
validate_slug "${OWNER_USERNAME}" "owner username"

# Create repo
_payload=$(jq -n --arg name "${DEST_REPO}" '{"name":$name,"visibility":"internal"}')
CREATE_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "${API_URL_PREFIX}/orgs/${ORG}/repos" -d "${_payload}")

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

# Set up a GIT_ASKPASS script so the token is read from an env var at runtime
# rather than embedded in the remote URL (which would expose it in ps output)
_cred_script=$(mktemp)
chmod 700 "${_cred_script}"
printf '%s\n' \
  '#!/bin/bash' \
  'case "$1" in' \
  '  Username*) echo x-access-token ;;' \
  '  *) printf "%s" "${GIT_CRED_TOKEN}" ;;' \
  'esac' \
  > "${_cred_script}"
export GIT_CRED_TOKEN="${GITHUB_TOKEN}"
export GIT_ASKPASS="${_cred_script}"
export GIT_TERMINAL_PROMPT=0

# Clone old repo locally
git clone --bare "${GIT_URL_PREFIX}/${ORG}/${SRC_REPO}.git"

# Push to new repo
cd "${SRC_REPO}.git"
git push --mirror "${GIT_URL_PREFIX}/${ORG}/${DEST_REPO}.git"

unset GIT_ASKPASS GIT_CRED_TOKEN GIT_TERMINAL_PROMPT

echo "Repository import complete: ${SRC_REPO} -> ${DEST_REPO}"
