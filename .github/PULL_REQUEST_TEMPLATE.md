## Description

<!-- What does this PR do? Why is it needed? -->

## Changes

<!-- List the scripts added, modified, or removed. -->

- [ ] New script: `<domain>/github-<name>/github-<name>.sh`
- [ ] Modified: `lib/github-common.sh`
- [ ] Other:

## How to test

```bash
export GITHUB_TOKEN=ghp_REDACTED
export ORG=test-org
./path/to/script.sh [--dry-run]
```

<!-- Describe the expected output and any edge cases tested. -->

## Checklist

- [ ] `set -euo pipefail` is the first executable line after the `# ===` header
- [ ] Script sources `lib/github-common.sh` via `SCRIPT_DIR`
- [ ] All required env vars validated with `require_env_var`
- [ ] Token validated with `validate_github_token` (or `validate_token` for secondary tokens)
- [ ] User-supplied slugs validated with `validate_slug`
- [ ] `sleep` added between repo-level operations to respect rate limits
- [ ] README.md updated with the new/changed script (env var table + usage example)
- [ ] Script header comment matches README documentation
- [ ] Tested on a non-production org before production
- [ ] shellcheck passes (`shellcheck --severity=warning --exclude=SC2034,SC1091 --shell=bash <script>`)
