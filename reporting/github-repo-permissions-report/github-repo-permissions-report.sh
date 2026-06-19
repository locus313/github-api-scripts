#!/bin/bash
# =============================================================================
# github-repo-permissions-report.sh
#
# Export GitHub repository user/team permissions to CSV and identify who can
# bypass pull request approval requirements on a protected branch.
#
# Output:
#   A single CSV with two record types:
#   - permission    : collaborators/teams and whether they can bypass approvals
#   - bypass_actor  : explicit bypass actors from branch protection and rulesets
#
# Requirements:
#   - gh CLI authenticated with access to the target repository
#   - jq
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/github-common.sh
source "${SCRIPT_DIR}/../../lib/github-common.sh"

API_VERSION="2022-11-28"
REPO=""
BRANCH=""
OUTPUT_CSV=""

usage() {
  cat <<'EOF'
Usage: github-repo-permissions-report.sh -r OWNER/REPO [options]

Create a CSV report of repository permissions and branch-approval bypass actors.

Required:
  -r, --repo OWNER/REPO      Target repository

Optional:
  -b, --branch NAME          Branch to evaluate (default: repository default branch)
  -o, --output FILE          Output CSV path
  -h, --help                 Show this help

Examples:
  github-repo-permissions-report.sh -r my-org/my-repo
  github-repo-permissions-report.sh -r my-org/my-repo -b main -o repo-perms.csv
EOF
}

err()  { print_error  "$*"; exit 1; }
info() { print_status "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--repo)
      REPO="${2:-}"
      shift 2
      ;;
    -b|--branch)
      BRANCH="${2:-}"
      shift 2
      ;;
    -o|--output)
      OUTPUT_CSV="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown option: $1"
      ;;
  esac
done

[[ -z "$REPO" ]] && err "Repository is required. Use -r OWNER/REPO"

require_command gh
require_command jq

gh auth status >/dev/null 2>&1 || err "gh is not authenticated. Run: gh auth login"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REPO_JSON="${TMP_DIR}/repo.json"
COLLAB_JSON="${TMP_DIR}/collaborators.json"
TEAMS_JSON="${TMP_DIR}/teams.json"
BP_JSON="${TMP_DIR}/branch_protection.json"
RULESETS_JSON="${TMP_DIR}/rulesets.json"
BYPASS_JSON="${TMP_DIR}/bypass.json"

gh_api() {
  gh api \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    "$@"
}

info "Fetching repository metadata for ${REPO}..."
gh_api "/repos/${REPO}" > "$REPO_JSON"
DEFAULT_BRANCH="$(jq -r '.default_branch // empty' "$REPO_JSON")"
[[ -z "$DEFAULT_BRANCH" ]] && err "Unable to determine default branch for ${REPO}"

if [[ -z "$BRANCH" ]]; then
  BRANCH="$DEFAULT_BRANCH"
fi

if [[ -z "$OUTPUT_CSV" ]]; then
  OUTPUT_CSV="${REPO//\//-}-permissions-${BRANCH}-$(date +%Y%m%d).csv"
fi

info "Fetching collaborators..."
gh_api --paginate \
  "/repos/${REPO}/collaborators?affiliation=all&per_page=100" \
  --jq '.[]' | jq -s '.' > "$COLLAB_JSON"

info "Fetching teams with repository access..."
gh_api --paginate \
  "/repos/${REPO}/teams?per_page=100" \
  --jq '.[]' | jq -s '.' > "$TEAMS_JSON"

info "Fetching branch protection for ${BRANCH} (if configured)..."
if gh_api "/repos/${REPO}/branches/${BRANCH}/protection" > "$BP_JSON" 2>/dev/null; then
  :
else
  echo '{}' > "$BP_JSON"
fi

info "Fetching repository rulesets (if configured)..."
if gh_api --paginate \
  "/repos/${REPO}/rulesets?includes_parents=true&per_page=100" \
  --jq '.[]' | jq -s '.' > "$RULESETS_JSON" 2>/dev/null; then
  :
else
  echo '[]' > "$RULESETS_JSON"
fi

