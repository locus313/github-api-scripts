#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/github-common.sh
source "${SCRIPT_DIR}/../lib/github-common.sh"

###
## GLOBAL VARIABLES
###
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}

require_env_var GITHUB_TOKEN "GitHub token"
require_env_var ORG "GitHub organization"
require_command jq
validate_github_token

get_repo_pagination () {
    repo_pages=$(curl -H "Authorization: token ${GITHUB_TOKEN}" -I "${API_URL_PREFIX}/orgs/${ORG}/repos?per_page=100" | grep -Eo '&page=[0-9]+' | grep -Eo '[0-9]+' | tail -1;)
    echo "${repo_pages:-1}"
}

limit_repo_pagination () {
  seq "$(get_repo_pagination)"
}

process_repos () {
  local PAGE
  local i
  local repos_json
  local REPO_PAYLOAD
  local REPO_FULLNAME
  local REPO_OWNER
  local REPO_PRIVATE
  local REPO_HTMLURL
  local REPO_DESCRIPTION
  local REPO_FORK
  local REPO_PUSHEDAT
  local REPO_CREATEDAT
  local REPO_UPDATEDAT
  local ESCAPED_DESCRIPTION

  for PAGE in $(limit_repo_pagination); do
    repos_json=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" "${API_URL_PREFIX}/orgs/${ORG}/repos?page=${PAGE}&per_page=100&sort=full_name")

    while IFS= read -r i; do
      [ -z "${i}" ] && continue

      REPO_PAYLOAD=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/repos/${ORG}/${i}")
      REPO_FULLNAME=$(echo "${REPO_PAYLOAD}" | jq -r .full_name)
      REPO_OWNER=$(echo "${REPO_PAYLOAD}" | jq -r .owner.login)
      REPO_PRIVATE=$(echo "${REPO_PAYLOAD}" | jq -r .private)
      REPO_HTMLURL=$(echo "${REPO_PAYLOAD}" | jq -r .html_url)
      REPO_DESCRIPTION=$(echo "${REPO_PAYLOAD}" | jq -r '.description // ""')
      REPO_FORK=$(echo "${REPO_PAYLOAD}" | jq -r .fork)
      REPO_PUSHEDAT=$(echo "${REPO_PAYLOAD}" | jq -r .pushed_at)
      REPO_CREATEDAT=$(echo "${REPO_PAYLOAD}" | jq -r .created_at)
      REPO_UPDATEDAT=$(echo "${REPO_PAYLOAD}" | jq -r .updated_at)
      ESCAPED_DESCRIPTION=$(echo "${REPO_DESCRIPTION}" | sed 's/"/""/g')

      printf '%s,%s,%s,%s,%s,"%s",%s,%s,%s,%s\n' \
        "${i}" "${REPO_FULLNAME}" "${REPO_OWNER}" "${REPO_PRIVATE}" "${REPO_HTMLURL}" \
        "${ESCAPED_DESCRIPTION}" "${REPO_FORK}" "${REPO_PUSHEDAT}" "${REPO_CREATEDAT}" "${REPO_UPDATEDAT}" \
        >> repo-list.csv
    done < <(echo "${repos_json}" | jq -r 'sort_by(.name) | .[] | .name')
  done
}

echo "name,full_name,owner,private,html_url,description,fork,pushed_at,created_at,updated_at" > repo-list.csv
process_repos
