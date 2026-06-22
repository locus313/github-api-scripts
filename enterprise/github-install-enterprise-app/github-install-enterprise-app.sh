#!/bin/bash
# =============================================================================
# github-install-enterprise-app.sh
#
# Programmatically installs an enterprise-owned "automation" GitHub App into an
# enterprise-owned organization, using a second enterprise-owned "installer"
# GitHub App that holds the "Enterprise organization installations" permission.
#
# The flow follows GitHub's "Automating app installations" guide:
#   1. Generate a JWT from the installer app's client ID and private key.
#   2. Exchange the JWT for an enterprise-scoped installation access token.
#   3. Use that token to install the automation app in the target organization.
#   4. (Optional) If the automation app's private key is supplied, exchange a
#      JWT for an organization-scoped installation access token to confirm the
#      new installation works.
#
# No GITHUB_TOKEN / PAT is used: authentication is performed entirely with the
# two GitHub Apps. JWTs and access tokens are never printed.
#
# Usage:
#   export ENTERPRISE=my-enterprise
#   export ORG=my-org
#   export INSTALLER_APP_CLIENT_ID=Iv23li...
#   export INSTALLER_APP_PRIVATE_KEY=~/installer-app.private-key.pem
#   export INSTALLER_APP_INSTALL_ID=12345678
#   export AUTOMATION_APP_CLIENT_ID=Iv23li...
#   ./github-install-enterprise-app.sh [--dry-run]
#
# Options:
#   --dry-run    Authenticate the installer app but do not install anything
#
# Environment variables:
#   ENTERPRISE                  Required. Enterprise slug
#   ORG                         Required. Target organization slug
#   INSTALLER_APP_CLIENT_ID     Required. Installer app client ID
#   INSTALLER_APP_PRIVATE_KEY   Required. Path to installer app .pem private key
#   INSTALLER_APP_INSTALL_ID    Required. Installer app's enterprise install ID
#   AUTOMATION_APP_CLIENT_ID    Required. Automation app client ID (app to install)
#   AUTOMATION_APP_PRIVATE_KEY  Optional. Path to automation app .pem to verify
#                               the new install by minting an org-scoped token
#   REPO_SELECTION              Optional. all | selected (default: all)
#   API_URL_PREFIX              Optional. GitHub API base URL
#                               (default: https://api.github.com)
#
# Requirements:
#   - curl
#   - jq
#   - openssl
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/github-common.sh
source "${SCRIPT_DIR}/../../lib/github-common.sh"

### GLOBAL VARIABLES
ENTERPRISE=${ENTERPRISE:-''}
ORG=${ORG:-''}
INSTALLER_APP_CLIENT_ID=${INSTALLER_APP_CLIENT_ID:-''}
INSTALLER_APP_PRIVATE_KEY=${INSTALLER_APP_PRIVATE_KEY:-''}
INSTALLER_APP_INSTALL_ID=${INSTALLER_APP_INSTALL_ID:-''}
AUTOMATION_APP_CLIENT_ID=${AUTOMATION_APP_CLIENT_ID:-''}
AUTOMATION_APP_PRIVATE_KEY=${AUTOMATION_APP_PRIVATE_KEY:-''}
REPO_SELECTION=${REPO_SELECTION:-'all'}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}

DRY_RUN=false

### ARGUMENT PARSING
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      print_error "Unknown option: ${arg}"
      exit 1
      ;;
  esac
done

### VALIDATION
require_env_var ENTERPRISE "GitHub enterprise"
require_env_var ORG "GitHub organization"
require_env_var INSTALLER_APP_CLIENT_ID "Installer app client ID"
require_env_var INSTALLER_APP_PRIVATE_KEY "Installer app private key path"
require_env_var INSTALLER_APP_INSTALL_ID "Installer app installation ID"
require_env_var AUTOMATION_APP_CLIENT_ID "Automation app client ID"
require_command curl
require_command jq
require_command openssl

validate_slug "${ENTERPRISE}" "enterprise slug"
validate_slug "${ORG}" "organization slug"
validate_slug "${INSTALLER_APP_INSTALL_ID}" "installer app installation ID"

case "${REPO_SELECTION}" in
  all|selected) ;;
  *)
    print_error "REPO_SELECTION must be 'all' or 'selected' (got '${REPO_SELECTION}')"
    exit 1
    ;;
esac

# Expand a leading ~ in private-key paths (env vars are not tilde-expanded).
INSTALLER_APP_PRIVATE_KEY="${INSTALLER_APP_PRIVATE_KEY/#\~/${HOME}}"
[ -n "${AUTOMATION_APP_PRIVATE_KEY}" ] && \
  AUTOMATION_APP_PRIVATE_KEY="${AUTOMATION_APP_PRIVATE_KEY/#\~/${HOME}}"

if [ ! -r "${INSTALLER_APP_PRIVATE_KEY}" ]; then
  print_error "Installer app private key not readable: ${INSTALLER_APP_PRIVATE_KEY}"
  exit 1
fi
if [ -n "${AUTOMATION_APP_PRIVATE_KEY}" ] && [ ! -r "${AUTOMATION_APP_PRIVATE_KEY}" ]; then
  print_error "Automation app private key not readable: ${AUTOMATION_APP_PRIVATE_KEY}"
  exit 1
