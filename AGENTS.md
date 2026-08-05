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
| gh CLI | Used in `github-organize-stars` |
| base64 | Used in `github-auto-repo-creation` for CODEOWNERS encoding |
| git | Used in `github-import-repo` for bare clone + mirror push |
| shellcheck | Linting (pre-commit hook + CI) |
| gitleaks | Secret scanning (pre-commit hook) |
| Release Please | Automated releases and CHANGELOG generation (`.github/workflows/release.yml`) |

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

The project has a bats unit-test suite in `tests/`. **Every new script must ship with tests.**

```bash
# Run all tests
bats tests/

# Run a single file
bats tests/test_common.bats
```

### Test files

| File | What it covers |
|------|----------------|
| `tests/test_common.bats` | `lib/github-common.sh` — pure-logic functions (`validate_slug`, `require_env_var`, `require_command`, `err`, `configure_gh_auth`, `validate_token`, `get_repo_page_count`, `is_bsd_date`) and API helpers (`gh_api` sentinels, `gh_api_paginate`) |
| `tests/test_script_validation.bats` | Every script — missing required env vars exit 1, invalid CLI args exit 1, `--help` exits 0, script-specific enum/allowlist validation |
| `tests/mock_curl.sh` | Universal drop-in curl mock (used by both test files); response data via env vars `MOCK_CURL_CODE`, `MOCK_CURL_BODY`, `MOCK_CURL_LINK` |

### What to test for every new script

1. **Missing required env vars** — one `@test` per required variable, in the order the script checks them. Each test asserts `status -eq 1`.
2. **Invalid CLI args** — unknown flag exits 1 with an "Unknown" message.
3. **`--help` flag** — exits 0 (for scripts that implement it).
4. **Recognised flags** — `--dry-run` and other known flags do not trigger the unknown-arg error (test by asserting output does *not* contain "Unknown").
5. **Script-specific guards** — enum validation (`--type`, `DEPENDABOT_REASON`), URL allowlists (`GIT_URL_PREFIX`), required positional args.

### Mocking pattern

Tests shadow real binaries by prepending a `MOCK_BIN` directory to `PATH`:

```bash
setup() {
  MOCK_BIN="$(mktemp -d)"
  # Fail gh auth so GITHUB_TOKEN is never auto-resolved from a session
  printf '#!/bin/sh\nexit 1\n' > "$MOCK_BIN/gh"
  chmod +x "$MOCK_BIN/gh"
}

teardown() { rm -rf "$MOCK_BIN"; }

@test "my-script: exits 1 when GITHUB_TOKEN is not set" {
  run bash -c "export PATH='${MOCK_BIN}:${PATH}'; unset GITHUB_TOKEN; bash '${REPO_ROOT}/domain/my-script/my-script.sh'"
  [ "$status" -eq 1 ]
}
```

Use `_mock_curl_200` (defined in `test_script_validation.bats`) when a test must reach code that runs after `validate_github_token`.

### Dry-run flags and other testing approaches

- **`--dry-run`** — several scripts support it to preview changes without applying them.
- **Test org first** — always run against a non-production GitHub org before production.

---

## Key Patterns and Conventions

> The full reference for script anatomy, shared library helpers, authentication,
> pagination, and adding new scripts lives in
> [`.github/copilot-instructions.md`](.github/copilot-instructions.md).
> The sections below cover only what is unique to this guide.

---

## CI/CD

- **Pre-commit hook:** `.githooks/pre-commit` — runs gitleaks + shellcheck on staged `.sh` files
- **Install:** `./install-hooks.sh` or `git config core.hooksPath .githooks`
- **Bypass (emergency only):** `git commit --no-verify`
- **CI:** shellcheck + bats unit tests run together on every PR (`.github/workflows/ci.yml`)
- **Releases:** automated by Release Please (`.github/workflows/release.yml`) — pushes to `main` trigger a release PR; merging it publishes the GitHub Release and tag

## Commit Messages — Conventional Commits (required)

All commits **must** follow [Conventional Commits](https://www.conventionalcommits.org/). `CHANGELOG.md` is fully managed by Release Please and **must never be edited manually**.

| Prefix | Version bump | Visible in changelog |
|--------|-------------|----------------------|
| `feat:` | minor | ✅ Features |
| `fix:` | patch | ✅ Bug Fixes |
| `docs:` | patch | ✅ Documentation |
| `perf:` | patch | ✅ Performance Improvements |
| `revert:` | patch | ✅ Reverts |
| `feat!:` / `BREAKING CHANGE:` | major | ✅ |
| `chore:` | none | hidden |
| `ci:` | none | hidden |
| `refactor:` | patch | Code Refactoring |
| `test:` | none | hidden |

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
- **Never edit `CHANGELOG.md` manually** — it is fully managed by Release Please via Conventional Commits
