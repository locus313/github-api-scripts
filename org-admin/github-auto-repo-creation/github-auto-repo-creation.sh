#!/bin/bash
# =============================================================================
# github-auto-repo-creation.sh
#
# Creates one or more private GitHub repositories in an organisation with
# standard configuration: branch protection on main, a CODEOWNERS file, and
# optional team permissions.
#
# Usage:
#   export GITHUB_TOKEN=ghp_yourtoken
#   export ORG=my-org
#   export REPO_NAMES=repo1,repo2
#   export REPO_OWNERS=platform-team
#   ./github-auto-repo-creation.sh
#
# Environment variables:
#   GITHUB_TOKEN    Required. PAT with repo and admin:org scope
#   ORG             Required. GitHub organization name
#   REPO_NAMES      Required. Comma-separated list of repository names to create
#   REPO_OWNERS     Required. Comma-separated list of CODEOWNERS team slugs
#   ADMIN_TEAMS     Optional. Comma-separated team slugs to grant admin access
#   API_URL_PREFIX  Optional. GitHub API base URL (default: https://api.github.com)
#
# Requirements:
#   - curl
#   - base64
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/github-common.sh
source "${SCRIPT_DIR}/../../lib/github-common.sh"

###
## GLOBAL VARIABLES - Set default values for the required environment variables
###
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}

# Set default values for repository names and admin teams and code owners
REPO_NAMES=${REPO_NAMES:-''}
ADMIN_TEAMS=${ADMIN_TEAMS:-''}
REPO_OWNERS=${REPO_OWNERS:-''}

require_env_var GITHUB_TOKEN "GitHub token"
require_env_var ORG "GitHub organization"
require_env_var REPO_NAMES "Repo names list"
require_env_var REPO_OWNERS "Repo owners list"
require_command base64
require_command jq
validate_github_token

# Define the content of the CODEOWNERS file
CODEOWNERS_CONTENT=$(cat << EOF
# Lines starting with '#' are comments.
# Each line is a file pattern followed by one or more owners.

# More details are here: https://help.github.com/articles/about-codeowners/

# The '*' pattern is global owners.

# Order is important. The last matching pattern has the most precedence.
# The folders are ordered as follows:

# In each subsection folders are ordered first by depth, then alphabetically.
# This should make it easy to add new rules without breaking existing ones.

# Global rule:
*$(IFS=','; for owner in $REPO_OWNERS; do printf " @${ORG}/${owner}"; done)


EOF
)

# Function to create a new GitHub repository
create_github_repo() {
  local repo_name="$1"
  local _payload
  _payload=$(jq -n --arg name "${repo_name}" \
    '{"name":$name,"private":true,"auto_init":true,"has_issues":true,"has_projects":false,"has_wiki":true}')
  curl -s -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API_URL_PREFIX}/orgs/${ORG}/repos" \
    -d "${_payload}"
}

# Function to enable branch protection on the main branch
enable_branch_protection() {
  local repo_name=$1
  curl -s -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "${API_URL_PREFIX}/repos/${ORG}/${repo_name}/branches/main/protection" -d "{
    \"required_status_checks\": null,
    \"enforce_admins\": true,
    \"required_pull_request_reviews\": {
      \"dismiss_stale_reviews\": false,
      \"require_code_owner_reviews\": true,
      \"required_approving_review_count\": 1
    },
    \"restrictions\": null
  }"
}

# Function to create a CODEOWNERS file in the repository
create_codeowners_file() {
  local repo_name=$1
  curl -s -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "${API_URL_PREFIX}/repos/${ORG}/${repo_name}/contents/.github/CODEOWNERS" -d "{
    \"message\": \"Add CODEOWNERS file\",
    \"content\": \"$(echo "${CODEOWNERS_CONTENT}" | base64 | tr -d '\n')\"
  }"
}

# Function to add a team with admin permissions to the repository
add_teams_to_repo() {
  local repo_name=$1
  local team_name=$2
  curl -s -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "${API_URL_PREFIX}/orgs/${ORG}/teams/${team_name}/repos/${ORG}/${repo_name}" -d "{
    \"permission\": \"admin\"
  }"
}

# Function to add a team with write permissions to the repository
add_repo_owners_to_repo() {
  local repo_name=$1
  local team_name=$2
  curl -s -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "${API_URL_PREFIX}/orgs/${ORG}/teams/${team_name}/repos/${ORG}/${repo_name}" -d "{
    \"permission\": \"push\"
  }"
}

# Convert comma-separated lists into arrays
mapfile -t REPO_NAMES  < <(tr ',' '\n' <<< "${REPO_NAMES}")
mapfile -t ADMIN_TEAMS < <(tr ',' '\n' <<< "${ADMIN_TEAMS:-}")
mapfile -t REPO_OWNERS < <(tr ',' '\n' <<< "${REPO_OWNERS}")

# Loop through each repository and perform the required actions
for repo_name in "${REPO_NAMES[@]}"; do
  echo "Creating repository ${repo_name}"
  create_github_repo "${repo_name}"

  echo "Creating CODEOWNERS file for ${repo_name}"
  create_codeowners_file "${repo_name}"
  
  echo "Enabling branch protection for ${repo_name}"
  enable_branch_protection "${repo_name}"

  # Add each admin team to the repository
  for team_name in "${ADMIN_TEAMS[@]}"; do
    echo "Adding team ${team_name} as admin to ${repo_name}"
    add_teams_to_repo "${repo_name}" "${team_name}"
  done

    # Add each repo owner team to the repository with write permissions, but only if it's not an admin team
  for team_name in "${REPO_OWNERS[@]}"; do
    if [[ ! "${ADMIN_TEAMS[*]}" =~ ${team_name} ]]; then
      echo "Adding team ${team_name} as a repo owner (write permission) to ${repo_name}"
      add_repo_owners_to_repo "${repo_name}" "${team_name}"
    fi
  done
done