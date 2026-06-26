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

All scripts **must** begin with a `# ===` header block, followed immediately by
`set -euo pipefail`. Fill in the script name, description, usage, every
environment variable the script reads (Required/Optional), and every external
command it depends on.

```bash
#!/usr/bin/env bash
# =============================================================================
# github-<script-name>.sh
#
# <One-paragraph description of what this script does.>
#
# Usage:
#   export GITHUB_TOKEN=ghp_yourtoken
#   export ORG=my-org
#   ./github-<script-name>.sh [options]
#
# Options:                         (omit this section if there are no CLI flags)
#   --dry-run    Preview changes without making them
#
# Environment variables:
#   GITHUB_TOKEN    Required. PAT with <scope> scope
#   ORG             Required. GitHub organization name
#   API_URL_PREFIX  Optional. GitHub API base URL (default: https://api.github.com)
#
# Requirements:
#   - curl
#   - jq
# =============================================================================

set -euo pipefail                # ALWAYS include: exit on error, undefined vars, pipe failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/github-common.sh
source "${SCRIPT_DIR}/../../lib/github-common.sh"

### GLOBAL VARIABLES
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
# Script-specific required vars...

# Token validation block
# Helper functions for pagination/processing
# Main execution logic
```

**Rules:**
- The `# ===` fence is exactly 79 characters.
- Do **not** add a second `###` description block inside the body — all descriptive content belongs in the top header.
- `set -euo pipefail` must be the first executable line after the header.

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
- **Repo-level operations** (permission grants, archival): `sleep 5` between each repository.
- **Code search** (`github-dockerfile-discovery`): configurable via `SEARCH_SLEEP` (default 2 s) and `CONTENT_SLEEP` (default 1 s).
- **gh_api helper** (lib): auto-retries up to 5 times on HTTP 403/429, sleeping 60 s before each retry.

### Authentication Headers

- **Standard org/repo REST endpoints**: `Authorization: token ${GITHUB_TOKEN}`
- **Enterprise endpoints and GraphQL**: `Authorization: Bearer ${GITHUB_TOKEN}`
- **`gh_api` helper** (lib): always uses `Bearer`; pass `"bearer"` to `validate_github_token` for enterprise-level scripts.
- **`validate_github_token`** wrapper: call without arguments for token auth, or pass `"bearer"` for Bearer auth.

### Accept Headers (Media Types)

Different endpoints require specific Accept headers:
- **Standard REST**: `Accept: application/vnd.github+json` (used by `gh_api` helper and newer scripts)
- **Legacy REST** (older scripts): `Accept: application/vnd.github.v3+json`
- **GraphQL**: no Accept header required; POST to `/graphql` with `Content-Type: application/json`
- **All modern API calls**: include `X-GitHub-Api-Version: 2022-11-28` (or `2026-03-10` for Copilot usage-metrics endpoints)

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

Uses GraphQL cursor-based pagination to enumerate all enterprise orgs, then assigns the `all_repo_read` org role (configurable via `ALL_REPO_READ_ROLE_NAME`) to the enterprise team in each org. Requires Bearer token authentication with `admin:enterprise` scope. The `ENTERPRISE_TEAM_SLUG` is the slug without the `"ent:"` prefix.

### `github-add-repo-collaborators-by-pattern`

Adds individual collaborators to org repos whose names match `REPO_NAME_REGEX` (ERE). Accepts a comma-separated `COLLABORATORS` list and an optional `REPO_EXCLUDE_REGEX` to skip matching repos. Uses `token` auth for all REST calls. Iterates all org repos paginated at 100 per page.

### `github-add-repo-permissions`

Grants team permissions across all repos in an org. Reads five space-separated team-slug lists (`REPO_ADMIN`, `REPO_MAINTAIN`, `REPO_PUSH`, `REPO_TRIAGE`, `REPO_PULL`). Optionally filters repos by name prefix via `REPO_NAME_FILTER`. Sleeps 5 s between each repo to stay within rate limits. Uses legacy `Accept: application/vnd.github.v3+json` and `token` auth.

### `github-archive-old-repos`

Calculates a cutoff date based on `YEARS_THRESHOLD` (default 5). Generates a timestamped CSV report under `reports/`, shows the top 10 oldest repos, and prompts for confirmation before archiving. Handles both BSD (`date -v`, macOS) and GNU (`date -d`, Linux) date syntax for cross-platform compatibility.

### `github-auto-repo-creation`

Creates private repos from a comma-separated `REPO_NAMES` list. Configures branch protection on the default branch, creates a CODEOWNERS file (Base64-encoded via API), and grants admin access to comma-separated `ADMIN_TEAMS`. All slug values in `REPO_NAMES`, `ADMIN_TEAMS`, and `REPO_OWNERS` are validated before use. Requires `base64` in addition to `curl` and `jq`.

### `github-close-archived-repo-security-alerts`

Dismisses open Dependabot, code-scanning, and secret-scanning alerts on all archived repos. Supports `--type` to target a single alert type and `--dry-run` to preview without changes. Generates a timestamped CSV report under `reports/`. Requires a token with `security_events` and `repo` scopes.

### `github-dockerfile-discovery`

Uses GitHub code-search API to find Dockerfiles across all enterprise orgs, then fetches and parses each file to extract `FROM` instructions (including multi-stage builds). Produces three timestamped reports in `REPORT_DIR`: a detail CSV, a summary CSV, and a plain-text summary. Supports `ORGS` override, `ORG_FILTER`/`ORG_EXCLUDE` regex filters (validated as syntactically correct ERE before use), and configurable sleep intervals (`SEARCH_SLEEP`, `CONTENT_SLEEP`).

### `github-enable-issues`

