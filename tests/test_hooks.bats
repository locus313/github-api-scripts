#!/usr/bin/env bats
# =============================================================================
# tests/test_hooks.bats
#
# Verifies .github/hooks/scripts/block-file-writes-via-bash.sh denies heredoc
# and tee file writes and allows ordinary commands.
#
# Usage:
#   bats tests/test_hooks.bats
# =============================================================================

HOOK="${BATS_TEST_DIRNAME}/../.github/hooks/scripts/block-file-writes-via-bash.sh"

# $1 = tool name, $2 = shell command the agent wants to run
_run_hook() {
  local payload
  payload=$(jq -nc --arg t "$1" --arg c "$2" '{toolName: $t, toolArgs: ({command: $c} | tojson)}')
  run bash "${HOOK}" <<<"${payload}"
}

@test "hook: denies cat > file with a quoted heredoc" {
  _run_hook bash "cat > notes.md <<'EOF'
hello
EOF"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

@test "hook: denies cat >> file with an unquoted heredoc" {
  _run_hook bash "cat >> tests/a.bats << EOF
x
EOF"
  [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

@test "hook: denies tee file with a heredoc" {
  _run_hook bash "tee out.txt <<-EOF
x
EOF"
  [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

@test "hook: allows ordinary commands" {
  _run_hook bash "bats tests/ && git status --short"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook: allows a heredoc that does not write a file" {
  _run_hook bash "python3 - <<'EOF'
print(1)
EOF"
  [ -z "$output" ]
}

@test "hook: ignores other tools" {
  _run_hook edit "cat > f <<EOF"
  [ -z "$output" ]
}
