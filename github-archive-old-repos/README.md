# GitHub Archive Old Repositories

A Bash script to identify and archive GitHub repositories that haven't been updated in the last 5 years.

## Features

- ✅ Fetches all repositories from a GitHub organization
- ✅ Filters repos not updated in the last 5 years (configurable)
- ✅ Generates a timestamped CSV report with repository details
- ✅ Shows summary with top 10 oldest repositories
- ✅ Interactive approval prompt before archiving
- ✅ Archives repositories via GitHub API
- ✅ Skips already archived repositories
- ✅ Colored output for better readability
- ✅ Rate limiting protection

## Prerequisites

- **GitHub Personal Access Token** with `repo` permissions
- **jq** - JSON parser for bash
  - macOS: `brew install jq`
  - Ubuntu/Debian: `sudo apt-get install jq`

## Usage

### Environment Variables

```bash
export GITHUB_TOKEN="your_github_personal_access_token"
export ORG="your-org-name"
export YEARS_THRESHOLD=5        # Optional, defaults to 5 years
```

### Run the Script

```bash
./github-archive-old-repos.sh
```

### What It Does

1. **Validates** your GitHub token and environment
2. **Calculates** cutoff date (5 years ago by default)
3. **Fetches** all repositories from the organization
4. **Filters** repos not updated since the cutoff date
5. **Generates** CSV report: `old_repos_YYYYMMDD_HHMMSS.csv`
6. **Displays** summary with top 10 oldest repos
7. **Prompts** for confirmation before archiving
8. **Archives** repositories if approved

### Output Files

The script generates a CSV report with the following columns:
- `name` - Repository name
- `full_name` - Full repository name (org/repo)
- `private` - Whether the repo is private
- `archived` - Current archive status
- `html_url` - Repository URL
- `description` - Repository description
- `fork` - Whether it's a fork
- `last_updated` - Last update timestamp
- `days_since_update` - Days since last update

**Example:** `old_repos_20251015_143022.csv`

## Safety Features

- **Interactive approval** - Script asks for confirmation before archiving
- **Skips archived repos** - Won't try to archive already archived repositories
- **Rate limiting** - 2-second delay between archive operations
- **Token validation** - Validates GitHub token before proceeding
- **Detailed logging** - Color-coded status messages

## What Archiving Does

When a repository is archived:
- ✅ It becomes **read-only**
- ✅ No new issues, pull requests, or comments can be created
- ✅ GitHub Actions workflows are disabled
- ✅ The repository remains visible and cloneable
- ⚠️ **This action can be reversed** by organization admins

## Customization

### Change the Age Threshold

```bash
# Archive repos older than 3 years
export YEARS_THRESHOLD=3
./github-archive-old-repos.sh
```

### Different Organization

```bash
export ORG="your-org-name"
./github-archive-old-repos.sh
```

## Example Output

```
[INFO] GitHub Old Repository Archival Tool
[INFO] =====================================
[INFO] Validating environment...
[SUCCESS] Environment validation complete
[INFO] Cutoff date: 2020-10-15T00:00:00Z (repos not updated since this date will be identified)
[INFO] Fetching repositories from organization: your-org-name
[INFO] Processing page 1...
[INFO] Processing page 2...

==========================================
          SUMMARY REPORT
==========================================
Organization: your-org-name
Cutoff threshold: 5 years
Total old repositories found: 15
Report saved to: old_repos_20251015_143022.csv
==========================================

[WARNING] Found 15 repositories not updated in the last 5 years

Top 10 oldest repositories:
----------------------------
  - legacy-app (last updated: 2018-05-10T14:30:22Z, 2714 days ago)
  - old-project (last updated: 2019-01-15T09:12:05Z, 2465 days ago)
  ...

[WARNING] You are about to archive 15 repositories.
[WARNING] This action will:
[WARNING]   - Make repositories read-only
[WARNING]   - Prevent new issues, pull requests, and comments
[WARNING]   - Disable Actions workflows

Do you want to proceed with archiving these repositories? (yes/no): yes

[INFO] Proceeding with archival...
[INFO] Archiving repository: legacy-app (last updated: 2018-05-10T14:30:22Z)
[SUCCESS] Archived: legacy-app
...
[SUCCESS] Script execution complete!
```

## GitHub Actions Integration

You can run this script in a GitHub Actions workflow. See example workflow below:

```yaml
name: Archive Old Repositories

on:
  workflow_dispatch:  # Manual trigger
  schedule:
    - cron: '0 0 1 * *'  # Monthly on 1st day at midnight

jobs:
  archive-old-repos:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v3
      
      - name: Install jq
        run: sudo apt-get install -y jq
      
      - name: Run Archive Script
        env:
          GITHUB_TOKEN: ${{ secrets.GH_TOKEN }}
          ORG: your-org-name
          YEARS_THRESHOLD: 5
        run: |
          cd github-archive-old-repos
          chmod +x github-archive-old-repos.sh
          ./github-archive-old-repos.sh
      
      - name: Upload Report
        uses: actions/upload-artifact@v3
        with:
          name: archive-report
          path: github-archive-old-repos/old_repos_*.csv
```

## Troubleshooting

### "GITHUB_TOKEN is invalid"
- Ensure your token has `repo` scope
- Generate a new token at: https://github.com/settings/tokens

### "jq is not installed"
- Install jq using your package manager (see Prerequisites)

### No repositories found
- Check the `YEARS_THRESHOLD` value
- Verify you're using the correct organization name

## Related Scripts

- [`github-get-repo-list`](../github-get-repo-list/) - Get all repos without filtering
- [`github-add-repo-permissions`](../github-add-repo-permissions/) - Bulk permission management

## License

See [LICENSE](../LICENSE) in the root directory.
