# GitHub API Scripts - AI Agent Instructions

## Project Overview

This is a collection of **standalone bash automation scripts** for GitHub organization administration. Each script lives in its own directory with a single `.sh` file. Scripts use `curl` + `jq` to interact with the GitHub REST API v3.

**Key principle:** Scripts are independent, self-contained utilities—not a unified codebase. There's no shared library or common framework. Each script is a complete, self-validating executable that manages its own error handling and input validation.

## Architecture Pattern

### Directory Structure
```
github-<script-name>/
  └── github-<script-name>.sh    # Single executable script
```

Each script follows this exact naming convention. Scripts are NOT imported or called by each other.

### Script Anatomy (Standardized Pattern)

All scripts follow this structure:

```bash
#!/usr/bin/env /bin/bash
set -euo pipefail                # ALWAYS include: exit on error, undefined vars, pipe failures

### GLOBAL VARIABLES
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
GIT_URL_PREFIX=${GIT_URL_PREFIX:-'https://github.com'}
# Script-specific required vars...

# Token validation block (if applicable)
# Helper functions for pagination/processing
# Main execution logic
```

**Critical patterns:**
- Use `${VARIABLE:-''}` for all env vars to provide empty defaults
- Set `API_URL_PREFIX` and `GIT_URL_PREFIX` for GitHub Enterprise Server compatibility
- Include `sleep 5` between API calls to avoid rate limits (see `github-add-repo-permissions.sh` line 99)
- Use pagination helpers for org-level operations (pattern in `github-add-repo-permissions.sh` lines 45-51)
- **ALWAYS validate required variables** with explicit `if [ -z "${VAR}" ]` checks before any API calls
- **ALWAYS validate GITHUB_TOKEN** by calling `/user` endpoint and checking for 200 status code
- Use `curl -s -o /dev/null -w "%{http_code}"` pattern to check HTTP status codes
- Exit with status code 1 on validation failures with descriptive error messages

## GitHub API Patterns

### Pagination
When iterating over all repos in an org, use this pattern:
```bash
get_repo_pagination () {
    repo_pages=$(curl -H "Authorization: token ${GITHUB_TOKEN}" -I "${API_URL_PREFIX}/orgs/${ORG}/repos?per_page=100" | grep -Eo '&page=[0-9]+' | grep -Eo '[0-9]+' | tail -1;)
    echo "${repo_pages:-1}"
}

for PAGE in $(seq "$(get_repo_pagination)"); do
  # Process repos on this page with per_page=100
done
```

### Rate Limiting
**Always include `sleep 5`** between repository-level operations to stay under GitHub's rate limits. See `github-add-repo-permissions.sh` line 99 or `github-repo-from-template.sh` lines 77, 83.

### Authentication Headers
- Use `Bearer` token for enterprise endpoints: `-H "Authorization: Bearer ${GITHUB_TOKEN}"`
- Use `token` for standard API: `-H "Authorization: token ${GITHUB_TOKEN}"`
- Include API version when specified: `-H "X-GitHub-Api-Version: 2022-11-28"`

### Accept Headers (Media Types)
Different endpoints require specific Accept headers:
- Template generation: `application/vnd.github.baptiste-preview+json`
- Timeline events: `application/vnd.github.mockingbird-preview+json`
- Issue reactions: `application/vnd.github.mercy-preview+json`
- Repository visibility: `application/vnd.github.nebula-preview+json`
- Standard operations: `application/vnd.github.v3+json`

### Error Handling Pattern
All scripts follow this validation sequence:
1. Check all required env vars are non-empty (exit with descriptive message if missing)
2. Validate token by calling API `/user` endpoint (exit if not 200 status)
3. Validate additional tokens if used (e.g., `CD_GITHUB_TOKEN`)
4. Proceed with main logic only after all validations pass

## Script-Specific Behaviors

### `github-add-repo-permissions`
- Grants team permissions to ALL repos in an org across 5 permission levels
- Uses pagination + 5-second delay between repos
- Variables: `REPO_ADMIN`, `REPO_MAINTAIN`, `REPO_PUSH`, `REPO_TRIAGE`, `REPO_PULL` (all accept **space-separated team slugs**)
- At least one permission level variable must be set
- Loops through teams with helper function `apply_team_permissions()`

### `github-repo-from-template`
- `REPO_ADMIN` and `REPO_WRITE` are **space-separated lists** of team slugs
- Automatically accepts collaborator invite using `CD_GITHUB_TOKEN` (a separate token for the CD user)
- Permission mapping: `admin` = admin, `push` = write access
- Retrieves invite ID via `/user/repository_invitations` and accepts via PATCH request
- Creates repo with `private: true` and `include_all_branches: true` by default

### `github-import-repo`
- Performs **bare clone** + mirror push (full git history)
- Takes 2 positional args: `$1=SRC_REPO`, `$2=DEST_REPO`
- Cleans up local `.git` directory after mirroring
- Creates new repo with `visibility: internal`
- Grants admin permissions to `OWNER_USERNAME` on destination repo
- Requires git to be installed and accessible in PATH

### `github-monthly-issues-report`
- Generates HTML output to `output.txt` (not stdout)
- Creates temporary `test.json` file (cleaned up at end)
- Hardcoded label filter: `Linked%20[AC]` (URL-encoded)
- Filters issues by creation date between `MONTH_START` and `MONTH_END`
- Uses timeline API to track who applied labels
- Aggregates statistics and sorts by count (descending)

### `github-get-consumed-licenses`
- Uses **Bearer token** authentication (different from other scripts)
- Requires enterprise-level token scope (`read:enterprise`)
- Calls `/enterprises/{ENTERPRISE}/consumed-licenses` endpoint
- Outputs two metrics: seats consumed and seats purchased

## Development Guidelines

### Adding New Scripts
1. Create directory: `github-<action-verb-object>/`
2. Create script: `github-<action-verb-object>.sh` (match directory name)
3. Start with the standard boilerplate (see Script Anatomy above)
4. Document in README.md following existing format:
   - Use case description
   - Required variables table
   - Usage example with exports
   - Output format (if applicable)

### Testing Approach
- **Always test on a test organization first** (mentioned in README tips)
- Scripts have no built-in dry-run mode—handle with care
- Use `2>&1 | tee execution.log` to capture output for auditing

### Variable Naming Conventions
- `GITHUB_TOKEN` - main admin token
- `ORG` - organization name
- `ENTERPRISE` - enterprise account name
- `REPO` - single repository name
- `TEMPLATE_REPO` - source template repository
- `CD_USERNAME` / `CD_GITHUB_TOKEN` - automation user credentials
- `MONTH_START` / `MONTH_END` - ISO date format `YYYY-MM-DD`

### Dependencies
- **bash 4+** (for modern features)
- **curl** (API requests)
- **jq** (JSON parsing - REQUIRED for all scripts)
- **git** (only for `github-import-repo`)

No other dependencies. Keep scripts dependency-minimal.

## Common Pitfalls

1. **Team slugs vs names:** GitHub API uses team slugs (lowercase, hyphenated). Example: "Platform Team" → "platform-team"
2. **Enterprise vs Org endpoints:** License consumption requires enterprise-level token scopes
3. **Git URL authentication:** When using `git push --mirror`, ensure token has repo scope
4. **Space-separated lists:** Some variables like `REPO_ADMIN` accept multiple values separated by spaces (loop over them)
5. **URL encoding:** Labels in API calls must be URL-encoded (`Linked [AC]` → `Linked%20[AC]`)
