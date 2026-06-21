# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- `github-copilot-report`: NDJSON usage-metrics endpoints, Entra ID enrichment via `az rest`, auto-detection of credits per seat with promo/standard table, `--no-entra` flag
- README: GitHub Actions integration examples (workflow_dispatch, artifact upload, environment protection)
- `.github/workflows/update-readme-sha.yml` — automatically updates the pinned commit SHA in README.md on every push to `main`

### Changed
- README: updated all `actions/checkout` references from `v4` to `v7.0.0` (pinned SHA `9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0`)
- README: replaced `ref: main` in the GitHub Actions usage example with a pinned commit SHA, and updated the accompanying note to recommend SHA pinning

---

## [2026-06-21]

### Added
- `github-copilot-report`: NDJSON usage-metrics endpoints, Entra ID enrichment via `az rest`, auto-detection of credits per seat with promo/standard table, `--no-entra` flag
- README: GitHub Actions integration examples (workflow_dispatch, artifact upload, environment protection)

### Changed
- Validated all required environment variables across all scripts before any API calls
- Improved error handling with descriptive exit messages throughout

---

## [2026-06-20]

### Added
- `github-add-repo-permissions`: `REPO_NAME_FILTER` option to restrict permission grants to repos matching a name prefix

### Changed
- Enhanced validation for user-supplied inputs (slugs, regex patterns, date formats) across multiple scripts
- Improved payload handling and JSON construction in enterprise scripts

---

## [2026-06-19]

### Added
- `github-copilot-report` — Copilot usage report with per-user seat data, AI credit calculations, and optional Entra ID department/job-title enrichment
- `github-repo-permissions-report` — CSV report of all user/team permissions and branch-protection bypass actors for a given repo and branch; uses `gh` CLI
- `.githooks/pre-commit` — secret scanning (gitleaks or built-in regex) + shellcheck on staged `.sh` files
- `install-hooks.sh` — one-command hook installer (`git config core.hooksPath .githooks`)

### Changed
- Standardized all scripts to the `# ===` 79-char header block with full env-var and requirements documentation
- Added `--dry-run` flag documentation to `github-close-archived-repo-security-alerts` and `github-enable-issues`

---

## [2026-06-18]

### Added
- `lib/github-common.sh` — shared utility library: `print_status/success/warning/error`, `require_env_var`, `require_command`, `validate_github_token`, `validate_token`, `validate_slug`, `gh_api` (Bearer auth + 5-retry rate-limit handling), `get_repo_page_count`, `get_enterprise_orgs` (three-tier fallback)
- `github-enable-issues` — enables GitHub Issues on all repos in an org that have it disabled; supports `--dry-run`
- `github-get-repo-list` — exports a CSV of all repos in an org (visibility, URL, timestamps)
- `github-get-public-repos` — discovers all public repos across all enterprise orgs; writes timestamped CSV
- `github-migrate-internal-repos-to-private` — bulk-converts internal repos to private via PATCH
- `github-archive-old-repos` — archives repos not pushed to in N years; generates CSV report; prompts for confirmation
- `github-auto-repo-creation` — creates private repos with branch protection, CODEOWNERS, and admin team grants
- `github-close-archived-repo-security-alerts` — dismisses open Dependabot, code-scanning, and secret-scanning alerts on archived repos; supports `--type` and `--dry-run`
- `github-add-enterprise-team-read-permissions` — grants `all_repo_read` org role to an enterprise team across all enterprise orgs via GraphQL pagination
- `github-dockerfile-discovery` — code-searches all enterprise orgs for Dockerfiles, extracts `FROM` instructions, produces detail + summary CSVs
- Reorganized all scripts into domain subdirectories: `org-admin/`, `enterprise/`, `reporting/`, `personal/`
- `.github` instructions and agent profiles for Copilot

### Changed
- All scripts refactored to source `lib/github-common.sh` for shared validation and output helpers
- `github-repo-from-template`: added `CD_GITHUB_TOKEN` auto-accept collaborator invitation flow
- `github-add-repo-collaborators-by-pattern` (formerly `github-add-repo-admin`): expanded to support `REPO_EXCLUDE_REGEX` and comma-separated `COLLABORATORS`
- README: comprehensive rewrite with per-script env var tables, usage examples, and GitHub Actions integration guide

---

## [2026-03-12]

### Added
- `github-organize-stars` — fetches all starred repos via `gh` CLI GraphQL, categorizes by language/topic/name-keyword rules, and adds repos to GitHub Lists in batches of 25; supports `--dry-run`, `-y`, `--show-repos`, `--no-cache`

---

## [2025-10-31]

### Added
- `github-add-repo-permissions` — grants configurable team permissions (`admin`, `maintain`, `push`, `triage`, `pull`) across all repos in an org
- `.github/copilot-instructions.md` — initial AI agent instructions with architecture overview, API patterns, script-specific behaviors, and common pitfalls

### Changed
- Standardized shebang to `#!/bin/bash` and improved `GITHUB_TOKEN` validation across all scripts
- Enhanced error messages for missing environment variables
- Improved output formatting and readability

---

## [2025-03-26]

### Added
- `github-get-consumed-licenses` — calls the enterprise consumed-licenses endpoint to return seat consumption and purchase counts

---

## [2024-09-02]

### Changed
- `github-repo-from-template`: improved handling of template repo options and team permission assignment

---

## [2021-07-09]

### Added
- `github-add-repo-admin` (later renamed `github-add-repo-collaborators-by-pattern`) — adds collaborators to repos matching a name pattern

---

## [2021-07-04] — Initial release

### Added
- `github-import-repo` — bare-clones a source repo and mirror-pushes to a new private destination repo
- `github-repo-from-template` — creates a private repo from a template, assigns admin teams, and invites a CD user
- `github-monthly-issues-report` — generates an HTML report of issues created in a date range with label/timeline tracking
- README with project overview and installation instructions

