#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/github-common.sh
source "${SCRIPT_DIR}/../lib/github-common.sh"

### GLOBAL VARIABLES
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ENTERPRISE=${ENTERPRISE:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}

require_env_var GITHUB_TOKEN "GitHub token"
require_env_var ENTERPRISE "GitHub enterprise"
require_command jq
validate_github_token bearer

get_licenses () {
  PAYLOAD=$(curl -s -L -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "${API_URL_PREFIX}/enterprises/${ENTERPRISE}/consumed-licenses")

  if ! echo "${PAYLOAD}" | jq -e 'type == "object"' > /dev/null 2>&1; then
    echo "Error: Unexpected API response format"
    exit 1
  fi

  ERROR_MESSAGE=$(echo "${PAYLOAD}" | jq -r '.message // empty')
  if [ -n "${ERROR_MESSAGE}" ]; then
    echo "Error: ${ERROR_MESSAGE}"
    exit 1
  fi

  SEATS_CONSUMED=$(echo "${PAYLOAD}" | jq -r .total_seats_consumed)
  SEATS_PURCHASED=$(echo "${PAYLOAD}" | jq -r .total_seats_purchased)

  if [ -z "${SEATS_CONSUMED}" ] || [ -z "${SEATS_PURCHASED}" ] || [ "${SEATS_CONSUMED}" = "null" ] || [ "${SEATS_PURCHASED}" = "null" ]; then
    echo "Error: Could not parse seat usage from API response"
    exit 1
  fi

  echo "Total seats consumed: ${SEATS_CONSUMED}"
  echo "Total seats purchased: ${SEATS_PURCHASED}"
}

get_licenses
