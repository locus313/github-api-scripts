# GitHub API Scripts

[![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)
![Shell](https://img.shields.io/badge/Shell-Bash-89e051?style=flat-square&logo=gnu-bash&logoColor=white)
[![GitHub API](https://img.shields.io/badge/GitHub_API-v3-blue?style=flat-square&logo=github)](https://docs.github.com/en/rest)

⭐ If you like this project, star it on GitHub — it helps a lot!

[Overview](#overview) • [Getting started](#getting-started) • [Scripts](#scripts) • [Resources](#resources)

A collection of standalone bash scripts for GitHub organization administration. Automate common tasks like bulk permission management, repository creation, migration, and reporting using simple, self-contained utilities powered by the GitHub REST API.

## Overview

This toolkit provides ready-to-use automation scripts for GitHub organization administrators. Each script is a complete, independent utility—no shared libraries or frameworks. Just drop in your token and organization name, and you're ready to go.

**What you can do:**
- Grant team permissions across all repositories in bulk
- Create repositories from templates with pre-configured access
- Mirror repositories with full git history
- Generate monthly issue reports with contributor statistics
- Track license consumption for enterprise accounts

**What you can do:**
- Grant team permissions across all repositories in bulk
- Create repositories from templates with pre-configured access
- Mirror repositories with full git history
- Generate monthly issue reports with contributor statistics
- Track license consumption for enterprise accounts

**Built with simplicity:** Each script uses only `curl` for API requests and `jq` for JSON processing—no complex dependencies, no installation required beyond standard Unix tools.

> [!NOTE]
> These scripts follow a convention-over-configuration approach. Each lives in its own directory as a single `.sh` file with built-in validation and error handling.

## Getting started

### Prerequisites

- **bash** 4+ 
- **[curl](https://curl.se)** - HTTP client for API requests
- **[jq](https://stedolan.github.io/jq)** - Command-line JSON processor
- **[git](https://git-scm.com)** - For repository operations (required by some scripts)
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

### Add Repository Permissions

**Script:** `github-add-repo-permissions/github-add-repo-permissions.sh`

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
cd github-add-repo-permissions
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

**Script:** `github-repo-from-template/github-repo-from-template.sh`

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
cd github-repo-from-template
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

**Script:** `github-import-repo/github-import-repo.sh`

Performs a full repository mirror—clones source repo and pushes all branches, tags, and history to a new destination repo.

**Required variables:**
```bash
export GITHUB_TOKEN="your_token"
export ORG="your-org"
export OWNER_USERNAME="admin-user"
```

**Usage:**
```bash
cd github-import-repo
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

**Script:** `github-monthly-issues-report/github-monthly-issues-report.sh`

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
cd github-monthly-issues-report
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

### Get Consumed Licenses

**Script:** `github-get-consumed-licenses/github-get-consumed-licenses.sh`

Retrieves license consumption metrics for a GitHub Enterprise account.

**Required variables:**
```bash
export GITHUB_TOKEN="your_enterprise_token"  # Must have read:enterprise scope
export ENTERPRISE="your-enterprise"
```

**Usage:**
```bash
cd github-get-consumed-licenses
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