fi

###
## base64url <stdin>
## Base64-encodes stdin and converts to URL-safe, unpadded form (for JWTs).
###
base64url() {
  openssl base64 -e -A | tr '+/' '-_' | tr -d '='
}

###
## generate_jwt <client_id> <private_key_path>
## Prints a short-lived (10-minute) RS256 JWT signed with the app private key.
## The JWT is written to stdout only; callers must not log it.
###
generate_jwt() {
  local client_id="$1"
  local pem_path="$2"
  local now iat exp header payload signing_input signature

  now=$(date +%s)
  iat=$((now - 60))      # backdate 60s to tolerate clock drift
  exp=$((now + 600))     # GitHub rejects JWTs older than 10 minutes

  header=$(printf '{"typ":"JWT","alg":"RS256"}' | base64url)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "${iat}" "${exp}" "${client_id}" | base64url)
  signing_input="${header}.${payload}"

  signature=$(printf '%s' "${signing_input}" \
    | openssl dgst -sha256 -sign "${pem_path}" -binary \
    | base64url)

  printf '%s.%s' "${signing_input}" "${signature}"
}

###
## mint_installation_token <client_id> <private_key_path> <installation_id>
## Exchanges an app JWT for an installation access token via the
## /app/installations/{id}/access_tokens endpoint. Prints the token to stdout.
###
mint_installation_token() {
  local client_id="$1"
  local pem_path="$2"
  local install_id="$3"
  local jwt response http_code body token message

  jwt=$(generate_jwt "${client_id}" "${pem_path}")

  response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API_URL_PREFIX}/app/installations/${install_id}/access_tokens")

  http_code=$(echo "${response}" | tail -1)
  body=$(echo "${response}" | head -n -1)

  if [ "${http_code}" != "201" ]; then
    message=$(echo "${body}" | jq -r '.message // empty' 2>/dev/null || true)
    print_error "Failed to mint installation token (HTTP ${http_code}): ${message:-unknown error}"
    return 1
  fi

  token=$(echo "${body}" | jq -r '.token // empty')
  if [ -z "${token}" ]; then
    print_error "Installation token missing from API response"
    return 1
  fi

  printf '%s' "${token}"
}

### MAIN
print_status "Authenticating installer app (client ID ${INSTALLER_APP_CLIENT_ID})..."
INSTALLER_TOKEN=$(mint_installation_token \
  "${INSTALLER_APP_CLIENT_ID}" \
  "${INSTALLER_APP_PRIVATE_KEY}" \
  "${INSTALLER_APP_INSTALL_ID}")
print_success "Obtained enterprise-scoped installation token for the installer app."

if [ "${DRY_RUN}" = true ]; then
  print_warning "Dry run: would install automation app '${AUTOMATION_APP_CLIENT_ID}' in org '${ORG}' (repository_selection=${REPO_SELECTION})."
  print_warning "Dry run: no changes made."
  exit 0
fi

print_status "Installing automation app '${AUTOMATION_APP_CLIENT_ID}' in org '${ORG}'..."
INSTALL_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Authorization: Bearer ${INSTALLER_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "${API_URL_PREFIX}/enterprises/${ENTERPRISE}/apps/organizations/${ORG}/installations" \
  -d "$(jq -n \
    --arg client_id "${AUTOMATION_APP_CLIENT_ID}" \
    --arg repository_selection "${REPO_SELECTION}" \
    '{client_id: $client_id, repository_selection: $repository_selection}')")

INSTALL_HTTP_CODE=$(echo "${INSTALL_RESPONSE}" | tail -1)
INSTALL_BODY=$(echo "${INSTALL_RESPONSE}" | head -n -1)

case "${INSTALL_HTTP_CODE}" in
  200|201)
    AUTOMATION_APP_INSTALL_ID=$(echo "${INSTALL_BODY}" | jq -r '.id // empty')
    print_success "Automation app installed in '${ORG}'. Installation ID: ${AUTOMATION_APP_INSTALL_ID}"
    ;;
  *)
    INSTALL_MESSAGE=$(echo "${INSTALL_BODY}" | jq -r '.message // empty' 2>/dev/null || true)
    print_error "Failed to install automation app (HTTP ${INSTALL_HTTP_CODE}): ${INSTALL_MESSAGE:-unknown error}"
    exit 1
    ;;
esac

### OPTIONAL VERIFICATION
if [ -z "${AUTOMATION_APP_PRIVATE_KEY}" ]; then
  print_status "AUTOMATION_APP_PRIVATE_KEY not set; skipping org-scoped token verification."
  exit 0
fi

if [ -z "${AUTOMATION_APP_INSTALL_ID:-}" ]; then
  print_warning "No installation ID returned; cannot verify org-scoped token."
  exit 0
fi

print_status "Verifying new installation by minting an org-scoped token..."
if mint_installation_token \
  "${AUTOMATION_APP_CLIENT_ID}" \
  "${AUTOMATION_APP_PRIVATE_KEY}" \
  "${AUTOMATION_APP_INSTALL_ID}" > /dev/null; then
  print_success "Automation app authenticated successfully in '${ORG}'. Installation is live."
else
  print_error "Could not authenticate the automation app after install."
  exit 1
fi
