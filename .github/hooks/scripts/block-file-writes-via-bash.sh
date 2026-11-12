#!/usr/bin/env bash
# =============================================================================
# block-file-writes-via-bash.sh
#
# preToolUse hook for the bash tool. Denies commands that write file contents
# through heredocs, tee, or interpreter heredoc scripts, steering the agent to
# the create/edit tools. Allows the command if the payload cannot be parsed.
# =============================================================================

set -euo pipefail

deny() {
  jq -nc '{permissionDecision: "deny",
           permissionDecisionReason: "Write files with the create or edit tools; bash heredoc writes are blocked."}'
  exit 0
}

# Fail open: an unparseable payload must not block every bash call
payload="$(cat)"
tool_name="$(printf '%s' "${payload}" | jq -r '.toolName // ""' 2>/dev/null)" || exit 0
[[ "${tool_name}" == "bash" ]] || exit 0

# toolArgs arrives as a JSON string on some hosts and as an object on others
command="$(printf '%s' "${payload}" | jq -r '.toolArgs // {} | if type == "string" then fromjson else . end | .command // ""' 2>/dev/null)" || exit 0

# Heredoc redirected into a file or tee: cat > f <<EOF, tee f <<'EOF', cat >> f <<-EOF
if printf '%s' "${command}" | grep -Eq '(>|tee)[^<|;&]*<<-?[[:space:]]*['\''"\\]?[A-Za-z_]'; then
  deny
fi

# Heredoc script for an interpreter that opens a file for writing
if printf '%s' "${command}" | grep -Eq '(python3?|node|ruby|perl)[^<|;&]*<<' \
  && printf '%s' "${command}" | grep -Eq 'open\([^)]*['\''"][wa]\+?['\''"]|writeFile|write_text|File\.write'; then
  deny
fi
exit 0
