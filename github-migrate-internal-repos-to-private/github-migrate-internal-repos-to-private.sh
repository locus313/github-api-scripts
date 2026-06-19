#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/github-common.sh
source "${SCRIPT_DIR}/../lib/github-common.sh"

# This script will obtain a list of repos, check if they are of "Internal" type, and if so, convert them to "Private" type.
# You will need to set your github token as env var GITHUB_TOKEN

GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}

require_env_var GITHUB_TOKEN "GitHub token"
require_env_var ORG "GitHub organization"
require_command jq
validate_github_token

get_repo_pagination () {
    repo_pages=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" -I "${API_URL_PREFIX}/orgs/${ORG}/repos?type=internal&per_page=100" | grep -Eo '&page=[0-9]+' | grep -Eo '[0-9]+' | tail -1;)
    echo "${repo_pages:-1}"
}

limit_repo_pagination () {
  seq "$(get_repo_pagination)"
}

process_repos () {
  local PAGE
  local i
  local repos_json
  local response

  for PAGE in $(limit_repo_pagination); do
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
