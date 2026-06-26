# GitHub API Scripts

[![AI Ready](https://img.shields.io/badge/AI--Ready-yes-brightgreen?style=flat)](https://github.com/johnpapa/ai-ready)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)
![Shell](https://img.shields.io/badge/Shell-Bash-89e051?style=flat-square&logo=gnu-bash&logoColor=white)
[![GitHub API](https://img.shields.io/badge/GitHub_API-v3-blue?style=flat-square&logo=github)](https://docs.github.com/en/rest)

⭐ If you like this project, star it on GitHub — it helps a lot!

[Overview](#overview) • [Getting started](#getting-started) • [Scripts](#scripts) • [Shared Library](#shared-library-libgithub-commonsh) • [GitHub Actions](#using-scripts-in-github-actions) • [Resources](#resources)

A collection of standalone bash scripts for GitHub organization administration. Automate common tasks like bulk permission management, repository creation, migration, and reporting using simple, self-contained utilities powered by the GitHub REST API.

## Overview

This toolkit provides ready-to-use automation scripts for GitHub organization administrators. Each script is a complete, independent utility that can be run directly or integrated into your GitHub Actions workflows.

**What you can do:**
- Grant team permissions across all repositories in bulk
- Create repositories from templates with pre-configured access
- Mirror repositories with full git history
- Generate monthly issue reports with contributor statistics
- Track license consumption for enterprise accounts
- Archive old repositories
- Discover Dockerfiles and base images across an enterprise
- Organize your starred repositories
- And much more!

**Architecture:** Scripts use a shared utility library (`lib/github-common.sh`) for common validation, error handling, and API helpers. Script directories are grouped by domain (`org-admin/`, `enterprise/`, `reporting/`, `personal/`) and each script remains a self-contained `.sh` utility.

**Built with simplicity:** All scripts use only `curl` for API requests and `jq` for JSON processing—no complex dependencies or installation required beyond standard Unix tools.

> [!NOTE]
> Scripts follow a convention-over-configuration approach with built-in validation and error handling. Each can be run standalone or integrated into CI/CD pipelines and GitHub Actions workflows.

## Getting started

### Prerequisites

- **bash** 4+
- **[curl](https://curl.se)** - HTTP client for API requests
- **[jq](https://stedolan.github.io/jq)** - Command-line JSON processor
- **[git](https://git-scm.com)** - For repository operations (required by some scripts)
- **[gh](https://cli.github.com)** - GitHub CLI (required by `github-organize-stars`)
- **GitHub Personal Access Token** with appropriate scopes

### Installation

Clone the repository:

```bash
git clone https://github.com/locus313/github-api-scripts.git
cd github-api-scripts
```

Alternatively, download individual scripts as needed—each script is standalone and can be used independently.

### Authentication

Create a GitHub Personal Access Token at [github.com/settings/tokens](https://github.com/settings/tokens) with these scopes:

- `repo` - Full control of repositories
- `admin:org` - Organization administration
- `read:enterprise` - Read enterprise data (for license scripts)

Export your token as an environment variable:

```bash
export GITHUB_TOKEN="ghp_your_token_here"
```

> [!TIP]
> Add this export to your `~/.bashrc` or `~/.zshrc` to persist the token across terminal sessions.

### Configuration

Scripts use environment variables for configuration. Common variables include:

| Variable | Description | Required |
|----------|-------------|----------|
| `GITHUB_TOKEN` | GitHub personal access token | Yes |
| `ORG` | Organization name | Yes (most scripts) |
| `API_URL_PREFIX` | GitHub API base URL (default: `https://api.github.com`) | No |
| `GIT_URL_PREFIX` | GitHub base URL (default: `https://github.com`). Must be a GitHub-family host (`github.com`, `*.github.com`, `*.ghe.com`, `*.githubenterprise.com`). | No |

> [!NOTE]
> The `*_PREFIX` variables support GitHub Enterprise Server. Set them to your enterprise domain to use these scripts with GHES.

### Pre-commit Hooks

The repository ships versioned pre-commit hooks in `.githooks/`. Run the installer once after cloning:

```bash
./install-hooks.sh
```

This sets `core.hooksPath` to `.githooks/` so Git picks up the hooks automatically on every commit.

**What the hook checks:**

| Check | Tool | Fallback |
|-------|------|----------|
| Secret scanning | [`gitleaks`](https://github.com/gitleaks/gitleaks) | Built-in regex patterns for GitHub tokens, AWS keys, private keys, and generic secrets |
| Shell script security | [`shellcheck`](https://www.shellcheck.net) | Skipped with a warning if not installed |

Install the recommended tools for full coverage:

```bash
brew install gitleaks shellcheck
```

> [!TIP]
> To bypass the hooks in an emergency: `git commit --no-verify`. Use sparingly — the hooks exist to prevent secrets from reaching the remote.

## Scripts

Each script is a self-contained utility designed for a specific task. Navigate to the script's directory, set the required environment variables, and execute.

### Folder Layout (Domain-Based)

- `org-admin/`: `github-add-repo-collaborators-by-pattern`, `github-add-repo-permissions`, `github-archive-old-repos`, `github-auto-repo-creation`, `github-close-archived-repo-security-alerts`, `github-enable-issues`, `github-get-repo-list`, `github-import-repo`, `github-migrate-internal-repos-to-private`, `github-repo-from-template`
- `enterprise/`: `github-add-enterprise-team-read-permissions`, `github-dockerfile-discovery`, `github-get-consumed-licenses`, `github-get-public-repos`, `github-install-enterprise-app`
- `reporting/`: `github-monthly-issues-report`, `github-repo-permissions-report`, `github-copilot-report`
- `personal/`: `github-organize-stars`

### Add Repository Permissions

**Script:** `org-admin/github-add-repo-permissions/github-add-repo-permissions.sh`

Grants team permissions across all repositories in an organization. Supports multiple permission levels (admin, maintain, push, triage, pull) and multiple teams per permission level.

**Required variables:**
```bash
export GITHUB_TOKEN="your_token"
export ORG="your-org"

# Set one or more permission levels (space-separated team slugs)
export REPO_ADMIN="platform-team ops-team"      # Admin permissions
export REPO_MAINTAIN="maintainers"              # Maintain permissions
export REPO_PUSH="developers contributors"      # Write/push permissions
export REPO_TRIAGE="support-team"               # Triage permissions
export REPO_PULL="external-auditors"            # Read/pull permissions

# Optional: restrict to repos whose names start with a given prefix
export REPO_NAME_FILTER="my-service-"
```

**Usage:**
```bash
cd org-admin/github-add-repo-permissions
./github-add-repo-permissions.sh
```

**What it does:**
- Retrieves all repositories in the organization (paginated)
- Filters to repositories whose names start with `REPO_NAME_FILTER` (all repos when unset)
- Grants permissions to specified teams based on permission level
- Supports multiple teams per permission level (space-separated)
- Processes all five GitHub permission levels: admin, maintain, push, triage, pull
- Includes 5-second delays between repos to avoid rate limits

**Permission levels:**
- `admin` - Full repository access including settings and team management
- `maintain` - Repository management without admin privileges
- `push` - Read and write access to code
- `triage` - Read access plus ability to manage issues and pull requests
- `pull` - Read-only access to code

> [!NOTE]
> At least one permission level must be set. Team slugs should be lowercase and hyphenated (e.g., "Platform Team" → `platform-team`).

---

### Create Repository from Template

**Script:** `org-admin/github-repo-from-template/github-repo-from-template.sh`

Creates a new repository from a template with pre-configured team permissions and collaborator access.

**Required variables:**
```bash
export GITHUB_TOKEN="your_token"
export ORG="your-org"
export TEMPLATE_REPO="template-repo"
export REPO_ADMIN="admins platform-team"     # Space-separated team slugs
export REPO_WRITE="developers contributors"  # Space-separated team slugs
export CD_USERNAME="ci-bot"
export CD_GITHUB_TOKEN="bot_token"
```

**Usage:**
```bash
cd org-admin/github-repo-from-template
./github-repo-from-template.sh new-project-name
```

**What it does:**
- Creates a private repository from the specified template
- Includes all branches from the template
- Assigns admin permissions to teams in `REPO_ADMIN`
- Assigns write permissions to teams in `REPO_WRITE`
- Invites CD user as collaborator and auto-accepts the invitation

> [!NOTE]
> `REPO_NAME` (CLI argument), `TEMPLATE_REPO`, `CD_USERNAME`, and all team slugs in `REPO_ADMIN` and `REPO_WRITE` are validated as slugs before use. Only alphanumeric characters, hyphens, and underscores are accepted.

---

### Import Repository

**Script:** `org-admin/github-import-repo/github-import-repo.sh`

Performs a full repository mirror—clones source repo and pushes all branches, tags, and history to a new destination repo.

**Required variables:**
```bash
export GITHUB_TOKEN="your_token"
export ORG="your-org"
export OWNER_USERNAME="admin-user"
```

**Usage:**
```bash
cd org-admin/github-import-repo
./github-import-repo.sh source-repo destination-repo
```

**What it does:**
- Creates a new internal repository
- Performs bare clone of source repository
- Mirrors all git objects to destination
- Grants admin permissions to specified owner
- Cleans up local temporary clone

> [!WARNING]
> This creates a complete copy with full git history. Ensure you have sufficient disk space and network bandwidth for large repositories.

> [!NOTE]
> `GIT_URL_PREFIX` is validated against a GitHub-host allowlist before any git operations run. Non-GitHub URLs are rejected to prevent credential leakage. Repository names and `OWNER_USERNAME` must be valid slugs (alphanumeric, hyphen, and underscore only).

---

### Add Repository Collaborators by Pattern

**Script:** `org-admin/github-add-repo-collaborators-by-pattern/github-add-repo-collaborators-by-pattern.sh`

Adds one or more individual collaborators to all repositories in an organisation whose names match a given regex pattern.

**Required variables:**
```bash
export GITHUB_TOKEN="your_token"
export ORG="your-org"
export COLLABORATORS="alice,bob"
export REPO_NAME_REGEX='^service-'
```

**Usage:**
```bash
cd org-admin/github-add-repo-collaborators-by-pattern
./github-add-repo-collaborators-by-pattern.sh
```

| Variable | Description | Default |
|----------|-------------|---------|
| `PERMISSION` | Permission level: `pull\|triage\|push\|maintain\|admin` | `push` |
| `REPO_EXCLUDE_REGEX` | ERE regex to exclude matching repository names | — |

**What it does:**
- Iterates all repositories in the organization (paginated)
- Filters to repos matching `REPO_NAME_REGEX`
- Optionally excludes repos matching `REPO_EXCLUDE_REGEX`
- Adds each specified collaborator with the configured permission level

---

### Archive Old Repositories

**Script:** `org-admin/github-archive-old-repos/github-archive-old-repos.sh`

Identifies and archives repositories that have not been updated within a configurable number of years. Generates a timestamped CSV report.

**Required variables:**
```bash
export GITHUB_TOKEN="your_token"
export ORG="your-org"
```

**Usage:**
```bash
cd org-admin/github-archive-old-repos
./github-archive-old-repos.sh
```

**What it does:**
- Fetches all repositories in the organization (paginated)
- Calculates a cutoff date based on `YEARS_THRESHOLD`
- Generates a timestamped CSV report in the `reports/` subdirectory
- Displays a summary with the top 10 oldest repositories
- Prompts for confirmation before archiving
- Archives qualifying repositories via the GitHub API, skipping already-archived ones

| Variable | Description | Default |
|----------|-------------|---------|
| `YEARS_THRESHOLD` | Age threshold in years | `5` |

---

### Auto Repository Creation

**Script:** `org-admin/github-auto-repo-creation/github-auto-repo-creation.sh`

Creates one or more private GitHub repositories in an organisation with standard configuration: branch protection on the default branch, a CODEOWNERS file, and optional team permissions.

**Required variables:**
```bash
export GITHUB_TOKEN="your_token"
export ORG="your-org"
export REPO_NAMES="repo1,repo2"
export REPO_OWNERS="platform-team"
```

**Usage:**
```bash
cd org-admin/github-auto-repo-creation
./github-auto-repo-creation.sh
```

**What it does:**
- Creates each repository listed in `REPO_NAMES` as private
- Configures branch protection on the default branch
- Creates a CODEOWNERS file referencing the `REPO_OWNERS` teams
- Grants admin access to teams listed in `ADMIN_TEAMS`

| Variable | Description | Default |
|----------|-------------|---------|
| `ADMIN_TEAMS` | Comma-separated team slugs for admin access | — |

> [!NOTE]
> Requires `base64` in addition to `curl` and `jq` (used to encode the CODEOWNERS file content for the API).

> [!NOTE]
> All values in `REPO_NAMES`, `ADMIN_TEAMS`, and `REPO_OWNERS` are validated as slugs — only alphanumeric characters, hyphens, and underscores are allowed. The script exits with an error if any value fails this check.

---

### Close Archived Repository Security Alerts

**Script:** `org-admin/github-close-archived-repo-security-alerts/github-close-archived-repo-security-alerts.sh`

Dismisses or resolves all open security alerts (Dependabot, code scanning, and secret scanning) across all repositories in a GitHub organisation. Generates a CSV report of dismissed alerts.

**Required variables:**
```bash
export GITHUB_TOKEN="your_token"
export ORG="your-org"
```

**Usage:**
```bash
cd org-admin/github-close-archived-repo-security-alerts

# Preview which alerts would be dismissed (no changes)
./github-close-archived-repo-security-alerts.sh --dry-run

# Dismiss only Dependabot alerts
./github-close-archived-repo-security-alerts.sh --type dependabot

# Dismiss all alert types
./github-close-archived-repo-security-alerts.sh
```

**Options:**

| Flag | Description | Default |
|------|-------------|---------|
| `--type <type>` | Alert type: `dependabot \| code-scanning \| secret-scanning \| all` | `all` |
| `--dry-run` | List alerts without dismissing them | — |

| Variable | Description | Default |
|----------|-------------|---------|
| `DEPENDABOT_REASON` | Dismiss reason for Dependabot alerts | `tolerable_risk` |
| `CODE_SCANNING_REASON` | Dismiss reason for code scanning alerts | `won't fix` |
| `SECRET_SCANNING_RESOLUTION` | Resolution for secret scanning alerts | `wont_fix` |

**What it does:**
- Enumerates all repositories in the organization
- For each configured alert type, pages through all open alerts
- Dismisses or resolves alerts with the configured reason
- Generates a timestamped CSV report in the `reports/` subdirectory

> [!IMPORTANT]
> Requires a token with `security_events` and `repo` scope. Use `--dry-run` first to preview the scope of changes.

---

### Enable Issues

**Script:** `org-admin/github-enable-issues/github-enable-issues.sh`

Enables the Issues feature on every repository in a GitHub organisation that currently has it disabled. Skips archived repositories.

**Required variables:**
```bash
export GITHUB_TOKEN="your_token"
export ORG="your-org"
```

**Usage:**
```bash
cd org-admin/github-enable-issues
./github-enable-issues.sh --dry-run   # Preview only
./github-enable-issues.sh             # Apply changes
```

| Flag | Description |
|------|-------------|
| `--dry-run` | List repositories that would be updated without making changes |

**What it does:**
- Iterates all non-archived repositories in the organization (paginated)
- Identifies repositories with Issues disabled
- Enables Issues on each matching repository via the PATCH API

---

### Get Repository List

**Script:** `org-admin/github-get-repo-list/github-get-repo-list.sh`

Lists all repositories in a GitHub organisation and outputs their metadata to stdout in CSV format.

**Required variables:**
```bash
export GITHUB_TOKEN="your_token"
export ORG="your-org"
```

**Usage:**
```bash
cd org-admin/github-get-repo-list
./github-get-repo-list.sh
./github-get-repo-list.sh > repos.csv
```

**What it does:**
- Fetches all repositories (paginated, 100 per page)
- Outputs a CSV row per repository with: full name, owner, visibility, URL, description, fork flag, pushed/created/updated timestamps

---

### Migrate Internal Repositories to Private

**Script:** `org-admin/github-migrate-internal-repos-to-private/github-migrate-internal-repos-to-private.sh`

Converts all repositories with "internal" visibility to "private" in a GitHub organisation.

**Required variables:**
```bash
export GITHUB_TOKEN="your_token"
export ORG="your-org"
```

**Usage:**
```bash
cd org-admin/github-migrate-internal-repos-to-private
./github-migrate-internal-repos-to-private.sh
```

**What it does:**
- Fetches all repositories with internal visibility (paginated)
- Converts each to private via the PATCH API
- Logs success or failure for each repository

> [!WARNING]
> Converting repositories from internal to private removes access from members of other organisations in the enterprise. This operation cannot be undone via the API.

---

### Monthly Issues Report

**Script:** `reporting/github-monthly-issues-report/github-monthly-issues-report.sh`

Generates HTML-formatted statistics about issues created within a date range, filtered by labels.

**Required variables:**
```bash
export GITHUB_TOKEN="your_token"
export ORG="your-org"
export REPO="your-repo"
export MONTH_START="2025-10-01"
export MONTH_END="2025-10-31"
```

**Usage:**
```bash
cd reporting/github-monthly-issues-report
./github-monthly-issues-report.sh
```

**What it does:**
- Filters issues by creation date range
- Filters by label (currently hardcoded to `Linked [AC]`)
- Uses timeline API to track who applied labels
- Generates author and contributor statistics
- Outputs HTML report to `output.txt`

> [!NOTE]
> This script includes a hardcoded label filter. Edit the script to modify the filter criteria.

---

### Repository Permissions Report

**Script:** `reporting/github-repo-permissions-report/github-repo-permissions-report.sh`

Exports repository user/team permissions to CSV and identifies who can bypass pull request approval requirements, from both branch protection rules and repository rulesets.

**Prerequisites:**
- **[curl](https://curl.se)** — HTTP client
- **[jq](https://stedolan.github.io/jq)** — JSON processor

**Usage:**
```bash
export GITHUB_TOKEN=ghp_yourtoken   # or resolved automatically from an active gh auth session
cd reporting/github-repo-permissions-report
./github-repo-permissions-report.sh -r OWNER/REPO
./github-repo-permissions-report.sh -r OWNER/REPO -b main -o report.csv
```

**Options:**

| Flag | Description | Default |
|------|-------------|----------|
| `-r, --repo OWNER/REPO` | Target repository (required) | — |
| `-b, --branch NAME` | Branch to evaluate | Repository default branch |
| `-o, --output FILE` | Output CSV path | `OWNER-REPO-permissions-BRANCH-YYYYMMDD.csv` |

**What it does:**
- Fetches all collaborators and teams with repository access
- Fetches branch protection rules and repository rulesets
- Identifies every principal that can bypass PR approval requirements
- Produces a CSV with two record types: `permission` (all users/teams) and `bypass_actor` (explicit bypass entries)

---

### Copilot Enterprise Report

**Script:** `reporting/github-copilot-report/github-copilot-report.sh`

Generates a GitHub Copilot Enterprise licence and usage report. Shows every licensed user, their plan type, pool credit contribution, and actual AI credit consumption for the current billing month. Optionally enriches data with Entra ID department information.

**Prerequisites:**
- **[curl](https://curl.se)** — HTTP client
- **[az](https://learn.microsoft.com/en-us/cli/azure/)** — Azure CLI (optional; required only for Entra ID department enrichment — pass `--no-entra` or omit az to skip)
- **[jq](https://stedolan.github.io/jq)** — JSON processor

**Required variables:**
```bash
export GITHUB_ENTERPRISE="your-enterprise-slug"

# GitHub auth — use one of:
export GITHUB_TOKEN=ghp_yourtoken    # PAT with read:enterprise and manage_billing:enterprise scopes
# OR: token is resolved automatically from an active gh auth session with the required scopes

# Optional: Entra ID UPN domain for users without a public GitHub email
export UPN_DOMAIN="example.com"        # e.g. 'john_example' → john@example.com

# Optional: override the credits-per-seat value shown in your billing portal
export CREDITS_PER_SEAT_OVERRIDE="1900"
```

**Usage:**
```bash
cd reporting/github-copilot-report

az login   # optional; needed only for Entra ID department enrichment

./github-copilot-report.sh -e YOUR-ENTERPRISE
./github-copilot-report.sh -e YOUR-ENTERPRISE -d example.com
./github-copilot-report.sh -e YOUR-ENTERPRISE --no-entra
./github-copilot-report.sh -e YOUR-ENTERPRISE --credits 1900 --output report.csv
```

**Options:**

| Flag | Description | Default |
|------|-------------|---------|
| `-e, --enterprise SLUG` | GitHub Enterprise slug (or `$GITHUB_ENTERPRISE`) | — |
| `-d, --upn-domain DOM` | Email domain for Entra lookup when GitHub carries no email (or `$UPN_DOMAIN`) | — |
| `--credits N` | Override credits-per-seat value (or `$CREDITS_PER_SEAT_OVERRIDE`) | Auto-detected |
| `--output FILE` | Output CSV filename | `copilot-report-YYYYMMDD.csv` |
| `--no-entra` | Skip Entra ID department lookup | — |

**What it does:**
- Fetches all Copilot seats across the enterprise (deduplicated by user)
- Fetches per-user AI credit consumption for the current billing month
- Fetches enterprise-level model usage metrics (last 28 days)
- Optionally enriches each user with Entra ID department and job title via `az rest`
- Outputs a CSV and a formatted console summary with department breakdown and model usage tables

> [!IMPORTANT]
> Requires a PAT with `read:enterprise` and `manage_billing:enterprise` scopes — the built-in `GITHUB_TOKEN` cannot grant enterprise-level access. Set `GITHUB_TOKEN` before executing (or have an active `gh` auth session with those scopes so the lib can auto-resolve the token).

> [!NOTE]
> The Entra ID enrichment is skipped automatically if `az` is not logged in, or can be disabled with `--no-entra`.

---

### Get Consumed Licenses

**Script:** `enterprise/github-get-consumed-licenses/github-get-consumed-licenses.sh`

Retrieves license consumption metrics for a GitHub Enterprise account.

**Required variables:**
```bash
export GITHUB_TOKEN="your_enterprise_token"  # Must have read:enterprise scope
export ENTERPRISE="your-enterprise"
```

**Usage:**
```bash
cd enterprise/github-get-consumed-licenses
./github-get-consumed-licenses.sh
```

**Output:**
```
Total seats consumed: 150
Total seats purchased: 200
```

**What it does:**
- Calls the enterprise consumed-licenses endpoint
- Uses Bearer token authentication (unlike other scripts)
- Returns seat consumption and purchase counts

> [!IMPORTANT]
> This script requires an enterprise-level token with `read:enterprise` scope. Organization tokens will not work.

---

### Install Enterprise App

**Script:** `enterprise/github-install-enterprise-app/github-install-enterprise-app.sh`

Programmatically installs an enterprise-owned "automation" GitHub App into an enterprise-owned organization, using a second enterprise-owned "installer" GitHub App that holds the **Enterprise organization installations** permission. Follows GitHub's [Automating app installations](https://docs.github.com/en/enterprise-cloud@latest/admin/managing-github-apps-for-your-enterprise/automate-installations) guide.

Authentication is performed entirely with the two GitHub Apps (JWT → installation access token). No `GITHUB_TOKEN` / PAT is used, and JWTs and access tokens are never printed.

**Required variables:**
```bash
export ENTERPRISE="my-enterprise"
export ORG="my-org"                                   # Target org for the install
export INSTALLER_APP_CLIENT_ID="Iv23li..."            # Installer app client ID
export INSTALLER_APP_PRIVATE_KEY="~/installer-app.private-key.pem"
export INSTALLER_APP_INSTALL_ID="12345678"           # Installer app's enterprise install ID
export AUTOMATION_APP_CLIENT_ID="Iv23li..."          # App to install in the org
```

**Usage:**
```bash
cd enterprise/github-install-enterprise-app
./github-install-enterprise-app.sh           # Install the automation app
./github-install-enterprise-app.sh --dry-run # Authenticate only; make no changes
```

**What it does:**
- Generates a short-lived RS256 JWT from the installer app's client ID and private key (via `openssl`)
- Exchanges the JWT for an enterprise-scoped installation access token
- Installs the automation app in the target organization and prints the new installation ID
- Optionally verifies the install by minting an org-scoped token when `AUTOMATION_APP_PRIVATE_KEY` is supplied

| Variable | Description | Default |
|----------|-------------|---------|
| `AUTOMATION_APP_PRIVATE_KEY` | Path to the automation app `.pem`; when set, verifies the new install by minting an org-scoped token | (unset — verification skipped) |
| `REPO_SELECTION` | Repository access for the install: `all` or `selected` | `all` |
| `API_URL_PREFIX` | GitHub API base URL | `https://api.github.com` |

> [!IMPORTANT]
> Requires two enterprise-owned GitHub Apps. The installer app must be installed on the enterprise account with read and write access to **Enterprise organization installations**. This script additionally requires `openssl` for JWT generation.

---

### Add Enterprise Team Read Permissions

**Script:** `enterprise/github-add-enterprise-team-read-permissions/github-add-enterprise-team-read-permissions.sh`

Assigns the built-in "All-repository read" organisation role to a specified enterprise team in every organisation within a GitHub Enterprise account. This grants read access to all current and future repositories without requiring per-repository assignments.

**Required variables:**
```bash
export GITHUB_TOKEN="your_enterprise_token"   # Must have admin:enterprise scope
export ENTERPRISE="my-enterprise"
export ENTERPRISE_TEAM_SLUG="platform-team"
```

**Usage:**
```bash
cd enterprise/github-add-enterprise-team-read-permissions
./github-add-enterprise-team-read-permissions.sh
```

**What it does:**
- Enumerates all organizations in the enterprise via GraphQL (cursor-based pagination)
- Looks up the enterprise team ID and the target org role ID in each organization
- Assigns the `all_repo_read` org role to the enterprise team in every organization

| Variable | Description | Default |
|----------|-------------|---------|
| `ALL_REPO_READ_ROLE_NAME` | Org role name to assign | `all_repo_read` |

> [!IMPORTANT]
> Requires an enterprise-level token with `admin:enterprise` scope. Organization tokens will not work.

---

### Dockerfile Discovery

**Script:** `enterprise/github-dockerfile-discovery/github-dockerfile-discovery.sh`

Searches all organisations in a GitHub Enterprise account for Dockerfiles, extracts base image references from `FROM` instructions, and generates CSV reports to identify common base images across the estate.

**Required variables:**
```bash
export GITHUB_TOKEN="your_token"
export ENTERPRISE="my-enterprise"
```

**Usage:**
```bash
cd enterprise/github-dockerfile-discovery
./github-dockerfile-discovery.sh
```

**What it does:**
- Discovers all orgs in the enterprise via GraphQL, or uses the `ORGS` override
- Uses the GitHub code search API to locate Dockerfiles in each org
- Fetches and parses each Dockerfile to extract `FROM` instructions (including multi-stage builds)
- Generates three timestamped reports in `REPORT_DIR`:
  - `dockerfile_discovery_detail_*.csv` — one row per image reference
  - `dockerfile_discovery_summary_*.csv` — image usage counts
  - `dockerfile_discovery_summary_*.txt` — plain-text summary

| Variable | Description | Default |
|----------|-------------|---------|
| `REPORT_DIR` | Output directory for reports | `./reports` |
| `ORGS` | Comma-separated org list; skips enterprise lookup | — |
| `ORG_FILTER` | ERE regex to keep only matching org names | — |
| `ORG_EXCLUDE` | ERE regex to drop matching org names | — |
| `SEARCH_SLEEP` | Seconds between code-search requests | `2` |
| `CONTENT_SLEEP` | Seconds between content-fetch requests | `1` |

> [!NOTE]
> Code search is heavily rate-limited. Increase `SEARCH_SLEEP` and `CONTENT_SLEEP` if you encounter `403` responses.

> [!NOTE]
> `ORG_FILTER` and `ORG_EXCLUDE` are validated as syntactically correct ERE patterns before use. An invalid regex causes the script to exit immediately with an error rather than silently bypassing the filter.

---

### Get Public Repositories

**Script:** `enterprise/github-get-public-repos/github-get-public-repos.sh`

Lists all repositories with public visibility across every organisation in a GitHub Enterprise account and writes a timestamped CSV report.

**Required variables:**
```bash
export GITHUB_TOKEN="your_token"
export ENTERPRISE="my-enterprise"
```

**Usage:**
```bash
cd enterprise/github-get-public-repos
./github-get-public-repos.sh
./github-get-public-repos.sh > public_repos.csv
```

**What it does:**
- Discovers all orgs in the enterprise, or uses the `ORGS` override
- Fetches all repositories in each org and filters to public visibility
- Writes a timestamped CSV report in `REPORT_DIR` with: org, repo name, URL, description, created date, last pushed date

| Variable | Description | Default |
|----------|-------------|---------|
| `REPORT_DIR` | Output directory for reports | `./reports` |
| `ORGS` | Comma-separated org list; skips enterprise lookup | — |
| `ORG_FILTER` | ERE regex to keep only matching org names | — |
| `ORG_EXCLUDE` | ERE regex to drop matching org names | — |

> [!NOTE]
> `ORG_FILTER` and `ORG_EXCLUDE` are validated as syntactically correct ERE patterns before use. An invalid regex causes the script to exit immediately with an error rather than silently bypassing the filter.

---

### Organize Starred Repositories

**Script:** `personal/github-organize-stars/github-organize-stars.sh`

Fetches all your starred repositories and organizes them into GitHub Lists using customizable categorization rules.

**Prerequisites:**
- **[gh](https://cli.github.com)** - GitHub CLI (authenticated via `GITHUB_TOKEN` env var or `gh auth login`)
- **[jq](https://stedolan.github.io/jq)** - Command-line JSON processor

**Usage:**
```bash
cd personal/github-organize-stars
./github-organize-stars.sh              # Interactive (shows plan, asks to confirm)
./github-organize-stars.sh --dry-run    # Preview only, no changes made
./github-organize-stars.sh -y           # Skip confirmation prompt
./github-organize-stars.sh --show-repos # Also list repo names in each category
./github-organize-stars.sh --no-cache   # Force re-fetch stars from GitHub
```

**What it does:**
- Fetches all starred repositories via the GraphQL API (paginated)
- Categorizes each repo by primary language, GitHub topics, and repo name keywords
- Creates new GitHub Lists and adds repos in batches of 25
- Caches fetched stars locally at `~/.cache/gh-star-organizer/stars.json` to speed up re-runs
- Shows a categorization plan and prompts for confirmation before making changes

**Customizing categories:**

Edit the `RULES` array in the script. Each rule is a `|`-delimited string:
```
"List Name|LANGUAGES|TOPICS|NAME_KEYWORDS"
```
- `LANGUAGES` — comma-separated primary language names (case-insensitive)
- `TOPICS` — comma-separated GitHub topic slugs
- `NAME_KEYWORDS` — comma-separated substrings matched against the repo name

The **first matching rule wins**, so order matters. Place more specific rules (e.g., AI) before general ones (e.g., Security).

> [!NOTE]
> This script uses the `gh` CLI for all API calls (GraphQL) rather than `curl`. Authenticate by setting `GITHUB_TOKEN` or by running `gh auth login`.

## Shared Library: `lib/github-common.sh`

All scripts can leverage a shared utility library for common operations like validation, colored output, and API helpers. The library is optional—scripts work standalone without it—but sourcing it reduces code duplication and adds helpful utilities.

### Available Functions

**Output formatting:**
- `print_status <message>` — Blue INFO message
- `print_success <message>` — Green SUCCESS message
- `print_warning <message>` — Yellow WARNING message
- `print_error <message>` — Red ERROR message (to stderr)

**Validation:**
- `require_env_var <VAR_NAME> [description]` — Exit if environment variable is empty
- `require_command <cmd> [hint]` — Exit if command is not in PATH
- `validate_token <VAR_NAME> [bearer]` — Validate GitHub token by calling `/user` endpoint
- `validate_github_token [bearer]` — Convenience wrapper for `GITHUB_TOKEN` validation
- `validate_slug <value> <label>` — Exit if value contains characters other than alphanumeric, hyphen, or underscore

**Auth helpers:**
- `configure_gh_auth [scope_hint]` — Bridge `GITHUB_TOKEN→GH_TOKEN` for scripts that use the `gh` CLI, or verify an active `gh` auth session if no token is set

**API helpers:**
- `get_repo_page_count <url>` — Get total page count from paginated REST endpoint
- `gh_api <path|url> [curl args...]` — Bearer-auth REST helper with automatic rate-limit retry (up to 5 attempts); returns the literal string `__404__` or `__422__` (exit 0) for those status codes — callers must check for these sentinels before passing the result to `jq`
- `gh_api_paginate <path> [jq_filter] [api_version]` — Paginated REST helper that follows `Link` headers and streams items through `jq_filter` (default `.[]`); silently returns empty output on 404/422; pipe through `jq -s '.'` to collect all items as an array
- `_paginate_orgs_endpoint <jq_filter> <url_template>` — Page through an org-list REST endpoint, printing one login per line; use `PAGE` as a placeholder in the URL template
- `_graphql_enterprise_orgs` — Cursor-based GraphQL pagination for all orgs in `ENTERPRISE`; prints one login per line
- `get_enterprise_orgs` — Three-tier enterprise org resolver: tries REST `/enterprises/{slug}/organizations`, falls back to GraphQL, then falls back to `/user/orgs`

### Using the Shared Library in Scripts

Source the library from your script:

```bash
#!/bin/bash
set -euo pipefail

GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/github-common.sh
source "${SCRIPT_DIR}/../../lib/github-common.sh"

# Now use library functions
require_env_var GITHUB_TOKEN "GitHub Personal Access Token"
require_env_var ORG "GitHub Organization"
validate_github_token

print_status "Processing organization: ${ORG}"
# ... rest of script
```

## Using Scripts in GitHub Actions

Each script is published as a **composite action**, so you can reference it directly with a `uses:` step — no manual checkout required. Dependabot automatically tracks the pinned version and opens bump PRs when a new release is published.

```yaml
- uses: locus313/github-api-scripts/org-admin/github-add-repo-permissions@v1.0.0
  with:
    github-token: ${{ secrets.ORG_ADMIN_TOKEN }}
    org: my-org
    repo-push: developers maintainers
```

### Available Actions

| Action | Description |
|--------|-------------|
| `enterprise/github-add-enterprise-team-read-permissions` | Grant read permissions to an enterprise team across all orgs |
| `enterprise/github-dockerfile-discovery` | Discover Dockerfiles and extract `FROM` instructions across all enterprise orgs |
| `enterprise/github-get-consumed-licenses` | Report Enterprise consumed licence seat counts |
| `enterprise/github-get-public-repos` | List all public repositories across all Enterprise orgs |
| `enterprise/github-install-enterprise-app` | Install an enterprise-owned GitHub App into an org (JWT flow) |
| `org-admin/github-add-repo-collaborators-by-pattern` | Add collaborators to repositories matching a name pattern |
| `org-admin/github-add-repo-permissions` | Grant team permissions across all repositories in an org |
| `org-admin/github-archive-old-repos` | Archive repositories not updated within a configurable age threshold |
| `org-admin/github-auto-repo-creation` | Create private repositories with branch protection and CODEOWNERS |
| `org-admin/github-close-archived-repo-security-alerts` | Dismiss all open security alerts on archived repositories |
| `org-admin/github-enable-issues` | Enable Issues on all repositories where it is currently disabled |
| `org-admin/github-get-repo-list` | Output a CSV list of all repositories in an org |
| `org-admin/github-import-repo` | Mirror-clone a repository into a new private org repository |
| `org-admin/github-migrate-internal-repos-to-private` | Convert all internal-visibility repositories to private |
| `org-admin/github-repo-from-template` | Create a repository from a template with team permissions and a CI/CD collaborator |
| `reporting/github-monthly-issues-report` | Generate an HTML report of issues created within a date range |
| `reporting/github-repo-permissions-report` | Export repository collaborator/team permissions and branch-approval bypass actors to CSV |
| `reporting/github-copilot-report` | GitHub Copilot Enterprise licence and AI credit usage report, optionally enriched with Entra ID department data |

---

### Example 1: Grant Team Permissions on Repository Changes

Automatically update team permissions when ownership rules change:

```yaml
name: Update Repository Permissions
on:
  push:
    branches: [main]
    paths:
      - '.github/CODEOWNERS'

jobs:
  update-permissions:
    runs-on: ubuntu-latest
    steps:
      - uses: locus313/github-api-scripts/org-admin/github-add-repo-permissions@v1.0.0
        with:
          github-token: ${{ secrets.ORG_ADMIN_TOKEN }}
          org: my-org
          repo-push: developers maintainers
          repo-triage: support-team
```

### Example 2: Archive Old Repositories Monthly

Schedule automated archival of stale repositories:

```yaml
name: Archive Old Repositories
on:
  schedule:
    - cron: '0 9 1 * *'

jobs:
  archive-old:
    runs-on: ubuntu-latest
    steps:
      - uses: locus313/github-api-scripts/org-admin/github-archive-old-repos@v1.0.0
        with:
          github-token: ${{ secrets.ORG_ADMIN_TOKEN }}
          org: my-org
          years-threshold: '5'
          auto-confirm: 'true'
          report-dir: ./reports

      - name: Upload report as artifact
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: archive-report
          path: reports/
          retention-days: 30
```

### Example 3: Create Repositories from Template

Allow manual repository creation with pre-configured settings via workflow dispatch:

```yaml
name: Create New Repository from Template
on:
  workflow_dispatch:
    inputs:
      repo-name:
        description: 'Repository name'
        required: true
        type: string
      repo-owner:
        description: 'Team slug for admin permissions'
        required: true
        type: string

jobs:
  create-repo:
    runs-on: ubuntu-latest
    steps:
      - uses: locus313/github-api-scripts/org-admin/github-repo-from-template@v1.0.0
        with:
          github-token: ${{ secrets.ORG_ADMIN_TOKEN }}
          org: my-org
          repo-name: ${{ github.event.inputs.repo-name }}
          template-repo: template-repo
          repo-admin: ${{ github.event.inputs.repo-owner }}
          repo-write: developers
          cd-username: github-actions[bot]
          cd-github-token: ${{ secrets.CD_TOKEN }}
```

### Example 4: Weekly Dockerfile Discovery Report

Track base images across your enterprise and commit reports back to your own repository:

```yaml
name: Discover Dockerfiles in Enterprise
on:
  schedule:
    - cron: '0 12 * * 1'

jobs:
  discover-dockerfiles:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout your repository
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0

      - uses: locus313/github-api-scripts/enterprise/github-dockerfile-discovery@v1.0.0
        with:
          github-token: ${{ secrets.ENTERPRISE_TOKEN }}
          enterprise: my-enterprise
          report-dir: ./reports

      - name: Upload reports as artifacts
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: dockerfile-reports
          path: reports/
          retention-days: 60

      - name: Commit reports to repository
        if: success()
        run: |
          git add reports/ || true
          git diff --quiet && git diff --staged --quiet || (
            git config user.name "github-actions[bot]"
            git config user.email "github-actions[bot]@users.noreply.github.com"
            git commit -m "chore: update dockerfile discovery reports"
            git push
          )
```

> [!NOTE]
> Example 4 checks out your own repository first (so `git push` commits to it). The composite action writes reports to the `report-dir` path inside your workspace, so `git add reports/` picks them up correctly.

### Keeping Actions Up to Date

Because each script is a composite action, Dependabot tracks the pinned version tag and opens bump PRs automatically. Add the following to your `.github/dependabot.yml` (if not already present):

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: monthly
```

### GitHub Actions Best Practices

**Use separate secrets for sensitive operations:**
```yaml
env:
  GITHUB_TOKEN: ${{ secrets.ORG_ADMIN_TOKEN }}      # For org-level changes
  CD_GITHUB_TOKEN: ${{ secrets.CD_BOT_TOKEN }}      # For CD user operations
```

**Capture logs for audit trails:**
```yaml
- uses: locus313/github-api-scripts/org-admin/github-add-repo-permissions@v1.0.0
  with:
    github-token: ${{ secrets.ORG_ADMIN_TOKEN }}
    org: my-org
    repo-push: developers

- name: Upload execution log
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: execution-logs
    path: execution.log
```

**Use workflow_dispatch for manual operations:**
```yaml
on:
  workflow_dispatch:
    inputs:
      org:
        description: 'Organization name'
        required: true
```

**Protect destructive operations:**
Consider adding approval steps or environment protection rules before running destructive scripts (like archive or delete operations).

## Best Practices

**Test on a test organization first**
Always validate on a non-production organization before running against production resources. Several scripts support a `--dry-run` flag (`github-close-archived-repo-security-alerts`, `github-enable-issues`, `github-organize-stars`) that previews changes without applying them.

**Rate limiting**
Scripts include built-in delays (5 seconds between repository operations) to stay within GitHub's rate limits. For large organizations with hundreds of repos, expect longer execution times.

**Audit trails**
Capture output for compliance and troubleshooting:
```bash
./script.sh 2>&1 | tee execution-$(date +%Y%m%d).log
```

**Team slugs vs display names**
GitHub API uses team slugs (lowercase, hyphenated). Example: "Platform Team" → `platform-team`. Find team slugs in your organization settings or via the API.

**GitHub Enterprise Server**
These scripts support GHES. Set custom endpoints:
```bash
export API_URL_PREFIX="https://github.company.com/api/v3"
export GIT_URL_PREFIX="https://github.company.com"
```

## Resources

- [GitHub REST API Documentation](https://docs.github.com/en/rest)
- [Creating a personal access token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token)
- [jq Manual](https://stedolan.github.io/jq/manual/)
- [GitHub API Rate Limits](https://docs.github.com/en/rest/overview/resources-in-the-rest-api#rate-limiting)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)

## Contributing

Contributions are welcome! Please follow these steps:

1. **Fork** this repo and create a branch using Conventional Commits naming: `git checkout -b feat/my-new-script`
2. **Install the pre-commit hook:** `./install-hooks.sh`
3. **Add your script** following the conventions in [AGENTS.md](AGENTS.md):
   - Create `<domain>/github-<name>/github-<name>.sh`
   - Start with the `# ===` header and `set -euo pipefail`
   - Source `lib/github-common.sh` and validate all inputs
   - Create `action.yml` in the same directory (see existing actions for the pattern)
4. **Update README.md** with the env var table, usage example, and a row in the Available Actions table
5. **Run shellcheck:** `shellcheck --severity=warning --exclude=SC2034,SC1091 --shell=bash your-script.sh`
6. **Test on a non-production org** before submitting
7. **Commit using [Conventional Commits](https://www.conventionalcommits.org/)** — `CHANGELOG.md` is auto-generated from commit messages; do not edit it manually
8. **Open a PR** — the PR template will guide you through the checklist
