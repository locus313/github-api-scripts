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
PORTX_TENANT_FLUX_ADMINS=${PORTX_TENANT_FLUX_ADMINS:-''}
PORTX_INFRASTRUCTURE=${PORTX_INFRASTRUCTURE:-''}

# Create repo from template
curl -X POST -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.baptiste-preview+json" "${API_URL_PREFIX}/repos/${ORG}/${TEMPLATE_REPO}/generate" -d '{"name":"'${REPO_NAME}'", "owner":"'${ORG}'", "private":true, "include_all_branches":true}';

# Give internal teams permissions on the new repo
curl -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/orgs/${ORG}/teams/${PORTX_TENANT_FLUX_ADMINS}/repos/${ORG}/${REPO_NAME}" -d '{"permission":"admin"}';
curl -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/orgs/${ORG}/teams/${PORTX_INFRASTRUCTURE}/repos/${ORG}/${REPO_NAME}" -d '{"permission":"admin"}';

# Give cd user write permissions on the new repo
curl -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/repos/${ORG}/${REPO_NAME}/collaborators/${CD_USERNAME}" -d '{"permission":"push"}';

# Accept the invite automatically 
CD_INVITES=$(curl -H "Authorization: token ${CD_GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/user/repository_invitations")
CD_INVITES_INVITE_ID=$(echo "$CD_INVITES" | jq -r --arg REPO_NAME "${REPO_NAME}" 'select(.[].repository.name==$REPO_NAME) | .[].id')
curl -X PATCH -H "Authorization: token ${CD_GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/user/repository_invitations/${CD_INVITES_INVITE_ID}"
