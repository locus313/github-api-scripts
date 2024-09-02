#!/usr/bin/env /bin/bash
set -euo pipefail

###
## GLOBAL VARIABLES
###
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
TEMPLATE_REPO=${TEMPLATE_REPO:-''}
REPO_NAME=$1
CD_USERNAME=${CD_USERNAME:-''}
CD_GITHUB_TOKEN=${CD_GITHUB_TOKEN:-''}
REPO_ADMIN=${REPO_ADMIN:-'admins example'}
REPO_WRITE=${REPO_WRITE:-'write example2'}

# Check if GITHUB_TOKEN is empty
if [ -z "${GITHUB_TOKEN}" ]
then
      echo "GITHUB_TOKEN is empty. Please set your token and try again"
      exit 1
fi

# Create repo from template
curl -s -X POST -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.baptiste-preview+json" "${API_URL_PREFIX}/repos/${ORG}/${TEMPLATE_REPO}/generate" -d '{"name":"'${REPO_NAME}'", "owner":"'${ORG}'", "private":true, "include_all_branches":true}';

# Give internal teams permissions on the new repo
for ADMIN_TEAM in ${REPO_ADMIN}; do
    curl -s -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/orgs/${ORG}/teams/${ADMIN_TEAM}/repos/${ORG}/${REPO_NAME}" -d '{"permission":"admin"}';
done

for WRITE_TEAM in ${REPO_WRITE}; do
    curl -s -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/orgs/${ORG}/teams/${WRITE_TEAM}/repos/${ORG}/${REPO_NAME}" -d '{"permission":"push"}';
done
# Give cd user write permissions on the new repo
curl -s -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/repos/${ORG}/${REPO_NAME}/collaborators/${CD_USERNAME}" -d '{"permission":"push"}';

# Accept the invite automatically 
CD_INVITES=$(curl -s -H "Authorization: token ${CD_GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/user/repository_invitations")
CD_INVITES_INVITE_ID=$(echo "$CD_INVITES" | jq -r --arg REPO_NAME "${REPO_NAME}" 'select(.[].repository.name==$REPO_NAME) | .[].id')
curl -s -X PATCH -H "Authorization: token ${CD_GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/user/repository_invitations/${CD_INVITES_INVITE_ID}"
