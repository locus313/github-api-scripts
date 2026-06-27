#!/usr/bin/env bash
# =============================================================================
# github-migrate-internal-repos-to-private.sh
#
# Converts all repositories with "internal" visibility to "private" in a
# GitHub organisation.
#
# Usage:
#   export GITHUB_TOKEN=ghp_yourtoken
#   export ORG=my-org
#   ./github-migrate-internal-repos-to-private.sh
#
# Environment variables:
#   GITHUB_TOKEN    Required. PAT with repo scope
#   ORG             Required. GitHub organization name
#   API_URL_PREFIX  Optional. GitHub API base URL (default: https://api.github.com)
#
# Requirements:
#   - curl
#   - jq
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/github-common.sh
source "${SCRIPT_DIR}/../../lib/github-common.sh"

GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}

require_env_var GITHUB_TOKEN "GitHub token"
require_env_var ORG "GitHub organization"
require_command jq
validate_github_token

process_repos () {
  local PAGE
  local i
  local repos_json
  local response

  for PAGE in $(seq "$(get_repo_page_count "${API_URL_PREFIX}/orgs/${ORG}/repos?type=internal&per_page=100")"); do
    repos_json=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" "${API_URL_PREFIX}/orgs/${ORG}/repos?type=internal&page=${PAGE}&per_page=100&sort=full_name")

    while IFS= read -r i; do
      [ -z "${i}" ] && continue

      echo "Converting Repo: ${i} from internal type to private....Started"
      response=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/repos/${ORG}/${i}" -d '{"visibility":"private"}')

      if [ "${response}" -eq 200 ]; then
        echo "Converting Repo: ${i} from internal type to private....Completed"
      else
        echo "Failed to convert Repo: ${i} (HTTP ${response})"
      fi
    done < <(echo "${repos_json}" | jq -r 'sort_by(.name) | .[] | .name')
  done
}

process_repos
