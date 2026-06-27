#!/usr/bin/env bats
# =============================================================================
# tests/test_script_validation.bats
#
# Per-script tests verifying:
#   - Required environment variables: missing var exits 1 before any API call
#   - CLI argument parsing: unknown args exit 1, --help exits 0, recognised
#     flags (--dry-run, --type) do not trigger "Unknown argument" errors
#   - Script-specific input validation: invalid enum values, invalid URL
#     allowlists, missing required positional args
#
# curl and gh are mocked in MOCK_BIN so no real network calls are made.
# Where a test needs to reach past the token-validation step, _mock_curl_200
# installs a mock that returns HTTP 200.
#
# Requirements:
#   - bats   (https://github.com/bats-core/bats-core / apt install bats)
#
# Usage:
#   bats tests/test_script_validation.bats
# =============================================================================

REPO_ROOT="${BATS_TEST_DIRNAME}/.."
MOCK_BIN=""

setup() {
  MOCK_BIN="$(mktemp -d)"
  # gh mock: fail all calls so GITHUB_TOKEN is never auto-resolved from a session
  printf '#!/bin/sh\nexit 1\n' > "$MOCK_BIN/gh"
  chmod +x "$MOCK_BIN/gh"
}

teardown() {
  rm -rf "$MOCK_BIN"
}

# Install a mock curl that always returns HTTP 200 with an empty body.
# Used for tests that need to pass token validation before reaching later checks.
_mock_curl_200() {
  export MOCK_CURL_CODE=200
  export MOCK_CURL_BODY=""
  export MOCK_CURL_LINK=""
  cp "${BATS_TEST_DIRNAME}/mock_curl.sh" "$MOCK_BIN/curl"
  chmod +x "$MOCK_BIN/curl"
}

# Run SCRIPT with MOCK_BIN prepended to PATH and an optional shell preamble.
# $1 = script path, $2 = preamble (env/unset shell statements, optional)
# $3 = script CLI arguments (optional)
_run_script() {
  local script="$1" preamble="${2:-}" args="${3:-}"
  run bash -c "export PATH='${MOCK_BIN}:${PATH}'; ${preamble} bash '${script}' ${args}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# org-admin/github-add-repo-collaborators-by-pattern
# ═══════════════════════════════════════════════════════════════════════════════

@test "github-add-repo-collaborators-by-pattern: exits 1 when GITHUB_TOKEN is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-add-repo-collaborators-by-pattern/github-add-repo-collaborators-by-pattern.sh" "unset GITHUB_TOKEN;"
  [ "$status" -eq 1 ]
}

@test "github-add-repo-collaborators-by-pattern: exits 1 when ORG is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-add-repo-collaborators-by-pattern/github-add-repo-collaborators-by-pattern.sh" "export GITHUB_TOKEN=fake; unset ORG;"
  [ "$status" -eq 1 ]
}

@test "github-add-repo-collaborators-by-pattern: exits 1 when COLLABORATORS is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-add-repo-collaborators-by-pattern/github-add-repo-collaborators-by-pattern.sh" "export GITHUB_TOKEN=fake; export ORG=test; unset COLLABORATORS;"
  [ "$status" -eq 1 ]
}

@test "github-add-repo-collaborators-by-pattern: exits 1 when REPO_NAME_REGEX is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-add-repo-collaborators-by-pattern/github-add-repo-collaborators-by-pattern.sh" "export GITHUB_TOKEN=fake; export ORG=test; export COLLABORATORS=user1; unset REPO_NAME_REGEX;"
  [ "$status" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# org-admin/github-add-repo-permissions
# ═══════════════════════════════════════════════════════════════════════════════

@test "github-add-repo-permissions: exits 1 when GITHUB_TOKEN is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-add-repo-permissions/github-add-repo-permissions.sh" "unset GITHUB_TOKEN;"
  [ "$status" -eq 1 ]
}

@test "github-add-repo-permissions: exits 1 when ORG is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-add-repo-permissions/github-add-repo-permissions.sh" "export GITHUB_TOKEN=fake; unset ORG;"
  [ "$status" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# org-admin/github-archive-old-repos
# ═══════════════════════════════════════════════════════════════════════════════

@test "github-archive-old-repos: exits 1 when GITHUB_TOKEN is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-archive-old-repos/github-archive-old-repos.sh" "unset GITHUB_TOKEN;"
  [ "$status" -eq 1 ]
}

