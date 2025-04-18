#!/bin/bash
set -euo pipefail

###
## GLOBAL VARIABLES
###
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ENTERPRISE=${ENTERPRISE:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}

if [ -z "${GITHUB_TOKEN}" ]
then
      echo "GITHUB_TOKEN is empty. Please set your token and try again"
      exit 1
fi

list_enterprise_hosted_runners () {
  PAYLOAD=$(curl -s -L -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "${API_URL_PREFIX}/enterprises/${ENTERPRISE}/actions/hosted-runners")
  echo Enterprise Hosted Runners:
  echo "$PAYLOAD"
}

get_enterprise_hosted_runners_limits () {
  PAYLOAD=$(curl -s -L -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "${API_URL_PREFIX}/enterprises/${ENTERPRISE}/actions/hosted-runners/limits")
  echo Enterprise Hosted Runners Limits:
  echo "$PAYLOAD"
}

list_org_hosted_runners () {
  PAYLOAD=$(curl -s -L -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "${API_URL_PREFIX}/orgs/${ORG}/actions/hosted-runners")
  echo Org Hosted Runners:
  echo "$PAYLOAD"
}

list_enterprise_hosted_runners
get_enterprise_hosted_runners_limits
list_org_hosted_runners
