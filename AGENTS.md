# GitHub API Scripts — Agent Guide

## Project Overview

A collection of **standalone bash automation scripts** for GitHub organization and enterprise administration. Each script is a self-contained, self-validating CLI utility that interacts with the GitHub REST and GraphQL APIs using `curl` + `jq`. A shared utility library (`lib/github-common.sh`) provides common validation, output, and API helpers.

**Key principle:** Scripts are independent — they are never imported or called by each other. Every script manages its own validation, error handling, and environment variable requirements.

---

## Repository Structure

```
github-api-scripts/
├── lib/
│   └── github-common.sh          # Shared helpers (source this, never execute directly)
├── org-admin/                    # Organization-level administration scripts
│   └── github-<name>/
│       └── github-<name>.sh
├── enterprise/                   # Enterprise-level scripts
│   └── github-<name>/
│       └── github-<name>.sh
├── reporting/                    # Reporting and audit scripts
│   └── github-<name>/
│       └── github-<name>.sh
├── personal/                     # Personal GitHub utility scripts
│   └── github-<name>/
│       └── github-<name>.sh
├── .githooks/
│   └── pre-commit                # Secret scanning (gitleaks) + shellcheck
├── .github/
│   ├── copilot-instructions.md   # Detailed AI agent conventions
│   ├── agents/                   # Custom agent profiles
│   ├── skills/                   # Custom skills
│   └── instructions/             # Path-scoped instruction files
├── install-hooks.sh              # Installs .githooks/pre-commit via git config
├── LICENSE                       # MIT
└── README.md                     # Full script documentation with usage examples
```

---

## Tech Stack

| Tool | Role |
|------|------|
| bash 4+ | All scripts |
| curl | GitHub REST and GraphQL API calls |
| jq | JSON parsing and transformation |
| gh CLI | Used in `github-organize-stars` and `github-repo-permissions-report` |
| base64 | Used in `github-auto-repo-creation` for CODEOWNERS encoding |
| git | Used in `github-import-repo` for bare clone + mirror push |
| shellcheck | Linting (pre-commit hook + CI) |
| gitleaks | Secret scanning (pre-commit hook) |

---

## Build & Run

There is no build step. Scripts run directly:

```bash
# Install the pre-commit hook (one-time setup)
./install-hooks.sh

# Run any script directly after exporting required env vars
export GITHUB_TOKEN=ghp_yourtoken
export ORG=my-org
./org-admin/github-get-repo-list/github-get-repo-list.sh
```

**Lint all scripts:**
```bash
find . -name "*.sh" | xargs shellcheck --severity=warning --exclude=SC2034,SC1091 --shell=bash
```

---

## Testing

There is no automated test suite. The validation approach is:

1. **Pre-commit hook** — shellcheck on every staged `.sh` file; gitleaks secret scan
2. **Dry-run flags** — several scripts support `--dry-run` to preview changes without applying them:
   - `github-close-archived-repo-security-alerts`
   - `github-enable-issues`
   - `github-organize-stars`
3. **Test org first** — always run against a non-production GitHub org before production

---

## Key Patterns and Conventions

### Script anatomy

Every script begins with a `# ===` header (exactly 79 `=` chars), then immediately `set -euo pipefail`:

```bash
#!/usr/bin/env bash
# =============================================================================
# github-<name>.sh
#
# <description>
#
# Usage:
#   export GITHUB_TOKEN=ghp_yourtoken
#   export ORG=my-org
#   ./github-<name>.sh
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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/github-common.sh
source "${SCRIPT_DIR}/../../lib/github-common.sh"
```

### Sourcing the shared library

Always use `SCRIPT_DIR` to build the path to `lib/github-common.sh`. The library is two directory levels up from any script (`../../lib/github-common.sh`). Never hardcode absolute paths.

### Authentication

- Standard org/repo REST calls: `Authorization: token ${GITHUB_TOKEN}`
- Enterprise endpoints and GraphQL: `Authorization: Bearer ${GITHUB_TOKEN}`
- The `gh_api` helper in `lib/github-common.sh` always uses Bearer; pass `"bearer"` to `validate_github_token` for enterprise scripts

### Shared library helpers

| Function | Purpose |
|----------|---------|
| `print_status` / `print_success` / `print_warning` / `print_error` | Colored output |
| `require_env_var <VAR>` | Exit with message if variable unset/empty |
| `require_command <cmd>` | Exit if binary not in PATH |
| `validate_github_token [bearer]` | Verify GITHUB_TOKEN via /user endpoint |
| `validate_slug <value> <label>` | Reject values with non-alphanumeric/hyphen/underscore chars |
| `gh_api <path> [curl args...]` | Bearer-auth REST helper with 5-retry rate-limit handling |
| `get_enterprise_orgs` | Three-tier enterprise org resolver (REST → GraphQL → /user/orgs) |
| `get_repo_page_count <url>` | Returns total pages for a paginated endpoint |

### Error handling sequence

1. `require_env_var` all required variables
2. `validate_github_token` (or `validate_token` for secondary tokens)
3. Validate additional inputs with `validate_slug` where needed
4. Proceed with main logic

### Pagination (REST)

```bash
for PAGE in $(seq "$(get_repo_page_count "${API_URL_PREFIX}/orgs/${ORG}/repos?per_page=100")"); do
  # process page
done
```

### Rate limiting

- Repo-level operations (permission grants, archival): `sleep 5` between each repo
- Code search: configurable `SEARCH_SLEEP` (default 2s) and `CONTENT_SLEEP` (default 1s)
- `gh_api` auto-retries on HTTP 403/429 with 60s sleep

---

## Adding a New Script

1. **Create the directory:** `<domain>/github-<verb-noun>/`
2. **Create the script:** `github-<verb-noun>.sh` (name must match the directory)
3. **Copy the header template** from Script Anatomy above — fill in description, all env vars, requirements
4. **Source the shared library** using `SCRIPT_DIR`
5. **Validate all inputs** before any API calls
6. **Add to README.md** — follow the existing format: use case, env var table, usage example, output format
7. Place in the correct domain:
   - `org-admin/` — organization-level operations (repos, teams, members)
   - `enterprise/` — enterprise-level operations (licenses, org enumeration)
   - `reporting/` — read-only reports and audits
   - `personal/` — personal GitHub utilities (stars, profile)

---

## CI/CD

- **Pre-commit hook:** `.githooks/pre-commit` — runs gitleaks + shellcheck on staged `.sh` files
- **Install:** `./install-hooks.sh` or `git config core.hooksPath .githooks`
- **Bypass (emergency only):** `git commit --no-verify`
- **CI:** shellcheck runs on all `.sh` files on every PR (`.github/workflows/ci.yml`)

---

## Common Pitfalls

- **Team slugs vs names:** API uses slugs (lowercase, hyphenated). "Platform Team" → `platform-team`
- **Bearer vs token auth:** Enterprise endpoints need `Bearer`; standard org/repo endpoints use `token`
- **Space-separated lists:** `REPO_ADMIN` and similar accept multiple space-separated values — loop with `for item in ${VAR}`
- **Comma-separated lists:** `COLLABORATORS`, `REPO_NAMES`, `ORGS` use commas — split with `IFS=','`
- **URL encoding:** Labels in API calls must be URL-encoded (e.g., `Linked [AC]` → `Linked%20[AC]`)
- **Public repo filtering:** Do not rely on `?type=public` for enterprise-managed orgs — fetch all and filter in `jq`
- **macOS vs Linux date:** `github-archive-old-repos.sh` handles both BSD `date -v` and GNU `date -d`
- **`set -euo pipefail`:** Must be the first executable line after the header — never omit it
