# GitHub API Scripts

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
| `GIT_URL_PREFIX` | GitHub base URL (default: `https://github.com`) | No |

> [!NOTE]
> The `*_PREFIX` variables support GitHub Enterprise Server. Set them to your enterprise domain to use these scripts with GHES.

## Scripts

Each script is a self-contained utility designed for a specific task. Navigate to the script's directory, set the required environment variables, and execute.

### Folder Layout (Domain-Based)

- `org-admin/`: `github-add-repo-collaborators-by-pattern`, `github-add-repo-permissions`, `github-archive-old-repos`, `github-auto-repo-creation`, `github-close-archived-repo-security-alerts`, `github-enable-issues`, `github-get-repo-list`, `github-import-repo`, `github-migrate-internal-repos-to-private`, `github-repo-from-template`
- `enterprise/`: `github-add-enterprise-team-read-permissions`, `github-dockerfile-discovery`, `github-get-consumed-licenses`, `github-get-public-repos`
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
```

**Usage:**
```bash
cd org-admin/github-add-repo-permissions
./github-add-repo-permissions.sh
```

**What it does:**
- Retrieves all repositories in the organization (paginated)
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
- **[gh](https://cli.github.com)** — GitHub CLI (authenticated via `gh auth login`)
- **[jq](https://stedolan.github.io/jq)** — JSON processor

**Usage:**
```bash
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

> [!NOTE]
> Uses the `gh` CLI for all API calls. Authenticate via `gh auth login` before running.

---

### Copilot Enterprise Report

**Script:** `reporting/github-copilot-report/github-copilot-report.sh`

Generates a GitHub Copilot Enterprise licence and usage report. Shows every licensed user, their plan type, pool credit contribution, and actual AI credit consumption for the current billing month. Optionally enriches data with Entra ID department information.

**Prerequisites:**
- **[gh](https://cli.github.com)** — GitHub CLI authenticated with `read:enterprise` and `manage_billing:enterprise` scopes
- **[az](https://learn.microsoft.com/en-us/cli/azure/)** — Azure CLI (optional, for Entra ID department enrichment)
- **[jq](https://stedolan.github.io/jq)** — JSON processor

**Required variables:**
```bash
export GITHUB_ENTERPRISE="your-enterprise-slug"

# Optional: Entra ID UPN domain for users without a public GitHub email
export UPN_DOMAIN="example.com"        # e.g. 'john_example' → john@example.com

# Optional: override the credits-per-seat value shown in your billing portal
export CREDITS_PER_SEAT_OVERRIDE="1900"
```

**Usage:**
```bash
cd reporting/github-copilot-report

# Authenticate first
gh auth refresh --scopes "read:enterprise,manage_billing:enterprise"
az login   # optional, for department enrichment

./github-copilot-report.sh -e YOUR-ENTERPRISE
./github-copilot-report.sh -e YOUR-ENTERPRISE -d example.com
./github-copilot-report.sh -e YOUR-ENTERPRISE --no-entra
```

**What it does:**
- Fetches all Copilot seats across the enterprise (deduplicated by user)
- Fetches per-user AI credit consumption for the current billing month
- Fetches enterprise-level model usage metrics (last 28 days)
- Optionally enriches each user with Entra ID department and job title via `az rest`
- Outputs a CSV and a formatted console summary with department breakdown and model usage tables

> [!IMPORTANT]
> Requires an enterprise owner or billing manager token. Run `gh auth refresh --scopes "read:enterprise,manage_billing:enterprise"` before executing.

> [!NOTE]
> Uses the `gh` CLI and (optionally) the `az` CLI. The Entra ID enrichment is skipped automatically if `az` is not logged in, or can be disabled with `--no-entra`.

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

### Organize Starred Repositories

**Script:** `personal/github-organize-stars/github-organize-stars.sh`

Fetches all your starred repositories and organizes them into GitHub Lists using customizable categorization rules.

**Prerequisites:**
- **[gh](https://cli.github.com)** - GitHub CLI (authenticated via `gh auth login`)
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
> This script uses the `gh` CLI for all API calls (GraphQL) rather than `curl`. Ensure you are authenticated via `gh auth login` before running.

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

**API helpers:**
- `get_repo_page_count <url>` — Get total page count from paginated REST endpoint

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

All scripts can be easily integrated into GitHub Actions workflows. Here are practical examples:

### Example 1: Grant Team Permissions on Repository Changes

Automatically update team permissions when ownership rules change:

```yaml
name: Update Repository Permissions
on:
  push:
    branches: [main]
    paths:
      - '.github/CODEOWNERS'  # Trigger when ownership changes

jobs:
  update-permissions:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Grant team permissions to all repos
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          ORG: my-org
          REPO_PUSH: developers maintainers
          REPO_TRIAGE: support-team
        run: |
          ./org-admin/github-add-repo-permissions/github-add-repo-permissions.sh
```

### Example 2: Archive Old Repositories Monthly

Schedule automated archival of stale repositories:

```yaml
name: Archive Old Repositories
on:
  schedule:
    # Run monthly on the 1st at 9 AM UTC
    - cron: '0 9 1 * *'

jobs:
  archive-old:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Archive repositories not updated in 5 years
        env:
          GITHUB_TOKEN: ${{ secrets.ORG_ADMIN_TOKEN }}
          ORG: my-org
          YEARS_THRESHOLD: 5
        run: |
          ./org-admin/github-archive-old-repos/github-archive-old-repos.sh
      
      - name: Upload report as artifact
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: archive-report
          path: org-admin/github-archive-old-repos/reports/
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
      - uses: actions/checkout@v4
      
      - name: Create repository from template
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          ORG: my-org
          TEMPLATE_REPO: template-repo
          REPO_ADMIN: ${{ github.event.inputs.repo-owner }}
          REPO_WRITE: developers
          CD_USERNAME: github-actions[bot]
          CD_GITHUB_TOKEN: ${{ secrets.CD_TOKEN }}
        run: |
          ./org-admin/github-repo-from-template/github-repo-from-template.sh "${{ github.event.inputs.repo-name }}"
      
      - name: Log success
        if: success()
        run: |
          echo "✅ Repository ${{ github.event.inputs.repo-name }} created successfully!"
```

### Example 4: Weekly Dockerfile Discovery Report

Track base images across your enterprise:

```yaml
name: Discover Dockerfiles in Enterprise
on:
  schedule:
    # Run weekly on Monday at 12 PM UTC
    - cron: '0 12 * * 1'

jobs:
  discover-dockerfiles:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Discover Dockerfiles across enterprise
        env:
          GITHUB_TOKEN: ${{ secrets.ENTERPRISE_TOKEN }}
          ENTERPRISE: my-enterprise
          REPORT_DIR: ./reports
        run: |
          mkdir -p ./reports
          ./enterprise/github-dockerfile-discovery/github-dockerfile-discovery.sh
      
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

### GitHub Actions Best Practices

**Use separate secrets for sensitive operations:**
```yaml
env:
  GITHUB_TOKEN: ${{ secrets.ORG_ADMIN_TOKEN }}      # For org-level changes
  CD_GITHUB_TOKEN: ${{ secrets.CD_BOT_TOKEN }}      # For CD user operations
```

**Capture logs for audit trails:**
```yaml
- name: Run script with logging
  run: |
    ./org-admin/github-add-repo-permissions/github-add-repo-permissions.sh 2>&1 | tee -a execution.log
    
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
These scripts have no dry-run mode. Always validate on a non-production organization before running against production resources.

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