info "Building bypass actor list (branch protection + applicable rulesets)..."
jq -n \
  --argjson bp "$(cat "$BP_JSON")" \
  --argjson rulesets "$(cat "$RULESETS_JSON")" \
  --arg ref "refs/heads/${BRANCH}" \
  --arg default_branch "$DEFAULT_BRANCH" '
  def glob_to_re:
    "^" +
    (
      gsub("([][.^$+?(){}|\\\\])"; "\\\\\\\\\\1")
      | gsub("\\*\\*"; ".*")
      | gsub("\\*"; "[^/]*")
    ) +
    "$";

  def ref_match($pat):
    if $pat == "~ALL" then true
    elif $pat == "~DEFAULT_BRANCH" then $ref == ("refs/heads/" + $default_branch)
    elif ($pat | startswith("refs/")) then ($ref | test($pat | glob_to_re))
    else false
    end;

  def applies_to_ref($rs):
    ($rs.target == "branch")
    and ((($rs.enforcement // "active") | ascii_downcase) != "disabled")
    and (
      ((($rs.conditions.ref_name.include // ["~ALL"]) | map(ref_match(.))) | any)
      and (((($rs.conditions.ref_name.exclude // []) | map(ref_match(.))) | any) | not)
    );

  [
    ($bp.required_pull_request_reviews.bypass_pull_request_allowances.users[]? |
      {
        principal_type: "user",
        principal: .login,
        bypass_mode: "pull_request",
        source: "branch_protection",
        reason: "Explicit branch protection bypass allowance"
      }
    ),
    ($bp.required_pull_request_reviews.bypass_pull_request_allowances.teams[]? |
      {
        principal_type: "team",
        principal: .slug,
        bypass_mode: "pull_request",
        source: "branch_protection",
        reason: "Explicit branch protection bypass allowance"
      }
    ),
    ($bp.required_pull_request_reviews.bypass_pull_request_allowances.apps[]? |
      {
        principal_type: "app",
        principal: .slug,
        bypass_mode: "pull_request",
        source: "branch_protection",
        reason: "Explicit branch protection bypass allowance"
      }
    ),
    (
      if (($bp.required_pull_request_reviews.required_approving_review_count // 0) > 0)
         and ((($bp.enforce_admins.enabled // false) | not))
      then
        {
          principal_type: "role",
          principal: "repo_admins",
          bypass_mode: "always",
          source: "branch_protection",
          reason: "Admins are exempt because enforce_admins is disabled"
        }
      else empty end
    ),
    (
      $rulesets[]
      | select(applies_to_ref(.)) as $rs
      | $rs.bypass_actors[]?
      | {
          principal_type: (.actor_type | ascii_downcase),
          principal: (
            if .actor_type == "Team" then ("team_id:" + ((.actor_id // 0) | tostring))
            elif .actor_type == "Integration" then ("app_id:" + ((.actor_id // 0) | tostring))
            elif .actor_type == "RepositoryRole" then ("repository_role_id:" + ((.actor_id // 0) | tostring))
            elif .actor_type == "OrganizationAdmin" then "organization_admins"
            else ((.actor_type | ascii_downcase) + "_id:" + ((.actor_id // 0) | tostring))
            end
          ),
          bypass_mode: (.bypass_mode // "always"),
          source: ("ruleset:" + ($rs.name // ("id_" + (($rs.id // 0) | tostring)))),
          reason: "Ruleset bypass actor"
        }
    )
  ]
' > "$BYPASS_JSON"

info "Normalizing team references in bypass data..."
jq -n \
  --argjson bypass "$(cat "$BYPASS_JSON")" \
  --argjson teams "$(cat "$TEAMS_JSON")" '
  def team_name_from_id($id):
    ($teams[] | select((.id | tostring) == $id) | .slug) // ("team_id:" + $id);

  $bypass
  | map(
      if .principal_type == "team" and (.principal | startswith("team_id:")) then
        .principal = team_name_from_id((.principal | split(":")[1])
      )
      else
        .
      end
    )
' > "$BYPASS_JSON.tmp"
mv "$BYPASS_JSON.tmp" "$BYPASS_JSON"

info "Generating CSV report: ${OUTPUT_CSV}"
jq -r -n \
  --arg repo "$REPO" \
  --arg branch "$BRANCH" \
  --argjson collabs "$(cat "$COLLAB_JSON")" \
  --argjson teams "$(cat "$TEAMS_JSON")" \
  --argjson bypass "$(cat "$BYPASS_JSON")" '
  def effective_permission($c):
    ($c.role_name //
      (if $c.permissions.admin then "admin"
       elif $c.permissions.maintain then "maintain"
       elif $c.permissions.push then "push"
       elif $c.permissions.triage then "triage"
       else "pull" end));

  def user_bypass_reasons($login; $perm):
    [
      $bypass[]
      | select(
          (.principal_type == "user" and .principal == $login)
          or (.principal_type == "role" and .principal == "repo_admins" and $perm == "admin")
        )
      | .reason
    ];

  def team_bypass_reasons($slug):
    [
      $bypass[]
      | select(.principal_type == "team" and .principal == $slug)
      | .reason
    ];

  (
    [
      "record_type",
      "repo",
      "branch",
      "principal_type",
      "principal_name",
      "permission",
      "role_name",
      "can_bypass_pr_approvals",
      "bypass_mode",
      "source",
      "notes"
    ]
    | @csv
  ),

  (
    $collabs[] as $c
    | (effective_permission($c)) as $perm
    | (user_bypass_reasons($c.login; $perm)) as $reasons
    | [
        "permission",
        $repo,
        $branch,
        "user",
        $c.login,
        $perm,
        ($c.role_name // ""),
        (if ($reasons | length) > 0 then "true" else "false" end),
        (if ($reasons | length) > 0 then "pull_request_or_always" else "" end),
        "collaborator",
        ($reasons | unique | join("; "))
      ]
    | @csv
  ),

  (
    $teams[] as $t
    | ($t.permission // "") as $perm
    | (team_bypass_reasons($t.slug)) as $reasons
    | [
        "permission",
        $repo,
        $branch,
        "team",
        $t.slug,
        $perm,
        "",
        (if ($reasons | length) > 0 then "true" else "false" end),
        (if ($reasons | length) > 0 then "pull_request_or_always" else "" end),
        "team_access",
        ($reasons | unique | join("; "))
      ]
    | @csv
  ),

  (
    $bypass[]
    | [
        "bypass_actor",
        $repo,
        $branch,
        .principal_type,
        .principal,
        "",
        "",
        "true",
        (.bypass_mode // "always"),
        .source,
        .reason
      ]
    | @csv
  )
' > "$OUTPUT_CSV"

TOTAL_USERS="$(jq 'length' "$COLLAB_JSON")"
TOTAL_TEAMS="$(jq 'length' "$TEAMS_JSON")"
TOTAL_BYPASS="$(jq 'length' "$BYPASS_JSON")"

print_success "Done."
echo "Report file: ${OUTPUT_CSV}"
echo "Users: ${TOTAL_USERS} | Teams: ${TOTAL_TEAMS} | Bypass actors: ${TOTAL_BYPASS}"
