#!/usr/bin/env /bin/bash
set -euo pipefail

###
## GLOBAL VARIABLES
###
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
GIT_URL_PREFIX=${GIT_URL_PREFIX:-'https://github.com'}
SRC_REPO=$1
DEST_REPO=$2
OWNER_USERNAME=${OWNER_USERNAME:-''}


# Create repo
curl -X POST -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.nebula-preview+json" "${API_URL_PREFIX}/orgs/${ORG}/repos" -d '{"name":"'${DEST_REPO}'", "visibility":"internal"}';

# Grant Admin permissions on new repo
curl -X PUT -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${API_URL_PREFIX}/repos/${ORG}/${DEST_REPO}/collaborators/${OWNER_USERNAME}" -d '{"permission":"admin"}';

# Clone old repo locally
git clone --bare "${GIT_URL_PREFIX}/${ORG}/${SRC_REPO}.git"

# Push to new repo
cd "${SRC_REPO}.git"
git push --mirror "${GIT_URL_PREFIX}/${ORG}/${DEST_REPO}.git"

# Cleanup
cd ..
rm -Rf "${SRC_REPO}.git"
