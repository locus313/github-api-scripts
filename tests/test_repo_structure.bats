#!/usr/bin/env bats
# =============================================================================
# tests/test_repo_structure.bats
#
# Enforces the "Add a new script" checklist from .github/copilot-instructions.md
# for every <domain>/github-<name>/github-<name>.sh:
#   - the script is executable
#   - action.yml sits beside it
#   - tests/test_script_validation.bats has tests for it
#   - README.md documents it (usage section and Available Actions table row)
#
# Usage:
#   bats tests/test_repo_structure.bats
# =============================================================================

REPO_ROOT="${BATS_TEST_DIRNAME}/.."

# Prints the paths of every domain script, one per line.
_scripts() {
  find "${REPO_ROOT}"/{org-admin,enterprise,reporting,personal} \
    -mindepth 2 -maxdepth 2 -name 'github-*.sh' 2>/dev/null | sort
}

# Runs a check function on every script and fails with the list of scripts
# that do not satisfy it.
_assert_all_scripts() {
  local check="$1" script failures=""
  while IFS= read -r script; do
    "${check}" "${script}" || failures+="  ${script#"${REPO_ROOT}"/}"$'\n'
  done < <(_scripts)
  if [ -n "${failures}" ]; then
    echo "Scripts failing ${check#_check_}:"
    echo "${failures}"
    return 1
  fi
}

# Local interactive tools that are intentionally not exposed as GitHub Actions.
_no_action() { [[ "$(basename "$1")" == "github-organize-stars.sh" ]]; }

_check_executable() { [ -x "$1" ]; }
_check_action_yml() { _no_action "$1" || [ -f "$(dirname "$1")/action.yml" ]; }
_check_bats_tests() { grep -q "^@test \"$(basename "$1" .sh):" "${REPO_ROOT}/tests/test_script_validation.bats"; }
_check_readme_script() { grep -q "$(basename "$(dirname "$1")")/$(basename "$1")" "${REPO_ROOT}/README.md"; }
_check_readme_actions_row() { _no_action "$1" || grep -q "^| \`[a-z-]*/$(basename "$1" .sh)\` |" "${REPO_ROOT}/README.md"; }

@test "structure: at least one domain script is discovered" {
  [ -n "$(_scripts)" ]
}

@test "structure: every script is executable" {
  _assert_all_scripts _check_executable
}

@test "structure: every script has an action.yml" {
  _assert_all_scripts _check_action_yml
}

@test "structure: every script has tests in test_script_validation.bats" {
  _assert_all_scripts _check_bats_tests
}

@test "structure: every script is documented in README.md" {
  _assert_all_scripts _check_readme_script
}

@test "structure: every script has a row in the README Available Actions table" {
  _assert_all_scripts _check_readme_actions_row
}