@test "github-archive-old-repos: exits 1 when ORG is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-archive-old-repos/github-archive-old-repos.sh" "export GITHUB_TOKEN=fake; unset ORG;"
  [ "$status" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# org-admin/github-auto-repo-creation
# ═══════════════════════════════════════════════════════════════════════════════

@test "github-auto-repo-creation: exits 1 when GITHUB_TOKEN is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-auto-repo-creation/github-auto-repo-creation.sh" "unset GITHUB_TOKEN;"
  [ "$status" -eq 1 ]
}

@test "github-auto-repo-creation: exits 1 when ORG is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-auto-repo-creation/github-auto-repo-creation.sh" "export GITHUB_TOKEN=fake; unset ORG;"
  [ "$status" -eq 1 ]
}

@test "github-auto-repo-creation: exits 1 when REPO_NAMES is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-auto-repo-creation/github-auto-repo-creation.sh" "export GITHUB_TOKEN=fake; export ORG=test; unset REPO_NAMES;"
  [ "$status" -eq 1 ]
}

@test "github-auto-repo-creation: exits 1 when REPO_OWNERS is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-auto-repo-creation/github-auto-repo-creation.sh" "export GITHUB_TOKEN=fake; export ORG=test; export REPO_NAMES=my-repo; unset REPO_OWNERS;"
  [ "$status" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# org-admin/github-close-archived-repo-security-alerts
# ═══════════════════════════════════════════════════════════════════════════════

@test "github-close-archived-repo-security-alerts: exits 1 when GITHUB_TOKEN is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-close-archived-repo-security-alerts/github-close-archived-repo-security-alerts.sh" "unset GITHUB_TOKEN;"
  [ "$status" -eq 1 ]
}

@test "github-close-archived-repo-security-alerts: exits 1 when ORG is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-close-archived-repo-security-alerts/github-close-archived-repo-security-alerts.sh" "export GITHUB_TOKEN=fake; unset ORG;"
  [ "$status" -eq 1 ]
}

@test "github-close-archived-repo-security-alerts: exits 1 for unknown argument" {
  _run_script "${REPO_ROOT}/org-admin/github-close-archived-repo-security-alerts/github-close-archived-repo-security-alerts.sh" "unset GITHUB_TOKEN;" "--garbage"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown argument"* ]]
}

@test "github-close-archived-repo-security-alerts: exits 1 for invalid --type value" {
  _run_script "${REPO_ROOT}/org-admin/github-close-archived-repo-security-alerts/github-close-archived-repo-security-alerts.sh" "unset GITHUB_TOKEN;" "--type badtype"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid --type"* ]]
}

@test "github-close-archived-repo-security-alerts: --dry-run is recognised (fails at token check)" {
  _run_script "${REPO_ROOT}/org-admin/github-close-archived-repo-security-alerts/github-close-archived-repo-security-alerts.sh" "unset GITHUB_TOKEN;" "--dry-run"
  [ "$status" -eq 1 ]
  [[ "$output" != *"Unknown argument"* ]]
}

@test "github-close-archived-repo-security-alerts: exits 1 for invalid DEPENDABOT_REASON" {
  _run_script "${REPO_ROOT}/org-admin/github-close-archived-repo-security-alerts/github-close-archived-repo-security-alerts.sh" "export DEPENDABOT_REASON=bad-value; unset GITHUB_TOKEN;"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid DEPENDABOT_REASON"* ]]
}

@test "github-close-archived-repo-security-alerts: exits 1 for invalid SECRET_SCANNING_RESOLUTION" {
  _run_script "${REPO_ROOT}/org-admin/github-close-archived-repo-security-alerts/github-close-archived-repo-security-alerts.sh" "export SECRET_SCANNING_RESOLUTION=bad-value; unset GITHUB_TOKEN;"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid SECRET_SCANNING_RESOLUTION"* ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# org-admin/github-enable-issues
# ═══════════════════════════════════════════════════════════════════════════════

@test "github-enable-issues: exits 1 when GITHUB_TOKEN is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-enable-issues/github-enable-issues.sh" "unset GITHUB_TOKEN;"
  [ "$status" -eq 1 ]
}

@test "github-enable-issues: exits 1 when ORG is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-enable-issues/github-enable-issues.sh" "export GITHUB_TOKEN=fake; unset ORG;"
  [ "$status" -eq 1 ]
}

@test "github-enable-issues: --help exits 0" {
  _run_script "${REPO_ROOT}/org-admin/github-enable-issues/github-enable-issues.sh" "" "--help"
  [ "$status" -eq 0 ]
}

