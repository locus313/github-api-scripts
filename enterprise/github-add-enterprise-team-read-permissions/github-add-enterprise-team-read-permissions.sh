#!/usr/bin/env bash
# =============================================================================
# github-add-enterprise-team-read-permissions.sh
#
# Assigns the built-in "All-repository read" organisation role to a specified
# enterprise team in every organisation within a GitHub Enterprise account.
# This grants read access to all current and future repositories without
# requiring per-repository assignments.
#
# Usage:
#   export GITHUB_TOKEN=ghp_yourtoken
#   export ENTERPRISE=my-enterprise
#   export ENTERPRISE_TEAM_SLUG=platform-team
#   ./github-add-enterprise-team-read-permissions.sh
#
# Environment variables:
#   GITHUB_TOKEN             Required. PAT with admin:enterprise scope
#   ENTERPRISE               Required. GitHub Enterprise slug
#   ENTERPRISE_TEAM_SLUG     Required. Enterprise team slug (without "ent:" prefix)
#   ALL_REPO_READ_ROLE_NAME  Optional. Org role name (default: all_repo_read)
#   API_URL_PREFIX           Optional. GitHub API base URL (default: https://api.github.com)
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
# GitHub Enterprise Cloud slug (visible in your enterprise URL: github.com/enterprises/{slug})
ENTERPRISE=${ENTERPRISE:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
# Slug used in the org-roles API - enterprise teams use name WITHOUT the "ent:" prefix
ENTERPRISE_TEAM_SLUG=${ENTERPRISE_TEAM_SLUG:-''}
# API name of the built-in org role that grants read on all repositories
ALL_REPO_READ_ROLE_NAME=${ALL_REPO_READ_ROLE_NAME:-'all_repo_read'}

require_env_var GITHUB_TOKEN "GitHub token"
require_env_var ENTERPRISE "GitHub enterprise slug"
require_env_var ENTERPRISE_TEAM_SLUG "Enterprise team slug"
require_command jq
validate_github_token
print_success "GitHub token validated successfully"
print_status "Enterprise: ${ENTERPRISE}"
print_status "Enterprise team slug: ${ENTERPRISE_TEAM_SLUG}"
print_status "Org role to assign: ${ALL_REPO_READ_ROLE_NAME}"

###
## Look up the numeric role_id for the all_repo_read built-in org role
###
get_role_id () {
  local org="$1"

  local response
  response=$(curl -s \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API_URL_PREFIX}/orgs/${org}/organization-roles")

  local status
  status=$(echo "${response}" | jq -r '.status // empty' 2>/dev/null)
  if [ "${status}" = "403" ]; then
    echo "SAML"
    return
  fi
  if [ "${status}" = "404" ]; then
    echo "NOT_FOUND"
    return
  fi

  echo "${response}" | jq -r --arg name "${ALL_REPO_READ_ROLE_NAME}" \
    '.roles[] | select(.name == $name) | .id' 2>/dev/null
}

###
## Assign the org role to the enterprise team
###
process_org () {
  local org="$1"

  print_status "========================================="
  print_status "Processing organization: ${org}"
  print_status "========================================="

  print_status "Looking up role ID for '${ALL_REPO_READ_ROLE_NAME}'..."
  local role_id
  role_id=$(get_role_id "${org}")

  case "${role_id}" in
    SAML)
      print_warning "Skipping ${org}: SAML SSO block — authorize token at github.com/settings/tokens"
      return 2
      ;;
    NOT_FOUND)
      print_warning "Skipping ${org}: org roles not available (org may not be on Enterprise Cloud)"
      return 2
      ;;
    "")
      print_error "Could not find role '${ALL_REPO_READ_ROLE_NAME}' in org ${org}. Skipping."
      return 1
      ;;
  esac

  print_status "Found role ID: ${role_id}"
  print_status "Assigning role to team '${ENTERPRISE_TEAM_SLUG}'..."

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API_URL_PREFIX}/orgs/${org}/organization-roles/teams/${ENTERPRISE_TEAM_SLUG}/${role_id}")

  if [ "${http_code}" -eq 204 ]; then
    print_success "'${ALL_REPO_READ_ROLE_NAME}' org role assigned to '${ENTERPRISE_TEAM_SLUG}' in ${org}"
  else
    print_error "Failed to assign role in ${org} (HTTP ${http_code})"
    return 1
  fi
}

###
## Main
###
print_status "Starting org role assignment..."
print_status "Fetching organizations in enterprise: ${ENTERPRISE}..."

mapfile -t ORG_LIST < <(get_enterprise_orgs)

if [ "${#ORG_LIST[@]}" -eq 0 ]; then
  print_error "No organizations found in enterprise '${ENTERPRISE}'. Check the enterprise slug and token permissions."
  exit 1
fi

print_status "Found ${#ORG_LIST[@]} organization(s)"
echo ""

SUCCESS_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0
SKIPPED_ORGS=()
FAILED_ORGS=()

for ORG in "${ORG_LIST[@]}"; do
  rc=0
  process_org "${ORG}" || rc=$?
  case $rc in
    0) SUCCESS_COUNT=$((SUCCESS_COUNT + 1)) ;;
    2) SKIP_COUNT=$((SKIP_COUNT + 1)); SKIPPED_ORGS+=("${ORG}") ;;
    *) FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_ORGS+=("${ORG}") ;;
  esac
done

echo ""
print_success "Done! ${SUCCESS_COUNT} assigned, ${SKIP_COUNT} skipped (SAML/unsupported), ${FAIL_COUNT} failed."

if [ "${#SKIPPED_ORGS[@]}" -gt 0 ]; then
  echo ""
  print_warning "Skipped orgs (SAML SSO block or org roles unsupported):"
  for org in "${SKIPPED_ORGS[@]}"; do
    echo "  - ${org}"
  done
fi

if [ "${#FAILED_ORGS[@]}" -gt 0 ]; then
  echo ""
  print_error "Failed orgs (role not found or assignment error):"
  for org in "${FAILED_ORGS[@]}"; do
    echo "  - ${org}"
  done
fi
