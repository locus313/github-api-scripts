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

| Function | Purpose |
|----------|---------|
| `print_status` / `print_success` / `print_warning` / `print_error` | Colored output |
| `err <message>` | `print_error` + `exit 1` in one call |
| `require_env_var <VAR>` | Exit with message if variable unset/empty |
| `require_command <cmd>` | Exit if binary not in PATH |
| `configure_gh_auth [scope_hint]` | Bridge GITHUB_TOKEN→GH_TOKEN or verify gh auth session |
| `validate_github_token [bearer]` | Verify GITHUB_TOKEN via /user endpoint |
| `validate_slug <value> <label>` | Reject values with non-alphanumeric/hyphen/underscore chars |
| `is_bsd_date` | Returns 0 if `date` is BSD-style (macOS), 1 for GNU (Linux); branch between `date -v` and `date -d` syntax |
| `csv_escape <value>` | Doubles embedded double-quotes for a quoted CSV field |
| `gh_api <path> [--api-version V] [curl args...]` | Bearer-auth REST helper with 5-retry rate-limit handling; optional `--api-version` overrides the default `2022-11-28` header; returns literal `__404__` or `__422__` for those HTTP statuses — callers must check for these sentinels |
| `gh_api_paginate <path> [filter] [version]` | Paginated REST helper, follows Link headers, streams items; returns silently with empty output on 404/422 |
| `get_enterprise_orgs` | Three-tier enterprise org resolver (REST → GraphQL → /user/orgs) |
| `get_repo_page_count <url>` | Returns total pages for a paginated endpoint |

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
for PAGE in $(seq "$(get_repo_page_count "${API_URL_PREFIX}/orgs/${ORG}/repos?per_page=100")"); do
  # Process repos on this page with per_page=100
