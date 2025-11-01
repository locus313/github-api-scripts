# GitHub API Scripts

[![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)
![Shell](https://img.shields.io/badge/Shell-Bash-89e051?style=flat-square&logo=gnu-bash&logoColor=white)
[![GitHub API](https://img.shields.io/badge/GitHub_API-v3-blue?style=flat-square&logo=github)](https://docs.github.com/en/rest)

⭐ If you like this project, star it on GitHub — it helps a lot!

[Overview](#overview) • [Prerequisites](#prerequisites) • [Getting Started](#getting-started) • [Scripts](#scripts) • [Usage](#usage)

A collection of bash scripts that automate common GitHub administrative tasks using the [GitHub REST API](https://docs.github.com/en/rest). These lightweight, dependency-minimal scripts help you manage repositories, teams, issues, and licenses across your GitHub organization.

## Overview

This toolkit provides ready-to-use scripts for GitHub organization administrators and developers who need to automate repetitive tasks. All scripts use `curl` to interact with the GitHub API and `jq` for JSON processing, making them portable and easy to customize.

**Key capabilities:**
- Bulk repository management and administration
- Team permission assignment
- Repository creation and migration
- License consumption reporting
- Issue tracking and reporting

## Prerequisites

- **bash** (version 4+ recommended)
- **[curl](https://curl.se)** - for API requests
- **[jq](https://stedolan.github.io/jq)** - for JSON parsing
- **[git](https://git-scm.com)** - for repository operations (required by some scripts)
- **GitHub Personal Access Token** with appropriate scopes (see [Authentication](#authentication))

## Getting Started

### Installation

Clone the repository:

```bash
git clone https://github.com/locus313/github-api-scripts.git
cd github-api-scripts
```

Alternatively, download individual scripts as needed or grab the source archive.

### Authentication

All scripts require a GitHub Personal Access Token. Create one at [github.com/settings/tokens](https://github.com/settings/tokens) with the following scopes:

- `repo` - Full control of repositories
- `admin:org` - Organization administration (for team management)
- `read:enterprise` - Read enterprise data (for license consumption)

Set your token as an environment variable:

```bash
export GITHUB_TOKEN="your_github_token_here"
```

> [!TIP]
> Add this to your `~/.bashrc` or `~/.zshrc` to persist across sessions.

### Configuration

Most scripts use environment variables for configuration. Common variables include:

| Variable | Description | Required |
|----------|-------------|----------|
| `GITHUB_TOKEN` | Your GitHub personal access token | Yes |
| `ORG` | GitHub organization name | Yes (for org scripts) |
| `API_URL_PREFIX` | GitHub API base URL | No (defaults to `https://api.github.com`) |
| `GIT_URL_PREFIX` | GitHub base URL | No (defaults to `https://github.com`) |

## Scripts

### `github-add-repo-admin`

Grants admin permissions to a specified team across all repositories in an organization.

**Use case:** Ensuring an internal admin team has administrator access to all repositories.

**Required variables:**
- `GITHUB_TOKEN` - Your access token
- `ORG` - Organization name
- `REPO_ADMIN` - Team slug to grant admin permissions

**Usage:**
```bash
cd github-add-repo-admin
export GITHUB_TOKEN="your_token"
export ORG="your-org"
export REPO_ADMIN="admins"
./github-add-repo-admin.sh
```

### `github-get-consumed-licenses`

Retrieves license consumption information for a GitHub Enterprise account.

**Use case:** Auditing seat usage and tracking license costs.

**Required variables:**
- `GITHUB_TOKEN` - Your access token (with `read:enterprise` scope)
- `ENTERPRISE` - Enterprise account name

**Usage:**
```bash
cd github-get-consumed-licenses
export GITHUB_TOKEN="your_token"
export ENTERPRISE="your-enterprise"
./github-get-consumed-licenses.sh
```

**Output:**
```
Total seats consumed: 150
Total seats purchased: 200
```

### `github-import-repo`

Creates a new repository and mirrors all content from an existing repository.

**Use case:** Migrating or duplicating repositories within the same organization.

**Required variables:**
- `GITHUB_TOKEN` - Your access token
- `ORG` - Organization name
- `OWNER_USERNAME` - Username to grant admin permissions on the new repository

**Usage:**
```bash
cd github-import-repo
export GITHUB_TOKEN="your_token"
export ORG="your-org"
export OWNER_USERNAME="admin-user"
./github-import-repo.sh source-repo destination-repo
```

> [!WARNING]
> This script performs a bare clone and mirror push. Ensure you have sufficient disk space and network bandwidth for large repositories.

### `github-monthly-issues-report`

Generates a monthly report of issues with specific labels, including author and contributor statistics.

**Use case:** Tracking community contributions and support activities.

**Required variables:**
- `GITHUB_TOKEN` - Your access token
- `ORG` - Organization name
- `REPO` - Repository name
- `MONTH_START` - Start date (format: `YYYY-MM-DD`)
- `MONTH_END` - End date (format: `YYYY-MM-DD`)

**Usage:**
```bash
cd github-monthly-issues-report
export GITHUB_TOKEN="your_token"
export ORG="your-org"
export REPO="your-repo"
export MONTH_START="2025-10-01"
export MONTH_END="2025-10-31"
./github-monthly-issues-report.sh
```

**Output:** Creates `output.txt` with HTML-formatted author and contributor statistics.

### `github-repo-from-template`

Creates a new repository from a template and configures team permissions and collaborator access.

**Use case:** Standardizing new project setup with predefined structure and permissions.

**Required variables:**
- `GITHUB_TOKEN` - Your access token
- `ORG` - Organization name
- `TEMPLATE_REPO` - Template repository name
- `REPO_ADMIN` - Space-separated list of admin teams
- `REPO_WRITE` - Space-separated list of write teams
- `CD_USERNAME` - Username for CD/automation user
- `CD_GITHUB_TOKEN` - Token for CD user (to accept invitation)

**Usage:**
```bash
cd github-repo-from-template
export GITHUB_TOKEN="your_token"
export ORG="your-org"
export TEMPLATE_REPO="template-repo"
export REPO_ADMIN="admins platform-team"
export REPO_WRITE="developers"
export CD_USERNAME="cd-user"
export CD_GITHUB_TOKEN="cd_token"
./github-repo-from-template.sh new-project-name
```

## Usage

### Basic Workflow

1. **Navigate to the script directory:**
   ```bash
   cd github-<script-name>
   ```

2. **Set required environment variables:**
   ```bash
   export GITHUB_TOKEN="your_token"
   export ORG="your-org"
   # ... other variables as needed
   ```

3. **Run the script:**
   ```bash
   ./github-<script-name>.sh [arguments]
   ```

### Tips

- **Rate limiting:** Scripts include delays to avoid hitting GitHub's rate limits. For large organizations, expect longer execution times.
- **Dry run:** Consider testing scripts on a test organization first to verify behavior.
- **Logging:** Redirect output to a file for audit trails: `./script.sh 2>&1 | tee execution.log`
- **Customization:** All scripts are designed to be easily modified for your specific needs.

### Advanced Usage

**Custom GitHub Enterprise Server:**

```bash
export API_URL_PREFIX="https://github.company.com/api/v3"
export GIT_URL_PREFIX="https://github.company.com"
```

**Using with GitHub Enterprise Cloud:**

```bash
export API_URL_PREFIX="https://api.github.com"
export GIT_URL_PREFIX="https://github.com"
```

## Contributing

Contributions are welcome! If you have a useful GitHub automation script or improvements to existing ones:

1. Fork the repository
2. Create a feature branch
3. Add your script with documentation
4. Submit a pull request

## Resources

- [GitHub REST API Documentation](https://docs.github.com/en/rest)
- [Creating a personal access token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token)
- [jq Manual](https://stedolan.github.io/jq/manual/)
- [curl Documentation](https://curl.se/docs/)
