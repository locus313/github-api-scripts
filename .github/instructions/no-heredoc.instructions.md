---
name: 'No Heredoc File Operations'
description: 'Write file contents with the create and edit tools'
applyTo: '**'
---

# File Writes

Write and modify file contents with the create and edit tools. Terminal
heredocs, `tee`, and interpreter heredoc scripts that open files for writing
corrupt content in the VS Code terminal; the preToolUse hook
`.github/hooks/scripts/block-file-writes-via-bash.sh` denies them.
