#!/usr/bin/env bats
# =============================================================================
# tests/test_common.bats
#
# Unit tests for lib/github-common.sh — pure-logic functions and API helpers.
# No real network calls are made; curl and gh are mocked per test via a
# temporary directory prepended to PATH.
#
# Requirements:
#   - bats   (https://github.com/bats-core/bats-core / apt install bats)
#
# Usage:
#   bats tests/test_common.bats
# =============================================================================

LIB_PATH="${BATS_TEST_DIRNAME}/../lib/github-common.sh"

MOCK_BIN=""

setup() {
  MOCK_BIN="$(mktemp -d)"
  # Default gh mock: fails all calls so GITHUB_TOKEN is not auto-resolved
  printf '#!/bin/sh\nexit 1\n' > "$MOCK_BIN/gh"
  chmod +x "$MOCK_BIN/gh"
}

teardown() {
  rm -rf "$MOCK_BIN"
}

# Install the universal curl mock. Passes response data via env vars so no
# quoting issues arise with JSON or special characters in the body.
#   $1  HTTP status code  (default: 200)
#   $2  Response body     (default: empty)
#   $3  Link: next URL    (default: empty = last page)
_mock_curl() {
  local code="${1:-200}" body="${2:-}" link="${3:-}"
  export MOCK_CURL_CODE="$code"
  export MOCK_CURL_BODY="$body"
  export MOCK_CURL_LINK="$link"
  cp "${BATS_TEST_DIRNAME}/mock_curl.sh" "$MOCK_BIN/curl"
  chmod +x "$MOCK_BIN/curl"
}

# ─── err ──────────────────────────────────────────────────────────────────────

@test "err: exits 1" {
  run bash -c "GITHUB_TOKEN=x source '${LIB_PATH}' 2>/dev/null; err 'something went wrong'"
  [ "$status" -eq 1 ]
}

@test "err: output contains the supplied message" {
  run bash -c "GITHUB_TOKEN=x source '${LIB_PATH}' 2>/dev/null; err 'something went wrong'" 2>&1
  [[ "$output" == *"something went wrong"* ]]
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

# ─── configure_gh_auth ────────────────────────────────────────────────────────

@test "configure_gh_auth: passes and exports GH_TOKEN when GITHUB_TOKEN is set" {
  run bash -c "
    export PATH='${MOCK_BIN}:${PATH}'
    export GITHUB_TOKEN=mytoken
    source '${LIB_PATH}' 2>/dev/null
    configure_gh_auth
    [ \"\$GH_TOKEN\" = 'mytoken' ]
  "
  [ "$status" -eq 0 ]
}

@test "configure_gh_auth: exits 1 when GITHUB_TOKEN unset and gh auth fails" {
  run bash -c "
    export PATH='${MOCK_BIN}:${PATH}'
    unset GITHUB_TOKEN
    source '${LIB_PATH}' 2>/dev/null
    configure_gh_auth
  "
  [ "$status" -eq 1 ]
}

# ─── validate_token / validate_github_token ───────────────────────────────────

@test "validate_token: exits 0 on HTTP 200" {
  _mock_curl 200
  run bash -c "
    export PATH='${MOCK_BIN}:${PATH}'
    export GITHUB_TOKEN=fake
    export API_URL_PREFIX=https://api.github.com
    source '${LIB_PATH}' 2>/dev/null
    validate_token GITHUB_TOKEN
  "
  [ "$status" -eq 0 ]
}

@test "validate_token: exits 1 on HTTP 401" {
  _mock_curl 401
  run bash -c "
    export PATH='${MOCK_BIN}:${PATH}'
    export GITHUB_TOKEN=fake
    export API_URL_PREFIX=https://api.github.com
    source '${LIB_PATH}' 2>/dev/null
    validate_token GITHUB_TOKEN
  "
  [ "$status" -eq 1 ]
}

@test "validate_github_token: emits warning for non-GitHub API_URL_PREFIX" {
  _mock_curl 200
  run bash -c "
    export PATH='${MOCK_BIN}:${PATH}'
    export GITHUB_TOKEN=fake
    export API_URL_PREFIX=https://not-github.example.com
    source '${LIB_PATH}' 2>/dev/null
    validate_github_token
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not look like"* ]]
}

@test "validate_github_token: no warning for api.github.com" {
  _mock_curl 200
  run bash -c "
    export PATH='${MOCK_BIN}:${PATH}'
    export GITHUB_TOKEN=fake
    export API_URL_PREFIX=https://api.github.com
    source '${LIB_PATH}' 2>/dev/null
    validate_github_token
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"does not look like"* ]]
}

# ─── get_repo_page_count ──────────────────────────────────────────────────────

@test "get_repo_page_count: returns 1 when there is no Link header" {
  _mock_curl 200
  run bash -c "
    export PATH='${MOCK_BIN}:${PATH}'
    export GITHUB_TOKEN=fake
    export API_URL_PREFIX=https://api.github.com
    source '${LIB_PATH}' 2>/dev/null
    get_repo_page_count 'https://api.github.com/orgs/test/repos?per_page=100'
  "
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "get_repo_page_count: returns last page number from Link header" {
  # Body contains a Link header line — get_repo_page_count greps stdout for &page=N
  _mock_curl 200 'Link: <https://api.github.com/orgs/test/repos?per_page=100&page=7>; rel="last"'
  run bash -c "
    export PATH='${MOCK_BIN}:${PATH}'
    export GITHUB_TOKEN=fake
    export API_URL_PREFIX=https://api.github.com
    source '${LIB_PATH}' 2>/dev/null
    get_repo_page_count 'https://api.github.com/orgs/test/repos?per_page=100'
  "
  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
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

@test "gh_api: prepends API_URL_PREFIX when path starts with /" {
  _mock_curl 200 '{"ok":true}'
  run bash -c "
    export PATH='${MOCK_BIN}:${PATH}'
    export GITHUB_TOKEN=fake
    export API_URL_PREFIX=https://api.github.com
    source '${LIB_PATH}' 2>/dev/null
    result=\$(gh_api '/some/path')
    [ \"\$result\" = '{\"ok\":true}' ]
  "
  [ "$status" -eq 0 ]
}

# ─── gh_api_paginate ──────────────────────────────────────────────────────────

@test "gh_api_paginate: exits 0 silently on HTTP 404" {
  _mock_curl 404
  run bash -c "
    export PATH='${MOCK_BIN}:${PATH}'
    export GITHUB_TOKEN=fake
    export API_URL_PREFIX=https://api.github.com
    source '${LIB_PATH}' 2>/dev/null
    gh_api_paginate '/orgs/nonexistent/repos'
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "gh_api_paginate: exits 0 silently on HTTP 422" {
  _mock_curl 422
  run bash -c "
    export PATH='${MOCK_BIN}:${PATH}'
    export GITHUB_TOKEN=fake
    export API_URL_PREFIX=https://api.github.com
    source '${LIB_PATH}' 2>/dev/null
    gh_api_paginate '/orgs/test/repos'
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "gh_api_paginate: outputs items from a single page" {
  _mock_curl 200 '[{"name":"repo-a"},{"name":"repo-b"}]'
  run bash -c "
    export PATH='${MOCK_BIN}:${PATH}'
    export GITHUB_TOKEN=fake
    export API_URL_PREFIX=https://api.github.com
    source '${LIB_PATH}' 2>/dev/null
    gh_api_paginate '/orgs/test/repos'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"name":"repo-a"'* ]]
  [[ "$output" == *'"name":"repo-b"'* ]]
}
