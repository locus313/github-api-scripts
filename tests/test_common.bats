#!/usr/bin/env bats
# =============================================================================
# tests/test_common.bats
#
# Unit tests for lib/github-common.sh — pure-logic functions and gh_api
# sentinel returns. No real network calls are made; curl is mocked per test.
#
# Requirements:
#   - bats   (https://github.com/bats-core/bats-core / apt install bats)
#
# Usage:
#   bats tests/test_common.bats
# =============================================================================

LIB_PATH="${BATS_TEST_DIRNAME}/../lib/github-common.sh"

# Per-test mock binary directory; prepend to PATH in subshells that need mocking
MOCK_BIN=""

setup() {
  MOCK_BIN="$(mktemp -d)"
}

teardown() {
  rm -rf "$MOCK_BIN"
}

# Write a mock curl that outputs <body>\n<status_code> and ignores all arguments.
# gh_api captures: body=$(curl -s -w "\n%{http_code}" ...) then splits on last line.
# Body and status are passed via env vars to avoid quoting issues with JSON content.
_mock_curl() {
  local code="$1" body="${2:-}"
  export MOCK_CURL_CODE="$code"
  export MOCK_CURL_BODY="$body"
  printf '#!/bin/sh\nprintf "%%s\\n%%s" "$MOCK_CURL_BODY" "$MOCK_CURL_CODE"\n' \
    > "$MOCK_BIN/curl"
  chmod +x "$MOCK_BIN/curl"
}

# ─── validate_slug ────────────────────────────────────────────────────────────

@test "validate_slug: alphanumeric slug passes" {
  run bash -c "GITHUB_TOKEN=x source '${LIB_PATH}' 2>/dev/null; validate_slug 'myrepo123' 'repo'"
  [ "$status" -eq 0 ]
}

@test "validate_slug: slug with hyphens passes" {
  run bash -c "GITHUB_TOKEN=x source '${LIB_PATH}' 2>/dev/null; validate_slug 'my-org-repo' 'repo'"
  [ "$status" -eq 0 ]
}

@test "validate_slug: slug with underscores passes" {
  run bash -c "GITHUB_TOKEN=x source '${LIB_PATH}' 2>/dev/null; validate_slug 'my_repo_name' 'repo'"
  [ "$status" -eq 0 ]
}

@test "validate_slug: space in slug exits 1" {
  run bash -c "GITHUB_TOKEN=x source '${LIB_PATH}' 2>/dev/null; validate_slug 'my repo' 'repo'"
  [ "$status" -eq 1 ]
}

@test "validate_slug: slash in slug exits 1" {
  run bash -c "GITHUB_TOKEN=x source '${LIB_PATH}' 2>/dev/null; validate_slug 'org/repo' 'repo'"
  [ "$status" -eq 1 ]
}

@test "validate_slug: dot in slug exits 1" {
  run bash -c "GITHUB_TOKEN=x source '${LIB_PATH}' 2>/dev/null; validate_slug 'my.repo' 'repo'"
  [ "$status" -eq 1 ]
}

@test "validate_slug: shell metachar in slug exits 1" {
  run bash -c "GITHUB_TOKEN=x source '${LIB_PATH}' 2>/dev/null; validate_slug 'repo\$(evil)' 'repo'"
  [ "$status" -eq 1 ]
}

# ─── require_env_var ──────────────────────────────────────────────────────────

@test "require_env_var: exits 1 when variable is unset" {
  run bash -c "GITHUB_TOKEN=x source '${LIB_PATH}' 2>/dev/null; unset MY_VAR; require_env_var MY_VAR"
  [ "$status" -eq 1 ]
}

@test "require_env_var: exits 1 when variable is empty string" {
  run bash -c "GITHUB_TOKEN=x source '${LIB_PATH}' 2>/dev/null; MY_VAR=''; require_env_var MY_VAR"
  [ "$status" -eq 1 ]
}

@test "require_env_var: exits 0 when variable has a value" {
  run bash -c "GITHUB_TOKEN=x source '${LIB_PATH}' 2>/dev/null; MY_VAR=hello; require_env_var MY_VAR"
  [ "$status" -eq 0 ]
}

# ─── require_command ──────────────────────────────────────────────────────────

@test "require_command: exits 0 for an existing command" {
  run bash -c "GITHUB_TOKEN=x source '${LIB_PATH}' 2>/dev/null; require_command bash"
  [ "$status" -eq 0 ]
}

@test "require_command: exits 1 for a command that does not exist" {
  run bash -c "GITHUB_TOKEN=x source '${LIB_PATH}' 2>/dev/null; require_command __no_such_cmd__"
  [ "$status" -eq 1 ]
}

# ─── gh_api sentinels ─────────────────────────────────────────────────────────

@test "gh_api: returns __404__ on HTTP 404" {
  _mock_curl 404
  # Expand ${MOCK_BIN} and ${PATH} now so the subshell inherits full system PATH
  run bash -c "export PATH='${MOCK_BIN}:${PATH}'; export GITHUB_TOKEN=fake; export API_URL_PREFIX=https://api.github.com; source '${LIB_PATH}' 2>/dev/null; gh_api '/orgs/nonexistent'"
  [ "$status" -eq 0 ]
  [ "$output" = "__404__" ]
}

@test "gh_api: returns __422__ on HTTP 422" {
  _mock_curl 422
  run bash -c "export PATH='${MOCK_BIN}:${PATH}'; export GITHUB_TOKEN=fake; export API_URL_PREFIX=https://api.github.com; source '${LIB_PATH}' 2>/dev/null; gh_api '/orgs/bad-request'"
  [ "$status" -eq 0 ]
  [ "$output" = "__422__" ]
}

@test "gh_api: returns body on HTTP 200" {
  _mock_curl 200 '{"login":"test-org"}'
  run bash -c "export PATH='${MOCK_BIN}:${PATH}'; export GITHUB_TOKEN=fake; export API_URL_PREFIX=https://api.github.com; source '${LIB_PATH}' 2>/dev/null; gh_api '/orgs/test-org'"
  [ "$status" -eq 0 ]
  [ "$output" = '{"login":"test-org"}' ]
}