Iterates all non-archived repos in an org and enables the Issues feature on any repo where it is disabled. Supports `--dry-run` to list affected repos without making changes.

### `github-get-consumed-licenses`

Calls the enterprise consumed-licenses endpoint using Bearer authentication. Requires `read:enterprise` scope. Returns seat consumption and purchase counts. Token-only script; no pagination or retry logic beyond what the single API call provides.

### `github-get-public-repos`

Discovers all enterprise orgs (three-tier fallback via `get_enterprise_orgs`), fetches all repos in each, and filters to public visibility in `jq` (does not rely on `?type=public` query param, which is unreliable for enterprise-managed orgs). Writes a timestamped CSV to `REPORT_DIR`. Supports `ORGS` override and `ORG_FILTER`/`ORG_EXCLUDE` ERE regex filters.

### `github-get-repo-list`

Outputs a CSV row per repository (full name, owner, visibility, URL, description, fork flag, pushed/created/updated timestamps) to stdout. Pagination handled at 100 repos per page via `get_repo_page_count`.

### `github-import-repo`

Performs a full bare clone (`git clone --mirror`) of a source repo and pushes all branches, tags, and history to a new private destination repo. Validates `GIT_URL_PREFIX` against a GitHub-host allowlist before running any git operations to prevent credential leakage. Repo names and `OWNER_USERNAME` are validated as slugs.

### `github-migrate-internal-repos-to-private`

Fetches all repos with internal visibility (paginated) and converts each to private via PATCH. Logs success or failure per repo. This operation cannot be undone via the API — converting internal to private removes access from members of other enterprise orgs.

### `github-monthly-issues-report`

Generates an HTML report of issues created in a date range (`MONTH_START`/`MONTH_END`), filtered by a hardcoded label (`Linked [AC]` — edit the script to change). Uses the timeline API to track who applied labels. URL-encodes labels for API calls (e.g., `Linked [AC]` → `Linked%20[AC]`). Outputs to `output.txt`.

### `github-organize-stars`

Uses `gh` CLI GraphQL (not `curl`) to fetch all starred repos. Categorizes by primary language, GitHub topics, and name keywords using a `RULES` array (pipe-delimited: `List Name|LANGUAGES|TOPICS|NAME_KEYWORDS`; first matching rule wins). Caches stars at `~/.cache/gh-star-organizer/stars.json`. Supports `--dry-run`, `-y` (skip confirm), `--show-repos`, and `--no-cache`. Adds repos to Lists in batches of 25.

### `github-repo-from-template`

Creates a private repo from `TEMPLATE_REPO` (including all branches), assigns admin permissions to space-separated `REPO_ADMIN` teams, write permissions to `REPO_WRITE` teams, then invites `CD_USERNAME` as a collaborator using `CD_GITHUB_TOKEN` and auto-accepts the invitation. All slug values are validated before use.

### `github-repo-permissions-report`

Uses `gh` CLI (not `curl`/`GITHUB_TOKEN`) for all API calls. Accepts `-r OWNER/REPO`, `-b BRANCH`, and `-o FILE` flags. Outputs a CSV with two record types: `permission` (all users/teams) and `bypass_actor` (explicit PR approval bypass entries). Reports both branch protection rules and repository rulesets. Requires `gh auth login` before running — no `GITHUB_TOKEN` env var needed.

### `github-copilot-report`

Uses `gh` CLI (not `curl`/`GITHUB_TOKEN`) for all GitHub API calls; requires `gh auth refresh --scopes "read:enterprise,manage_billing:enterprise"`. Also requires `az` to be **installed** (not just logged in) — the script calls `require_command az` unconditionally before checking `--no-entra`. When `az` is logged in, enriches each user with Entra ID department and job title via `az rest`.

Auto-detects credits per seat from a promo/standard table keyed on plan type and today's date (promo period Jun 1 – Sep 1, 2026); override with `--credits N` or `$CREDITS_PER_SEAT_OVERRIDE`. Credits are pooled enterprise-wide, not per-user buckets. Code completions are not billed in AI credits.

Uses API version `2026-03-10` and the new usage-metrics NDJSON endpoints (signed download links). The legacy `/copilot/metrics` and `/copilot/usage` endpoints were closed Apr 2, 2026.

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

## Maintenance Matrix

When you change one of these files, you must also update the files in the "Also update" column.

| When you change… | Also update |
|------------------|-------------|
| `lib/github-common.sh` — any public function signature or behaviour | All 19 scripts that source it; verify each caller still passes the right arguments. Check with: `grep -r "source.*github-common" . --include="*.sh"` |
| `lib/github-common.sh` — add a new helper function | `AGENTS.md` shared library table; `README.md` if the function affects usage |
| Any script's required env vars | That script's `# ===` header comment; the corresponding README.md section's env var table |
| Any script's optional env vars or defaults | Same as above |
| Any script's `--dry-run` or CLI flag behaviour | README.md usage example for that script |
| `README.md` — script documentation | Verify the script's `# ===` header comment still matches (env vars, options, requirements) |
| `.githooks/pre-commit` | `install-hooks.sh` if hook path or installation instructions change; README.md Best Practices section |
| `install-hooks.sh` | README.md Installation section |
| Add a new script | `README.md` (add use case, env var table, usage example); `CHANGELOG.md` under `[Unreleased]` |
| Add a new domain folder | `README.md` top-level structure description; `AGENTS.md` Repository Structure section |
| `.github/workflows/ci.yml` — shellcheck flags | `.githooks/pre-commit` shellcheck invocation (keep them in sync) |
| `.github/workflows/copilot-setup-steps.yml` — tool versions | `AGENTS.md` Tech Stack table |
| `AGENTS.md` | No cascade — but keep in sync with `copilot-instructions.md` if architecture changes |
