# GitHub Enterprise Dockerfile Discovery

Scans every organisation in a GitHub Enterprise account, finds all Dockerfiles,
and generates a report showing which base images (and versions) are in use.
The goal is to identify common base images across the entire estate.

## How it works

1. Uses the GitHub Enterprise API to list all organisations.
2. Uses the GitHub Code Search API (`filename:Dockerfile`) to find every Dockerfile in each org.
3. Fetches each Dockerfile's raw content via the Contents API.
4. Parses all `FROM` instructions, including multi-stage builds and `--platform` flags.
5. Produces three output files:
   - **detail CSV** — one row per FROM instruction (org, repo, path, image, tag, stage, …)
   - **summary CSV** — one row per unique `image:tag`, sorted by frequency
   - **summary TXT** — human-readable top-30 table

## Prerequisites

- `curl`
- `jq`
- `base64` (standard on Linux/macOS)
- A GitHub **Personal Access Token** (classic) or a GitHub App token with at minimum:
  - `read:org` — list organisations and search code
  - `repo` — read file contents (or `public_repo` for public repos only)

> **Org discovery — 3-step strategy**:
> 1. **REST enterprise endpoint** (`/enterprises/{slug}/organizations`) — requires an enterprise-owner token.
> 2. **GraphQL enterprise query** (`enterprise(slug).organizations`) — works for enterprise members with `read:org`.
> 3. **`/user/orgs` fallback** — returns every org the token owner belongs to (may include non-enterprise orgs).
>
> If step 3 is reached and the list includes orgs outside your enterprise, use `ORG_FILTER` to restrict the scan:
> ```bash
> export ORG_FILTER='^your-enterprise-prefix'
> ```

## Usage

```bash
export GITHUB_TOKEN=ghp_yourtoken
export ENTERPRISE=my-enterprise     # GitHub Enterprise slug

./github-dockerfile-discovery.sh
```

Reports are written to `./reports/` by default.

## Environment Variables

| Variable        | Required | Default                   | Description                                      |
|-----------------|----------|---------------------------|--------------------------------------------------|
| `GITHUB_TOKEN`  | Yes      | —                         | GitHub PAT or App token                          |
| `ENTERPRISE`    | No       | —                         | GitHub Enterprise slug                           |
| `API_URL_PREFIX`| No       | `https://api.github.com`  | Override for GHES instances                      |
| `REPORT_DIR`    | No       | `./reports`               | Output directory for CSV/TXT reports             |
| `ORGS`          | No       | —                         | Comma-separated org list; skips enterprise lookup|
| `ORG_FILTER`    | No       | —                         | ERE inclusion regex to keep only matching org names |
| `ORG_EXCLUDE`   | No       | —                         | ERE exclusion regex to drop matching org names |
| `SEARCH_SLEEP`  | No       | `2`                       | Seconds to sleep between code-search requests    |
| `CONTENT_SLEEP` | No       | `1`                       | Seconds to sleep between content-fetch requests  |

### Scanning specific orgs only

```bash
export ORGS="org-one,org-two"
./github-dockerfile-discovery.sh
```

## Output

### Detail CSV (`dockerfile_discovery_detail_<timestamp>.csv`)

| Column              | Description                                        |
|---------------------|----------------------------------------------------|
| `org`               | GitHub organisation name                           |
| `repo`              | Repository name                                    |
| `repo_full_name`    | `org/repo`                                         |
| `dockerfile_path`   | Path to Dockerfile within the repo                 |
| `stage`             | Build stage number (1 = first FROM, etc.)          |
| `image`             | Image name without tag                             |
| `tag`               | Tag (defaults to `latest` when not specified)      |
| `digest`            | SHA256 digest if pinned (empty otherwise)          |
| `base_image`        | `image:tag`                                        |
| `dockerfile_url`    | Direct GitHub URL to the Dockerfile                |

### Summary CSV (`dockerfile_discovery_summary_<timestamp>.csv`)

| Column              | Description                                        |
|---------------------|----------------------------------------------------|
| `base_image`        | `image:tag`                                        |
| `image`             | Image name without tag                             |
| `tag`               | Tag                                                |
| `count_dockerfiles` | Number of Dockerfiles using this image             |
| `repos`             | Semicolon-separated list of repos using it         |

## Notes

- **Rate limits**: The GitHub Code Search API allows 30 requests/minute for
  authenticated users. The script sleeps between requests to stay within limits.
  Large enterprises with many Dockerfiles may take several minutes to scan.
- **Code search cap**: GitHub code search returns a maximum of 1,000 results per
  query. Orgs with more than 1,000 Dockerfiles will be flagged with a warning.
- **ARG resolution**: `FROM $BASE_IMAGE` references are resolved to their default
  `ARG` values if defined. If no default exists the variable name is preserved.
- **Archived repos** are excluded from org repo enumeration but may still appear
  via code search hits.
