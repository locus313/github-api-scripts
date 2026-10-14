# Script-Specific Behaviors

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

Uses GitHub code-search API to find Dockerfiles across all enterprise orgs, then fetches and parses each file to extract `FROM` instructions (including multi-stage builds). Produces three timestamped reports in `REPORT_DIR`: a detail CSV, a summary CSV, and a plain-text summary. Supports `ORGS` override, `ORG_FILTER`/`ORG_EXCLUDE` regex filters (validated as syntactically correct ERE before use), and configurable sleep intervals (`SEARCH_SLEEP`, `CONTENT_SLEEP`). Both `gh_api` call sites handle sentinels: `__422__` or `__404__` on the code-search endpoint skips that org with a warning; `__404__` or `__422__` on the file-contents endpoint skips that individual file.

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

Uses `gh` CLI GraphQL (not `curl`) to fetch all starred repos. Accepts `GITHUB_TOKEN` env var or an active `gh` auth session for authentication. Categorizes by primary language, GitHub topics, and name keywords using a `RULES` array (pipe-delimited: `List Name|LANGUAGES|TOPICS|NAME_KEYWORDS`; first matching rule wins). Caches stars at `~/.cache/gh-star-organizer/stars.json`. Supports `--dry-run`, `-y` (skip confirm), `--show-repos`, and `--no-cache`. Adds repos to Lists in batches of 25.

### `github-repo-from-template`

Creates a private repo from `TEMPLATE_REPO` (including all branches), assigns admin permissions to space-separated `REPO_ADMIN` teams, write permissions to `REPO_WRITE` teams, then invites `CD_USERNAME` as a collaborator using `CD_GITHUB_TOKEN` and auto-accepts the invitation. All slug values are validated before use.

### `github-repo-permissions-report`

Uses `curl` for all API calls. Accepts `GITHUB_TOKEN` env var or an active `gh` auth session (token auto-resolved at lib source time) for authentication. Accepts `-r OWNER/REPO`, `-b BRANCH`, and `-o FILE` flags. Outputs a CSV with two record types: `permission` (all users/teams) and `bypass_actor` (explicit PR approval bypass entries). Reports both branch protection rules and repository rulesets.

### `github-copilot-report`

Uses `curl` for all GitHub API calls. Accepts `GITHUB_TOKEN` env var (PAT with `read:enterprise` and `manage_billing:enterprise` scopes) or an active `gh` auth session (token auto-resolved at lib source time) for authentication. Also requires `az` to be **installed** when Entra ID enrichment is needed — `az` is checked at runtime only if `--no-entra` is not set and `az` is not already skipped. If `az` is not installed or not logged in, Entra lookup is silently skipped. When `az` is logged in, enriches each user with Entra ID department and job title via `az rest`.

Auto-detects credits per seat from a promo/standard table keyed on plan type and today's date (promo period Jun 1 – Sep 1, 2026); override with `--credits N` or `$CREDITS_PER_SEAT_OVERRIDE`. Credits are pooled enterprise-wide, not per-user buckets. Code completions are not billed in AI credits.

Uses API version `2026-03-10` and the new usage-metrics NDJSON endpoints (signed download links). The legacy `/copilot/metrics` and `/copilot/usage` endpoints were closed Apr 2, 2026.