done
```

For enterprise-level org iteration (GraphQL), use cursor-based pagination — see `github-add-enterprise-team-read-permissions.sh` and `github-dockerfile-discovery.sh` for examples.

### Rate Limiting

Rate limiting delays are calibrated per operation type:
- **Repo-level operations** (permission grants, archival): `sleep 5` between each repository.
- **Code search** (`github-dockerfile-discovery`): configurable via `SEARCH_SLEEP` (default 2 s) and `CONTENT_SLEEP` (default 1 s).
- **gh_api helper** (lib): auto-retries up to 5 times on HTTP 403/429, sleeping 60 s before each retry. Pass `--api-version VERSION` immediately after the URL to override the default `2022-11-28` header. Returns the literal string `__404__` or `__422__` (exit 0) for those HTTP statuses instead of failing — every caller must check for these sentinels before passing the result to `jq`. `gh_api_paginate` returns silently with empty output on 404/422.

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

Per-script quirks (auth style, pagination, sentinels, reports) live in [`docs/script-behaviors.md`](../docs/script-behaviors.md). Read the matching section before changing an existing script.

## Development Guidelines

### Adding New Scripts
1. Create directory `<domain>/github-<action-verb-object>/` with `mkdir -p` in its own bash call, before any `create` call (the `create` tool needs an existing parent)
2. Create script: `github-<action-verb-object>.sh` (match directory name); add a section to `docs/script-behaviors.md`. `tests/test_repo_structure.bats` fails until every checklist item below exists
3. Source `lib/github-common.sh` for validation and output helpers
4. Start with the standard boilerplate (see Script Anatomy above)
5. Create `action.yml` in the same directory — expose every env var as a named input (required inputs without defaults, optional inputs with sensible defaults); map CLI flags such as `--dry-run` and `--type` to boolean/string inputs and build an `ARGS` array in the `run:` step. Mirror the pattern of any existing `action.yml`.
6. **Add tests to `tests/test_script_validation.bats`** — mandatory. Add a labelled section with tests for every required env var missing (exit 1), unknown CLI args (exit 1), `--help` exits 0, and script-specific validation guards. See existing sections for the pattern.
7. Document in README.md following existing format:
   - Use case description
   - Required variables table
   - Usage example with exports
   - Output format (if applicable)
   - Add a row to the Available Actions table in the "Using Scripts in GitHub Actions" section

### Testing Approach

The project has a bats unit-test suite in `tests/`. Run the full suite with:

```bash
bats tests/
```

| File | What it covers |
|------|----------------|
| `tests/test_common.bats` | `lib/github-common.sh` pure-logic functions and API helpers |
| `tests/test_script_validation.bats` | Every script — missing env vars, invalid args, `--help`, script-specific guards |
| `tests/mock_curl.sh` | Universal curl mock used by both test files |

Every new script **must** include a test section in `tests/test_script_validation.bats` before it is merged. At minimum test: each required env var missing exits 1, unknown CLI args exit 1, and any enum or allowlist validation specific to the script.

Additional testing approaches:
- **Always test on a test organization first** before running against production
- **Dry-run flags** — several scripts support `--dry-run` to preview changes without applying them

### Commit Messages — Conventional Commits (required)

All commits **must** follow [Conventional Commits](https://www.conventionalcommits.org/). Release Please reads commit messages to auto-generate `CHANGELOG.md` and determine the version bump. Never update `CHANGELOG.md` manually.

| Prefix | Effect | Example |
|--------|--------|---------|
| `feat:` | minor bump | `feat: add REPO_NAME_FILTER to github-add-repo-permissions` |
| `fix:` | patch bump | `fix: make REPORT_DIR overridable in github-archive-old-repos` |
| `feat!:` / `BREAKING CHANGE:` | major bump | `feat!: rename ENTERPRISE_SLUG to ENTERPRISE` |
| `docs:` | patch bump (visible) | `docs: update GitHub Actions examples in README` |
| `chore:` | no bump (hidden) | `chore: update actions/checkout to v7` |
| `ci:` | no bump (hidden) | `ci: pin release-please-action SHA` |
| `refactor:` | patch | `refactor: extract pagination helper` |

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
10. **Never edit CHANGELOG.md manually** — it is fully managed by Release Please via Conventional Commits

## Maintenance Matrix

When you change one of these files, you must also update the files in the "Also update" column.

| When you change… | Also update |
|------------------|-------------|
| `lib/github-common.sh` — any public function signature or behaviour | All 18 scripts that source it; verify each caller still passes the right arguments. Check with: `grep -r "github-common" . --include="*.sh"` |
| `lib/github-common.sh` — add a new helper function | `AGENTS.md` shared library table; `README.md` if the function affects usage |
| `gh_api_paginate` signature or pagination behaviour | `github-repo-permissions-report.sh` (3 call sites), `github-copilot-report.sh` (`fetch_seats`) — both pipe output through `jq -s '.'` and depend on the `jq_filter`/`api_version` parameter order |
| Any script's required env vars | That script's `# ===` header comment; the corresponding README.md section's env var table; that script's `action.yml` inputs (add/remove required inputs to match) |
| Any script's optional env vars or defaults | Same as above; update the `action.yml` optional inputs and their defaults |
| Any script's `--dry-run` or CLI flag behaviour | README.md usage example for that script; that script's `action.yml` inputs and `run:` step flag construction |
| `README.md` — script documentation | Verify the script's `# ===` header comment still matches (env vars, options, requirements) |
| `.githooks/pre-commit` | `install-hooks.sh` if hook path or installation instructions change; README.md Best Practices section |
| `install-hooks.sh` | README.md Installation section |
| Add a new script | `tests/test_script_validation.bats`; `action.yml` in the same directory; `README.md` (use case, env var table, usage example, Available Actions row); `docs/script-behaviors.md`. `tests/test_repo_structure.bats` enforces the first four |
| Add a new domain folder | `README.md` top-level structure description; `AGENTS.md` Repository Structure section |
| `.github/workflows/ci.yml` — shellcheck flags | `.githooks/pre-commit` shellcheck invocation (keep them in sync) |
| `.github/workflows/copilot-setup-steps.yml` — tool versions | `AGENTS.md` Tech Stack table |
| `AGENTS.md` | No cascade — but keep in sync with `copilot-instructions.md` if architecture changes |