@test "github-enable-issues: exits 1 for unknown argument" {
  _run_script "${REPO_ROOT}/org-admin/github-enable-issues/github-enable-issues.sh" "unset GITHUB_TOKEN;" "--garbage"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown argument"* ]]
}

@test "github-enable-issues: --dry-run is recognised (fails at token check)" {
  _run_script "${REPO_ROOT}/org-admin/github-enable-issues/github-enable-issues.sh" "unset GITHUB_TOKEN;" "--dry-run"
  [ "$status" -eq 1 ]
  [[ "$output" != *"Unknown argument"* ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# org-admin/github-get-repo-list
# ═══════════════════════════════════════════════════════════════════════════════

@test "github-get-repo-list: exits 1 when GITHUB_TOKEN is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-get-repo-list/github-get-repo-list.sh" "unset GITHUB_TOKEN;"
  [ "$status" -eq 1 ]
}

@test "github-get-repo-list: exits 1 when ORG is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-get-repo-list/github-get-repo-list.sh" "export GITHUB_TOKEN=fake; unset ORG;"
  [ "$status" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# org-admin/github-import-repo
# ═══════════════════════════════════════════════════════════════════════════════

@test "github-import-repo: exits 1 when GITHUB_TOKEN is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-import-repo/github-import-repo.sh" "unset GITHUB_TOKEN;"
  [ "$status" -eq 1 ]
}

@test "github-import-repo: exits 1 when ORG is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-import-repo/github-import-repo.sh" "export GITHUB_TOKEN=fake; unset ORG;"
  [ "$status" -eq 1 ]
}

@test "github-import-repo: exits 1 for non-GitHub GIT_URL_PREFIX" {
  # Needs to pass past require_env_var and validate_github_token before hitting the allowlist check
  _mock_curl_200
  run bash -c "
    export PATH='${MOCK_BIN}:${PATH}'
    export GITHUB_TOKEN=fake
    export ORG=test-org
    export OWNER_USERNAME=user
    export GIT_URL_PREFIX=https://evil.example.com
    export API_URL_PREFIX=https://api.github.com
    bash '${REPO_ROOT}/org-admin/github-import-repo/github-import-repo.sh' src dest
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a recognised GitHub host"* ]]
}

@test "github-import-repo: accepts default GIT_URL_PREFIX (github.com)" {
  # Verify the allowlist itself passes for the default value — reaches git, not the guard
  _mock_curl_200
  run bash -c "
    export PATH='${MOCK_BIN}:${PATH}'
    export GITHUB_TOKEN=fake
    export ORG=test-org
    export OWNER_USERNAME=user
    export GIT_URL_PREFIX=https://github.com
    export API_URL_PREFIX=https://api.github.com
    bash '${REPO_ROOT}/org-admin/github-import-repo/github-import-repo.sh' src dest 2>&1 || true
  "
  [[ "$output" != *"not a recognised GitHub host"* ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# org-admin/github-migrate-internal-repos-to-private
# ═══════════════════════════════════════════════════════════════════════════════

@test "github-migrate-internal-repos-to-private: exits 1 when GITHUB_TOKEN is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-migrate-internal-repos-to-private/github-migrate-internal-repos-to-private.sh" "unset GITHUB_TOKEN;"
  [ "$status" -eq 1 ]
}

@test "github-migrate-internal-repos-to-private: exits 1 when ORG is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-migrate-internal-repos-to-private/github-migrate-internal-repos-to-private.sh" "export GITHUB_TOKEN=fake; unset ORG;"
  [ "$status" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# org-admin/github-repo-from-template
# ═══════════════════════════════════════════════════════════════════════════════

@test "github-repo-from-template: exits 1 when GITHUB_TOKEN is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-repo-from-template/github-repo-from-template.sh" "unset GITHUB_TOKEN;"
  [ "$status" -eq 1 ]
}

@test "github-repo-from-template: exits 1 when ORG is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-repo-from-template/github-repo-from-template.sh" "export GITHUB_TOKEN=fake; unset ORG;"
  [ "$status" -eq 1 ]
}

@test "github-repo-from-template: exits 1 when TEMPLATE_REPO is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-repo-from-template/github-repo-from-template.sh" "export GITHUB_TOKEN=fake; export ORG=test; unset TEMPLATE_REPO;"
  [ "$status" -eq 1 ]
}

@test "github-repo-from-template: exits 1 when CD_USERNAME is not set" {
  _run_script "${REPO_ROOT}/org-admin/github-repo-from-template/github-repo-from-template.sh" "export GITHUB_TOKEN=fake; export ORG=test; export TEMPLATE_REPO=my-template; unset CD_USERNAME;"
  [ "$status" -eq 1 ]
}

@test "github-repo-from-template: exits 1 when CD_GITHUB_TOKEN is not set" {
  # CD_GITHUB_TOKEN is checked after validate_github_token — needs mocked curl
  _mock_curl_200
  run bash -c "
    export PATH='${MOCK_BIN}:${PATH}'
    export GITHUB_TOKEN=fake
    export ORG=test
    export TEMPLATE_REPO=my-template
    export CD_USERNAME=cduser
    export REPO_NAME=new-repo
    unset CD_GITHUB_TOKEN
    export API_URL_PREFIX=https://api.github.com
    bash '${REPO_ROOT}/org-admin/github-repo-from-template/github-repo-from-template.sh'
  "
  [ "$status" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# enterprise/github-add-enterprise-team-read-permissions
# ═══════════════════════════════════════════════════════════════════════════════

@test "github-add-enterprise-team-read-permissions: exits 1 when GITHUB_TOKEN is not set" {
  _run_script "${REPO_ROOT}/enterprise/github-add-enterprise-team-read-permissions/github-add-enterprise-team-read-permissions.sh" "unset GITHUB_TOKEN;"
  [ "$status" -eq 1 ]
}

@test "github-add-enterprise-team-read-permissions: exits 1 when ENTERPRISE is not set" {
  _run_script "${REPO_ROOT}/enterprise/github-add-enterprise-team-read-permissions/github-add-enterprise-team-read-permissions.sh" "export GITHUB_TOKEN=fake; unset ENTERPRISE;"
  [ "$status" -eq 1 ]
}

@test "github-add-enterprise-team-read-permissions: exits 1 when ENTERPRISE_TEAM_SLUG is not set" {
  _run_script "${REPO_ROOT}/enterprise/github-add-enterprise-team-read-permissions/github-add-enterprise-team-read-permissions.sh" "export GITHUB_TOKEN=fake; export ENTERPRISE=my-ent; unset ENTERPRISE_TEAM_SLUG;"
  [ "$status" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# enterprise/github-dockerfile-discovery
# ═══════════════════════════════════════════════════════════════════════════════

@test "github-dockerfile-discovery: exits 1 when GITHUB_TOKEN is not set" {
  _run_script "${REPO_ROOT}/enterprise/github-dockerfile-discovery/github-dockerfile-discovery.sh" "unset GITHUB_TOKEN;"
  [ "$status" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# enterprise/github-get-consumed-licenses
# ═══════════════════════════════════════════════════════════════════════════════

@test "github-get-consumed-licenses: exits 1 when GITHUB_TOKEN is not set" {
  _run_script "${REPO_ROOT}/enterprise/github-get-consumed-licenses/github-get-consumed-licenses.sh" "unset GITHUB_TOKEN;"
  [ "$status" -eq 1 ]
}

@test "github-get-consumed-licenses: exits 1 when ENTERPRISE is not set" {
  _run_script "${REPO_ROOT}/enterprise/github-get-consumed-licenses/github-get-consumed-licenses.sh" "export GITHUB_TOKEN=fake; unset ENTERPRISE;"
  [ "$status" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# enterprise/github-get-public-repos
# ═══════════════════════════════════════════════════════════════════════════════

@test "github-get-public-repos: exits 1 when GITHUB_TOKEN is not set" {
  _run_script "${REPO_ROOT}/enterprise/github-get-public-repos/github-get-public-repos.sh" "unset GITHUB_TOKEN;"
  [ "$status" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# enterprise/github-install-enterprise-app
# ═══════════════════════════════════════════════════════════════════════════════

@test "github-install-enterprise-app: exits 1 when ENTERPRISE is not set" {
  _run_script "${REPO_ROOT}/enterprise/github-install-enterprise-app/github-install-enterprise-app.sh" "unset ENTERPRISE;"
  [ "$status" -eq 1 ]
}

@test "github-install-enterprise-app: exits 1 when ORG is not set" {
  _run_script "${REPO_ROOT}/enterprise/github-install-enterprise-app/github-install-enterprise-app.sh" "export ENTERPRISE=my-ent; unset ORG;"
  [ "$status" -eq 1 ]
}

@test "github-install-enterprise-app: exits 1 when INSTALLER_APP_CLIENT_ID is not set" {
  _run_script "${REPO_ROOT}/enterprise/github-install-enterprise-app/github-install-enterprise-app.sh" "export ENTERPRISE=my-ent; export ORG=test; unset INSTALLER_APP_CLIENT_ID;"
  [ "$status" -eq 1 ]
}

@test "github-install-enterprise-app: exits 1 for unknown argument" {
  _run_script "${REPO_ROOT}/enterprise/github-install-enterprise-app/github-install-enterprise-app.sh" "unset ENTERPRISE;" "--garbage"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "github-install-enterprise-app: --help exits 0" {
  _run_script "${REPO_ROOT}/enterprise/github-install-enterprise-app/github-install-enterprise-app.sh" "" "--help"
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# reporting/github-monthly-issues-report
# ═══════════════════════════════════════════════════════════════════════════════

@test "github-monthly-issues-report: exits 1 when GITHUB_TOKEN is not set" {
  _run_script "${REPO_ROOT}/reporting/github-monthly-issues-report/github-monthly-issues-report.sh" "unset GITHUB_TOKEN;"
  [ "$status" -eq 1 ]
}

@test "github-monthly-issues-report: exits 1 when ORG is not set" {
  _run_script "${REPO_ROOT}/reporting/github-monthly-issues-report/github-monthly-issues-report.sh" "export GITHUB_TOKEN=fake; unset ORG;"
  [ "$status" -eq 1 ]
}

@test "github-monthly-issues-report: exits 1 when REPO is not set" {
  _run_script "${REPO_ROOT}/reporting/github-monthly-issues-report/github-monthly-issues-report.sh" "export GITHUB_TOKEN=fake; export ORG=test; unset REPO;"
  [ "$status" -eq 1 ]
}

@test "github-monthly-issues-report: exits 1 when MONTH_START is not set" {
  _run_script "${REPO_ROOT}/reporting/github-monthly-issues-report/github-monthly-issues-report.sh" "export GITHUB_TOKEN=fake; export ORG=test; export REPO=my-repo; unset MONTH_START;"
  [ "$status" -eq 1 ]
}

@test "github-monthly-issues-report: exits 1 when MONTH_END is not set" {
  _run_script "${REPO_ROOT}/reporting/github-monthly-issues-report/github-monthly-issues-report.sh" "export GITHUB_TOKEN=fake; export ORG=test; export REPO=my-repo; export MONTH_START=2024-01-01; unset MONTH_END;"
  [ "$status" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# reporting/github-repo-permissions-report
# ═══════════════════════════════════════════════════════════════════════════════

@test "github-repo-permissions-report: exits 1 when -r is not provided" {
  _run_script "${REPO_ROOT}/reporting/github-repo-permissions-report/github-repo-permissions-report.sh" "export GITHUB_TOKEN=fake;"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Repository is required"* ]]
}

@test "github-repo-permissions-report: exits 1 when GITHUB_TOKEN is not set" {
  _run_script "${REPO_ROOT}/reporting/github-repo-permissions-report/github-repo-permissions-report.sh" "unset GITHUB_TOKEN;" "-r org/repo"
  [ "$status" -eq 1 ]
}

@test "github-repo-permissions-report: --help exits 0" {
  _run_script "${REPO_ROOT}/reporting/github-repo-permissions-report/github-repo-permissions-report.sh" "" "--help"
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# reporting/github-copilot-report
# ═══════════════════════════════════════════════════════════════════════════════

@test "github-copilot-report: exits 1 when GITHUB_TOKEN is not set" {
  _run_script "${REPO_ROOT}/reporting/github-copilot-report/github-copilot-report.sh" "unset GITHUB_TOKEN;"
  [ "$status" -eq 1 ]
}

@test "github-copilot-report: --help exits 0" {
  _run_script "${REPO_ROOT}/reporting/github-copilot-report/github-copilot-report.sh" "" "--help"
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# personal/github-organize-stars
# ═══════════════════════════════════════════════════════════════════════════════

@test "github-organize-stars: exits 1 when not authenticated (no token, no gh session)" {
  _run_script "${REPO_ROOT}/personal/github-organize-stars/github-organize-stars.sh" "unset GITHUB_TOKEN;"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Not authenticated"* ]]
}

@test "github-organize-stars: --help exits 0" {
  _run_script "${REPO_ROOT}/personal/github-organize-stars/github-organize-stars.sh" "" "--help"
  [ "$status" -eq 0 ]
}

@test "github-organize-stars: --dry-run is recognised (fails at auth check, not arg parse)" {
  _run_script "${REPO_ROOT}/personal/github-organize-stars/github-organize-stars.sh" "unset GITHUB_TOKEN;" "--dry-run"
  [ "$status" -eq 1 ]
  [[ "$output" != *"Unknown option"* ]]
}
