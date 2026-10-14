#!/usr/bin/env bash
# =============================================================================
# block-file-writes-via-bash.sh
#
# preToolUse hook for the bash tool. Denies commands that write file contents
# through heredocs or tee, steering the agent to the create/edit tools.
# =============================================================================

set -euo pipefail

payload="$(cat)"
tool_name="$(printf '%s' "${payload}" | jq -r '.toolName // ""')"
[[ "${tool_name}" == "bash" ]] || exit 0

command="$(printf '%s' "${payload}" | jq -r '.toolArgs // "{}" | fromjson | .command // ""')"

# Heredoc redirected into a file or tee: cat > f <<EOF, tee f <<'EOF', cat >> f <<-EOF
if printf '%s' "${command}" | grep -Eq '(>|tee)[^<|;&]*<<-?[[:space:]]*['\''"\\]?[A-Za-z_]'; then
  jq -nc '{permissionDecision: "deny",
           permissionDecisionReason: "Write files with the create or edit tools; bash heredoc writes are blocked."}'
fi
exit 0
