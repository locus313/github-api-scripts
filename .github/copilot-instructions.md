# GitHub API Scripts - AI Agent Instructions

## Project Overview

This is a collection of **standalone bash automation scripts** for GitHub organization and enterprise administration. Each script lives in its own directory with a single `.sh` file. Scripts use `curl` + `jq` to interact with the GitHub REST and GraphQL APIs. A shared utility library lives in `lib/github-common.sh`.

**Key principle:** Scripts are independent, self-contained utilities. Each script is a complete, self-validating executable that manages its own error handling and input validation. Scripts source `lib/github-common.sh` for shared validation and output helpers where applicable.

## Architecture Pattern

### Directory Structure
```
github-<script-name>/
  └── github-<script-name>.sh    # Single executable script
lib/
  └── github-common.sh           # Shared utility functions
```

Each script follows this exact naming convention. Scripts are NOT imported or called by each other.

### Shared Library: `lib/github-common.sh`

Provides reusable helpers sourced by scripts:

- **Color output:** `print_status` (blue INFO), `print_success` (green), `print_warning` (yellow), `print_error` (red, to stderr)
- **Validation:** `require_env_var <VAR> [desc]` — exits with status 1 if empty; `require_command <cmd> [hint]` — exits if not in PATH
- **Token validation:** `validate_token <VAR_NAME> [bearer]` — calls `/user` endpoint; `validate_github_token [bearer]` — convenience wrapper for `GITHUB_TOKEN`
- **Pagination:** `get_repo_page_count <url>` — returns total page count from Link header

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
# source "${SCRIPT_DIR}/../lib/github-common.sh"

