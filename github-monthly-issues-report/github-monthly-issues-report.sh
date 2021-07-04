#!/usr/bin/env /bin/bash
set -euo pipefail

###
## GLOBAL VARIABLES
###
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
REPO=${REPO:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
MONTH_START=${MONTH_START:-''}
MONTH_END=${MONTH_END:-''}

get_public_pagination () {
    public_pages=$(curl -H "Authorization: token ${GITHUB_TOKEN}" -I "${API_URL_PREFIX}/repos/${ORG}/${REPO}/issues?state=all&labels=Linked%20[AC]&per_page=100" | grep -Eo '&page=[0-9]+' | grep -Eo '[0-9]+' | tail -1;)
    echo "${public_pages:-1}"
}

limit_public_pagination () {
  seq "$(get_public_pagination)"
}

repo_issues () {
  for PAGE in $(limit_public_pagination); do
      for i in $(curl -H "Authorization: token ${GITHUB_TOKEN}" -s "${API_URL_PREFIX}/repos/${ORG}/${REPO}/issues?state=all&labels=Linked%20[AC]&page=${PAGE}&per_page=100" | jq -r 'map(select(.created_at | . >= "'$MONTH_START'T00:00" and . <= "'$MONTH_END'T23:59")) | sort_by(.number) | .[] | .number'); do
        ISSUE_PAYLOAD=$(curl -H "Authorization: token ${GITHUB_TOKEN}" -s "${API_URL_PREFIX}/repos/${ORG}/${REPO}/issues/${i}" -H "Accept: application/vnd.github.mercy-preview+json")
        ISSUE_TIMELINE_PAYLOAD=$(curl -H "Authorization: token ${GITHUB_TOKEN}" -s "${API_URL_PREFIX}/repos/${ORG}/${REPO}/issues/${i}/timeline" -H "Accept: application/vnd.github.mockingbird-preview+json" | jq -r '.[] | select(.label.name=="Linked [AC]" or .label.name=="linked")')
        
        ISSUE_AUTHOR=$(echo "$ISSUE_PAYLOAD" | jq -r .user.login)
        ISSUE_TITLE=$(echo "$ISSUE_PAYLOAD" | jq -r .title | tr '"' "'")
        ISSUE_HTML_URL=$(echo "$ISSUE_PAYLOAD" | jq -r .html_url)

        ISSUE_TIMELINE_LABELED_BY=$(echo "$ISSUE_TIMELINE_PAYLOAD" | jq -s 'first(.[]| .actor.login)' | jq -r)

        cat >> test.json << EOF
{
  "author": "${ISSUE_AUTHOR}",
  "title": "${ISSUE_TITLE}",
  "issue_url": "${ISSUE_HTML_URL}",
  "contributor": "${ISSUE_TIMELINE_LABELED_BY}"         
}
EOF

      done
  done
}

author_json () {
  AUTHORS=$(cat test.json| jq -r '.author' | sort | uniq -c | awk -F " " '{print "{\"author\":""\""$2"\""",\"count\":" $1"}"}' | jq -r .author)
    for AUTHOR in ${AUTHORS}; do
    TEST_PAYLOAD=$(cat test.json| jq -r '.author' | sort | uniq -c | awk -F " " '{print "{\"author\":""\""$2"\""",\"count\":" $1"}"}' | jq -r .)
    TEST_PAYLOAD_AUTHOR=$(echo "$TEST_PAYLOAD" | jq -r --arg AUTHOR "${AUTHOR}" 'select(.author==$AUTHOR) | .author')
    TEST_PAYLOAD_AUTHOR_COUNT=$(echo "$TEST_PAYLOAD" | jq -r --arg AUTHOR "${AUTHOR}" 'select(.author==$AUTHOR) | .count')
    #TEST_PAYLOAD_AUTHOR_ISSUE_TITLE=$(cat test.json | jq -r --arg AUTHOR "${AUTHOR}" 'select(.author==$AUTHOR) | .title')
    TEST_PAYLOAD_AUTHOR_ISSUE_URL=$(cat test.json | jq -r --arg AUTHOR "${AUTHOR}" 'select(.author==$AUTHOR) | .title, .issue_url')
    echo -e "<a href="https://github.com/${TEST_PAYLOAD_AUTHOR}">${TEST_PAYLOAD_AUTHOR}</a> - ${TEST_PAYLOAD_AUTHOR_COUNT}"
    done | sort -n -k 4,4 -r >> output.txt
}

contributor_json () {
  CONTRIBUTORS=$(cat test.json| jq -r '.contributor' | sort | uniq -c | awk -F " " '{print "{\"contributor\":""\""$2"\""",\"count\":" $1"}"}' | jq -r .contributor)
    for CONTRIBUTOR in ${CONTRIBUTORS}; do
    TEST_PAYLOAD=$(cat test.json| jq -r '.contributor' | sort | uniq -c | awk -F " " '{print "{\"contributor\":""\""$2"\""",\"count\":" $1"}"}' | jq -r .)
    TEST_PAYLOAD_CONTRIBUTOR=$(echo "$TEST_PAYLOAD" | jq -r --arg CONTRIBUTOR "${CONTRIBUTOR}" 'select(.contributor==$CONTRIBUTOR) | .contributor')
    TEST_PAYLOAD_CONTRIBUTOR_COUNT=$(echo "$TEST_PAYLOAD" | jq -r --arg CONTRIBUTOR "${CONTRIBUTOR}" 'select(.contributor==$CONTRIBUTOR) | .count')
    #TEST_PAYLOAD_CONTRIBUTOR_ISSUE_TITLE=$(cat test.json | jq -r --arg CONTRIBUTOR "${CONTRIBUTOR}" 'select(.contributor==$CONTRIBUTOR) | .title' )
    TEST_PAYLOAD_CONTRIBUTOR_ISSUE_URL=$(cat test.json | jq -r --arg CONTRIBUTOR "${CONTRIBUTOR}" 'select(.contributor==$CONTRIBUTOR) | .issue_url')
    echo -e "<a href="https://github.com/${TEST_PAYLOAD_CONTRIBUTOR}">${TEST_PAYLOAD_CONTRIBUTOR}</a> - ${TEST_PAYLOAD_CONTRIBUTOR_COUNT}"
    done | sort -n -k 4,4 -r >> output.txt
  rm -Rf test.json
}

repo_issues
author_json
contributor_json
