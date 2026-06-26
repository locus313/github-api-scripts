#!/usr/bin/env bash
# =============================================================================
# github-monthly-issues-report.sh
#
# Generates a monthly issues report for a GitHub repository, listing all
# issues created within a date range that carry the "Linked [AC]" label,
# grouped by author and contributor.
#
# Usage:
#   export GITHUB_TOKEN=ghp_yourtoken
#   export ORG=my-org
#   export REPO=my-repo
#   export MONTH_START=2025-01-01
#   export MONTH_END=2025-01-31
#   ./github-monthly-issues-report.sh
#
# Environment variables:
#   GITHUB_TOKEN    Required. PAT with repo scope
#   ORG             Required. GitHub organization name
#   REPO            Required. Repository name
#   MONTH_START     Required. Start of reporting period (YYYY-MM-DD)
#   MONTH_END       Required. End of reporting period (YYYY-MM-DD)
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

### GLOBAL VARIABLES
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
REPO=${REPO:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
GIT_URL_PREFIX=${GIT_URL_PREFIX:-'https://github.com'}
MONTH_START=${MONTH_START:-''}
MONTH_END=${MONTH_END:-''}
REPORT_DIR="${REPORT_DIR:-./reports}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_FILE="${REPORT_DIR}/issues-report-${TIMESTAMP}.html"

require_env_var GITHUB_TOKEN "GitHub token"
require_env_var ORG "GitHub organization"
require_env_var REPO "GitHub repository"
require_env_var MONTH_START "Month start date (YYYY-MM-DD)"
require_env_var MONTH_END "Month end date (YYYY-MM-DD)"
require_command jq
validate_github_token

# Validate date format to prevent jq filter injection
if ! [[ "${MONTH_START}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  print_error "MONTH_START must be YYYY-MM-DD, got: ${MONTH_START}"
  exit 1
fi
if ! [[ "${MONTH_END}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  print_error "MONTH_END must be YYYY-MM-DD, got: ${MONTH_END}"
  exit 1
fi

ISSUES_TEMP=$(mktemp)
trap 'rm -f "${ISSUES_TEMP}"' EXIT
mkdir -p "${REPORT_DIR}"

get_issue_pagination () {
    issue_pages=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" -I "${API_URL_PREFIX}/repos/${ORG}/${REPO}/issues?state=all&labels=Linked%20[AC]&per_page=100" | grep -Eo '&page=[0-9]+' | grep -Eo '[0-9]+' | tail -1;)
    echo "${issue_pages:-1}"
}

limit_issue_pagination () {
  seq "$(get_issue_pagination)"
}

repo_issues () {
  for PAGE in $(limit_issue_pagination); do
    while IFS= read -r i; do
      [ -z "${i}" ] && continue
      ISSUE_PAYLOAD=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" "${API_URL_PREFIX}/repos/${ORG}/${REPO}/issues/${i}" -H "Accept: application/vnd.github.mercy-preview+json")
      ISSUE_TIMELINE_PAYLOAD=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" "${API_URL_PREFIX}/repos/${ORG}/${REPO}/issues/${i}/timeline" -H "Accept: application/vnd.github.mockingbird-preview+json" | jq -r '.[] | select(.label.name=="Linked [AC]" or .label.name=="linked")')
      
      ISSUE_AUTHOR=$(echo "${ISSUE_PAYLOAD}" | jq -r .user.login)
      ISSUE_TITLE=$(echo "${ISSUE_PAYLOAD}" | jq -r .title)
      ISSUE_HTML_URL=$(echo "${ISSUE_PAYLOAD}" | jq -r .html_url)

      ISSUE_TIMELINE_LABELED_BY=$(echo "${ISSUE_TIMELINE_PAYLOAD}" | jq -s 'first(.[]| .actor.login)' | jq -r)

      jq -n \
        --arg author "${ISSUE_AUTHOR}" \
        --arg title "${ISSUE_TITLE}" \
        --arg url "${ISSUE_HTML_URL}" \
        --arg contrib "${ISSUE_TIMELINE_LABELED_BY}" \
        '{"author":$author,"title":$title,"issue_url":$url,"contributor":$contrib}' \
        >> "${ISSUES_TEMP}"
    done < <(curl -s -H "Authorization: token ${GITHUB_TOKEN}" "${API_URL_PREFIX}/repos/${ORG}/${REPO}/issues?state=all&labels=Linked%20[AC]&page=${PAGE}&per_page=100" | jq -r --arg s "${MONTH_START}" --arg e "${MONTH_END}" 'map(select(.created_at | . >= ($s+"T00:00") and . <= ($e+"T23:59"))) | sort_by(.number) | .[].number')
  done
}

author_json () {
  AUTHORS=$(cat "${ISSUES_TEMP}" | jq -r '.author' | sort | uniq -c | awk -F " " '{print "{\"author\":""\""\ $2"\""",\"count\":" $1"}"}' | jq -r .author)
  for AUTHOR in ${AUTHORS}; do
    TEST_PAYLOAD=$(cat "${ISSUES_TEMP}" | jq -r '.author' | sort | uniq -c | awk -F " " '{print "{\"author\":""\""\ $2"\""",\"count\":" $1"}"}' | jq -r .)
    TEST_PAYLOAD_AUTHOR=$(echo "${TEST_PAYLOAD}" | jq -r --arg AUTHOR "${AUTHOR}" 'select(.author==$AUTHOR) | .author')
    TEST_PAYLOAD_AUTHOR_COUNT=$(echo "${TEST_PAYLOAD}" | jq -r --arg AUTHOR "${AUTHOR}" 'select(.author==$AUTHOR) | .count')
    echo -e "<a href=\"https://github.com/${TEST_PAYLOAD_AUTHOR}\">${TEST_PAYLOAD_AUTHOR}</a> - ${TEST_PAYLOAD_AUTHOR_COUNT}"
  done | sort -n -k 4,4 -r >> "${OUTPUT_FILE}"
}

contributor_json () {
  CONTRIBUTORS=$(cat "${ISSUES_TEMP}" | jq -r '.contributor' | sort | uniq -c | awk -F " " '{print "{\"contributor\":""\""\ $2"\""",\"count\":" $1"}"}' | jq -r .contributor)
  for CONTRIBUTOR in ${CONTRIBUTORS}; do
    TEST_PAYLOAD=$(cat "${ISSUES_TEMP}" | jq -r '.contributor' | sort | uniq -c | awk -F " " '{print "{\"contributor\":""\""\ $2"\""",\"count\":" $1"}"}' | jq -r .)
    TEST_PAYLOAD_CONTRIBUTOR=$(echo "${TEST_PAYLOAD}" | jq -r --arg CONTRIBUTOR "${CONTRIBUTOR}" 'select(.contributor==$CONTRIBUTOR) | .contributor')
    TEST_PAYLOAD_CONTRIBUTOR_COUNT=$(echo "${TEST_PAYLOAD}" | jq -r --arg CONTRIBUTOR "${CONTRIBUTOR}" 'select(.contributor==$CONTRIBUTOR) | .count')
    echo -e "<a href=\"https://github.com/${TEST_PAYLOAD_CONTRIBUTOR}\">${TEST_PAYLOAD_CONTRIBUTOR}</a> - ${TEST_PAYLOAD_CONTRIBUTOR_COUNT}"
  done | sort -n -k 4,4 -r >> "${OUTPUT_FILE}"
}

repo_issues
author_json
contributor_json
