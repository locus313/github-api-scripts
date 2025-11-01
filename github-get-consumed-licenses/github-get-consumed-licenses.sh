#!/usr/bin/env /bin/bash
set -euo pipefail

### GLOBAL VARIABLES
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ENTERPRISE=${ENTERPRISE:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}

# Check if GITHUB_TOKEN is set
if [ -z "${GITHUB_TOKEN}" ]; then
  echo "GITHUB_TOKEN is empty. Please set your token and try again"
  exit 1
fi

# Check if ENTERPRISE is set
if [ -z "${ENTERPRISE}" ]; then
  echo "ENTERPRISE is empty. Please set your enterprise and try again"
  exit 1
fi

# Validate GITHUB_TOKEN by calling GitHub API
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${GITHUB_TOKEN}" "${API_URL_PREFIX}/user")

if [ "${RESPONSE}" -ne 200 ]; then
  echo "Error: GITHUB_TOKEN is invalid or does not have required permissions."
  exit 1
fi

get_licenses () {
  PAYLOAD=$(curl -s -L -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "${API_URL_PREFIX}/enterprises/${ENTERPRISE}/consumed-licenses")
  SEATS_CONSUMED=$(echo "${PAYLOAD}" | jq -r .total_seats_consumed)
  SEATS_PURCHASED=$(echo "${PAYLOAD}" | jq -r .total_seats_purchased)
  echo "Total seats consumed: ${SEATS_CONSUMED}"
  echo "Total seats purchased: ${SEATS_PURCHASED}"
}

get_licenses