# Token validation block
# Helper functions for pagination/processing
# Main execution logic
```

**Critical patterns:**
- Use `${VARIABLE:-''}` for all env vars to provide empty defaults
- Set `API_URL_PREFIX` and `GIT_URL_PREFIX` for GitHub Enterprise Server compatibility
- **ALWAYS validate required variables** before any API calls — use `require_env_var` from lib or explicit `if [ -z "${VAR}" ]` checks
- **ALWAYS validate GITHUB_TOKEN** via `validate_github_token` (lib) or the `/user` endpoint pattern
- Use `curl -s -o /dev/null -w "%{http_code}"` pattern to check HTTP status codes
- Exit with status code 1 on validation failures with descriptive error messages
- Rate limiting delays vary by script: `sleep 5` for per-repo team operations, `sleep 2` for archive operations, `sleep 0.5` or `sleep 0.2` for lighter patch operations

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
- **Per-repo team permission assignments:** `sleep 5` (see `github-add-repo-permissions.sh`, `github-repo-from-template.sh`)
- **Archive operations:** `sleep 2` (see `github-archive-old-repos.sh`)
- **Lightweight patch operations:** `sleep 0.5` (see `github-enable-issues.sh`) or `sleep 0.2` (see `github-close-archived-repo-security-alerts.sh`)
- **Code search + content fetch:** configurable `SEARCH_SLEEP` / `CONTENT_SLEEP` with exponential backoff (see `github-dockerfile-discovery.sh`, `github-get-public-repos.sh`)

### Authentication Headers

- `token` scheme for standard org/repo API: `-H "Authorization: token ${GITHUB_TOKEN}"`
- `Bearer` scheme for enterprise endpoints and GraphQL: `-H "Authorization: Bearer ${GITHUB_TOKEN}"`
- Some scripts use **both** (e.g., `github-dockerfile-discovery.sh`, `github-get-public-repos.sh`)
- Include API version when specified: `-H "X-GitHub-Api-Version: 2022-11-28"`

### Accept Headers (Media Types)

Different endpoints require specific Accept headers:
- Template generation: `application/vnd.github.baptiste-preview+json`
- Timeline events: `application/vnd.github.mockingbird-preview+json`
- Issue reactions: `application/vnd.github.mercy-preview+json`
- Repository visibility: `application/vnd.github.nebula-preview+json`
- Standard operations: `application/vnd.github.v3+json`

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
- Assigns the "All-repository read" built-in org role to an enterprise team across all orgs in an enterprise
- Uses **GraphQL** with cursor-based pagination to iterate enterprise organizations
- Variables: `ENTERPRISE`, `ENTERPRISE_TEAM_SLUG`, `ALL_REPO_READ_ROLE_NAME` (default: `all_repo_read`)
- Handles SAML SSO blocks gracefully (skips affected orgs with a warning)
- Provides a summary of skipped and failed orgs at the end

### `github-add-repo-collaborators-by-pattern`
- Adds individual GitHub users as collaborators to repositories whose names match a regex
- Variables: `ORG`, `COLLABORATORS` (comma-separated usernames), `REPO_NAME_REGEX` (ERE regex)
- Optional: `PERMISSION` (default: `push`), `REPO_EXCLUDE_REGEX`
- Paginates through all org repos; applies both include and exclude regex filters
- No explicit rate-limit delay between user additions

### `github-add-repo-permissions`
- Grants team permissions to ALL repos in an org across 5 permission levels
- Variables: `REPO_ADMIN`, `REPO_MAINTAIN`, `REPO_PUSH`, `REPO_TRIAGE`, `REPO_PULL` (all accept **space-separated team slugs**)
- At least one permission level variable must be set
- Uses pagination + `sleep 5` delay between repos
- Loops through teams with helper function `apply_team_permissions()`

### `github-archive-old-repos`
- Identifies repos not updated in the last N years (configurable via `YEARS_THRESHOLD`, default: `5`)
- Generates a timestamped CSV report in `reports/old_repos_${TIMESTAMP}.csv`
- **Interactive:** Prompts for confirmation before archiving; shows top 10 oldest repos first
- Skips already-archived repos; uses `sleep 2` between archive operations
- macOS (`date -v`) and Linux (`date -d`) compatible date arithmetic

### `github-auto-repo-creation`
- Creates repos with branch protection, a `CODEOWNERS` file, and team assignments
- Variables: `REPO_NAMES` (comma-separated), `REPO_OWNERS` (comma-separated team slugs with write), `ADMIN_TEAMS` (comma-separated team slugs with admin)
- Creates repos as `private: true`, with issues enabled, no projects or wiki
- Encodes CODEOWNERS content via `base64` for API upload
- Enforces branch protection on `main`: admin enforcement, 1 required approval, code owner reviews required

### `github-close-archived-repo-security-alerts`
- Dismisses Dependabot, code-scanning, and secret-scanning alerts on all archived repos in an org
- Accepts CLI flags: `--type dependabot|code-scanning|secret-scanning|all` (default: all), `--dry-run`
- Optional dismiss/resolve reasons: `DEPENDABOT_REASON`, `CODE_SCANNING_REASON`, `SECRET_SCANNING_RESOLUTION`
- Generates timestamped CSV report in `reports/security_alerts_closed_${TIMESTAMP}.csv`
- Uses `sleep 0.2` between alert closure operations

### `github-dockerfile-discovery`
- Searches all orgs in a GitHub Enterprise for Dockerfiles; extracts base images from `FROM` instructions
- Variables: `ENTERPRISE` (or `ORGS` to skip enterprise lookup), optional `ORG_FILTER` / `ORG_EXCLUDE` ERE regex
- Configurable delays: `SEARCH_SLEEP` (default: `2`), `CONTENT_SLEEP` (default: `1`)
- Parses multi-stage builds, `ARG` defaults, image digests, and `--platform` overrides
- Generates two CSVs (detail + summary) and a human-readable TXT summary in `REPORT_DIR` (default: `./reports`)
- Requires `base64` (file content decoding) and `python3` (URL-encoding)
- Uses exponential backoff (up to 5 retries) for rate-limited requests

### `github-enable-issues`
- Enables the Issues feature on every repo in an org that has it disabled
- Accepts `--dry-run` flag
- Skips archived repos and repos already with issues enabled
- Uses `sleep 0.5` between patch operations
- Reports four counters: enabled, errors, already-on, archived

### `github-get-consumed-licenses`
- Queries enterprise seat license consumption
- Uses **Bearer token** authentication; requires `read:enterprise` token scope
- Calls `/enterprises/{ENTERPRISE}/consumed-licenses` endpoint
- Outputs two metrics: seats consumed and seats purchased

### `github-get-public-repos`
- Lists all public repos across every org in a GitHub Enterprise; writes a timestamped CSV
- Variables: `ENTERPRISE` (or `ORGS` override), optional `ORG_FILTER` / `ORG_EXCLUDE`
- Fetches all repos per org and filters by `visibility == "public"` in jq (avoids unreliable `?type=public` param)
- Uses exponential backoff for rate-limited requests
- Generates `public_repos_${TIMESTAMP}.csv` in `REPORT_DIR` (default: `./reports`)

### `github-get-repo-list`
- Generates a CSV of all repos in an org with full metadata
- Writes `repo-list.csv` (relative to working directory)
- Makes an extra individual API call per repo to fetch full details — slow on large orgs

### `github-import-repo`
- Imports a repo from one org to another using **bare clone + mirror push** (preserves full history)
- Takes 2 positional args: `$1=SRC_REPO`, `$2=DEST_REPO`
- Variables: `ORG` (destination), `OWNER_USERNAME` (granted admin on new repo)
- Creates destination repo with `visibility: internal`
- Uses `mktemp -d` for working directory; cleans up after push
- Accepts HTTP 201 (created) or 422 (already exists) as success
- Requires `git` in PATH

### `github-migrate-internal-repos-to-private`
- Converts all internal repos in an org to private visibility
- Queries only `?type=internal` repos; sends `visibility: private` PATCH to each
- No rate-limit delay between updates

### `github-monthly-issues-report`
- Generates an HTML report of issues created during a specified month
- Variables: `ORG`, `REPO`, `MONTH_START`, `MONTH_END` (ISO format `YYYY-MM-DD`)
- **Hardcoded label filter:** `Linked%20[AC]` (URL-encoded `Linked [AC]`)
- Uses timeline API (`mockingbird-preview` header) to track who applied labels
- Output: `output.txt` (HTML, appended); temp file `test.json` (cleaned up)
- Aggregates and sorts issue authors and label contributors by count (descending)

### `github-organize-stars`
- Fetches all starred repos and organizes them into GitHub Lists by category rules
- **Uses `gh` CLI** for authentication (not `GITHUB_TOKEN` env var)
- Accepts flags: `--dry-run`, `-y`/`--yes`, `--show-repos`, `--no-cache`
- Categorization via ordered rules (language, topics, name keywords); first match wins
- Caches stars in `~/.cache/gh-star-organizer/stars.json`; batch-adds repos in groups of 25
- Requires `gh` (GitHub CLI) and `jq`

### `github-repo-from-template`
- Creates a new repo from a template, sets team permissions, and auto-accepts the CD user invite
- Variables: `ORG`, `TEMPLATE_REPO`, `CD_USERNAME`, `CD_GITHUB_TOKEN`; positional arg: `REPO_NAME`
- `REPO_ADMIN` and `REPO_WRITE` are **space-separated lists** of team slugs
- Uses `baptiste-preview` Accept header for template generation API
- Creates repo with `private: true` and `include_all_branches: true`
- **Dual-token workflow:** Main token for creation; `CD_GITHUB_TOKEN` for auto-accepting invite
- Polls `/user/repository_invitations` up to 12 times (60-second timeout) to find the invitation
- Uses `sleep 5` between team permission assignments

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
- Several scripts support `--dry-run` — use it; others have no dry-run mode so handle with care
- Use `2>&1 | tee execution.log` to capture output for auditing

### Variable Naming Conventions
- `GITHUB_TOKEN` — main admin token
- `ORG` — organization name
- `ENTERPRISE` — enterprise account slug (from enterprise URL)
- `ENTERPRISE_TEAM_SLUG` — enterprise team slug (without "ent:" prefix)
- `REPO` — single repository name
- `TEMPLATE_REPO` — source template repository
- `CD_USERNAME` / `CD_GITHUB_TOKEN` — automation/CI user credentials
- `MONTH_START` / `MONTH_END` — ISO date format `YYYY-MM-DD`
- `ORGS` — comma-separated org list (overrides enterprise lookup)
- `ORG_FILTER` / `ORG_EXCLUDE` — ERE regex for org name filtering
- `REPORT_DIR` — output directory for report files (default: `./reports`)

### Dependencies
- **bash 4+** (for modern features)
- **curl** (API requests — all scripts)
- **jq** (JSON parsing — all scripts)
- **git** (`github-import-repo` only)
- **gh** (GitHub CLI — `github-organize-stars` only)
- **base64** (`github-auto-repo-creation`, `github-dockerfile-discovery`)
- **python3** (`github-dockerfile-discovery` — URL-encoding)
- **date** (`github-archive-old-repos` — BSD/GNU compatible)

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
