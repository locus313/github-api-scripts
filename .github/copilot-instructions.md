# GitHub API Scripts - AI Agent Instructions

## Project Overview

This is a collection of **standalone bash automation scripts** for GitHub organization and enterprise administration. Scripts are grouped by domain folders (`org-admin/`, `enterprise/`, `reporting/`, `personal/`), and each script lives in its own subdirectory with a single `.sh` file. Scripts use `curl` + `jq` to interact with the GitHub REST and GraphQL APIs. A shared utility library lives in `lib/github-common.sh`.

**Key principle:** Scripts are independent, self-contained utilities. Each script is a complete, self-validating executable that manages its own error handling and input validation. Scripts source `lib/github-common.sh` for shared validation and output helpers where applicable.

## Architecture Pattern

### Directory Structure
```
<domain>/
  └── github-<script-name>/
      └── github-<script-name>.sh    # Single executable script
lib/
  └── github-common.sh               # Shared utility functions
```

Each script follows the `github-<script-name>/github-<script-name>.sh` naming convention inside one domain folder. Scripts are NOT imported or called by each other.

### Shared Library: `lib/github-common.sh`

Provides reusable helpers sourced by scripts:


### Script Anatomy (Standardized Pattern)

All scripts follow this structure:

```bash
#!/bin/bash
set -euo pipefail                # ALWAYS include: exit on error, undefined vars, pipe failures

### GLOBAL VARIABLES
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
GIT_URL_PREFIX=${GIT_URL_PREFIX:-'https://github.com'}
# Script-specific required vars...

# Source shared library (when available)
# SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# source "${SCRIPT_DIR}/../../lib/github-common.sh"

# Token validation block
# Helper functions for pagination/processing
# Main execution logic
```

**Critical patterns:**

## GitHub API Patterns

### Pagination

For org-level repo iteration (REST):
```bash
get_repo_pagination () {
    repo_pages=$(curl -H "Authorization: token ${GITHUB_TOKEN}" -I "${API_URL_PREFIX}/orgs/${ORG}/repos?per_page=100" | grep -Eo '&page=[0-9]+' | grep -Eo '[0-9]+' | tail -1;)
    echo "${repo_pages:-1}"
}

for PAGE in $(seq "$(get_repo_pagination)"); do
  # Process repos on this page with per_page=100
done
```

For enterprise-level org iteration (GraphQL), use cursor-based pagination — see `github-add-enterprise-team-read-permissions.sh` and `github-dockerfile-discovery.sh` for examples.

### Rate Limiting

Rate limiting delays are calibrated per operation type:

### Authentication Headers


### Accept Headers (Media Types)

Different endpoints require specific Accept headers:

### Enterprise Org Lookup Strategy

Scripts that iterate across enterprise orgs (e.g., `github-dockerfile-discovery.sh`, `github-get-public-repos.sh`) use a three-tier fallback:
1. REST `/enterprises/{slug}/organizations` (enterprise owner token)
2. GraphQL `enterprise(slug).organizations` (enterprise member token)
3. Fallback to `/user/orgs` (any `read:org` token)

### Error Handling Pattern

Scripts follow this validation sequence:
1. Check all required env vars are non-empty (exit with descriptive message if missing)
2. Validate token by calling API `/user` endpoint (exit if not 200 status)
3. Validate additional tokens if used (e.g., `CD_GITHUB_TOKEN`)
4. Proceed with main logic only after all validations pass

## Script-Specific Behaviors

### `github-add-enterprise-team-read-permissions`

### `github-add-repo-collaborators-by-pattern`

### `github-add-repo-permissions`

### `github-archive-old-repos`

### `github-auto-repo-creation`

### `github-close-archived-repo-security-alerts`

### `github-dockerfile-discovery`

### `github-enable-issues`

### `github-get-consumed-licenses`

### `github-get-public-repos`

### `github-get-repo-list`

### `github-import-repo`

### `github-migrate-internal-repos-to-private`

### `github-monthly-issues-report`

### `github-organize-stars`

### `github-repo-from-template`

## Development Guidelines

### Adding New Scripts
1. Create directory: `github-<action-verb-object>/`
2. Create script: `github-<action-verb-object>.sh` (match directory name)
3. Source `lib/github-common.sh` for validation and output helpers
4. Start with the standard boilerplate (see Script Anatomy above)
5. Document in README.md following existing format:
   - Use case description
   - Required variables table
   - Usage example with exports
   - Output format (if applicable)

### Testing Approach
- **Always test on a test organization first**
### Variable Naming Conventions
- `GITHUB_TOKEN` — main admin token
### Dependencies
- **bash 4+** (for modern features)
Keep new scripts dependency-minimal; document any non-standard dependencies explicitly.

## Common Pitfalls

1. **Team slugs vs names:** GitHub API uses team slugs (lowercase, hyphenated). Example: "Platform Team" → "platform-team"
2. **Enterprise vs Org endpoints:** License consumption and enterprise team roles require enterprise-level token scopes
3. **Bearer vs token auth:** Enterprise endpoints and GraphQL use `Bearer`; standard REST org/repo endpoints use `token`
4. **Git URL authentication:** When using `git push --mirror`, ensure token has `repo` scope
5. **Space-separated lists:** Variables like `REPO_ADMIN` and `REPO_WRITE` accept multiple values separated by spaces — loop over them with `for team in ${REPO_ADMIN}; do`
6. **Comma-separated lists:** Variables like `COLLABORATORS`, `REPO_NAMES`, and `ORGS` use commas — split with `IFS=','`
7. **URL encoding:** Labels in API calls must be URL-encoded (`Linked [AC]` → `Linked%20[AC]`)
8. **Public repo filtering:** Do not rely on `?type=public` for enterprise-managed orgs — fetch all and filter in jq
9. **macOS vs Linux date:** `github-archive-old-repos.sh` handles both BSD `date -v` (macOS) and GNU `date -d` (Linux)
