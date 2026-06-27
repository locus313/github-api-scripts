#!/usr/bin/env bash
# =============================================================================
# github-dockerfile-discovery.sh
#
# Searches all organisations in a GitHub Enterprise account for Dockerfiles,
# extracts base image references from FROM instructions, and generates CSV
# reports to identify common base images across the estate.
#
# Usage:
#   export GITHUB_TOKEN=ghp_yourtoken
#   export ENTERPRISE=my-enterprise
#   ./github-dockerfile-discovery.sh
#
# Environment variables:
#   GITHUB_TOKEN    Required. PAT with read:org and repo scope
#   ENTERPRISE      Required. GitHub Enterprise slug
#   API_URL_PREFIX  Optional. GitHub API base URL (default: https://api.github.com)
#   REPORT_DIR      Optional. Output directory (default: ./reports)
#   ORGS            Optional. Comma-separated org list; skips enterprise lookup
#   ORG_FILTER      Optional. ERE regex to keep only matching org names
#   ORG_EXCLUDE     Optional. ERE regex to drop matching org names
#   SEARCH_SLEEP    Optional. Seconds between code-search requests (default: 2)
#   CONTENT_SLEEP   Optional. Seconds between content-fetch requests (default: 1)
#
# Requirements:
#   - curl
#   - jq
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/github-common.sh
source "${SCRIPT_DIR}/../../lib/github-common.sh"

###
## GLOBAL VARIABLES
###
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ENTERPRISE=${ENTERPRISE:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
ORGS_OVERRIDE=${ORGS:-''}
ORG_FILTER=${ORG_FILTER:-''}
ORG_EXCLUDE=${ORG_EXCLUDE:-''}
REPORT_DIR=${REPORT_DIR:-'./reports'}
SEARCH_SLEEP=${SEARCH_SLEEP:-2}
CONTENT_SLEEP=${CONTENT_SLEEP:-1}

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DETAIL_CSV="${REPORT_DIR}/dockerfile_discovery_detail_${TIMESTAMP}.csv"
SUMMARY_CSV="${REPORT_DIR}/dockerfile_discovery_summary_${TIMESTAMP}.csv"
SUMMARY_TXT="${REPORT_DIR}/dockerfile_discovery_summary_${TIMESTAMP}.txt"

###
## Temp file management
###
TEMP_DIR=$(mktemp -d)
DETAIL_TEMP="${TEMP_DIR}/detail_rows.csv"   # accumulates detail rows during scan
REFS_TEMP="${TEMP_DIR}/dockerfile_refs.tsv" # org TAB repo_full_name TAB path TAB html_url

cleanup() {
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

###
## search_dockerfiles_in_org <org>
## Appends TSV rows (org TAB repo_full_name TAB path TAB html_url) to REFS_TEMP
###
search_dockerfiles_in_org() {
  local org="$1"
  local page=1
  local total_fetched=0

  while true; do
    sleep "${SEARCH_SLEEP}"
    local resp
    resp=$(gh_api "/search/code?q=filename:Dockerfile+org:${org}&per_page=100&page=${page}")

    if [[ "${resp}" == "__422__" || "${resp}" == "__404__" ]]; then
      print_warning "  Code search not available for org '${org}'. Skipping."
      return 0
    fi

    local items_on_page
    items_on_page=$(echo "${resp}" | jq -r '.items | length')
    local total_count
    total_count=$(echo "${resp}" | jq -r '.total_count')

    if [ "${items_on_page}" -eq 0 ]; then
      break
    fi

    # Write each result as a TSV row
    echo "${resp}" | jq -r --arg org "${org}" \
      '.items[] | [$org, .repository.full_name, .path, .html_url] | @tsv' \
      >> "${REFS_TEMP}"

    total_fetched=$(( total_fetched + items_on_page ))

    if [ "${total_fetched}" -ge "${total_count}" ] || [ "${total_fetched}" -ge 1000 ]; then
      if [ "${total_fetched}" -ge 1000 ] && [ "${total_count}" -gt 1000 ]; then
        print_warning "  Code search cap (1000) reached for org '${org}'. Some Dockerfiles may be missed."
      fi
      break
    fi
    page=$(( page + 1 ))
  done
}

###
## parse_dockerfile_content <org> <repo_full_name> <dockerfile_path> <html_url>
## Reads Dockerfile content from stdin, extracts FROM instructions,
## and appends rows to DETAIL_TEMP
###
parse_dockerfile_content() {
  local org="$1"
  local repo_full_name="$2"
  local dockerfile_path="$3"
  local html_url="$4"
  local content
  content=$(cat)   # read from stdin

  if [ -z "${content}" ]; then
    return 0
  fi

  # Collect ARG defaults for variable substitution
  # Build a sed replacement script: s/\$VAR/default/g and s/\${VAR}/default/g
  local arg_sed_script=""
  while IFS= read -r arg_line; do
    local arg_name arg_default
    arg_name=$(echo "${arg_line}" | sed -E 's/^ARG[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)(=.*)?$/\1/')
    arg_default=$(echo "${arg_line}" | sed -E 's/^ARG[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=?//')
    if [ -n "${arg_default}" ]; then
      # Escape special chars in default for use in sed replacement
      # Strip newlines and escape &, /, \, and ; to prevent sed script injection
      local safe_default
      safe_default=$(printf '%s' "${arg_default}" | tr -d '\n' | sed 's/[&/\;]/\\&/g')
      arg_sed_script="${arg_sed_script}s/\\\${${arg_name}}/${safe_default}/g;"
      arg_sed_script="${arg_sed_script}s/\\\$${arg_name}\b/${safe_default}/g;"
    fi
  done < <(echo "${content}" | grep -Ei '^ARG[[:space:]]+' || true)

  # Extract and process FROM instructions
  local stage=0
  while IFS= read -r from_line; do
    stage=$(( stage + 1 ))

    # Strip leading FROM (case-insensitive) and optional --platform=...
    local rest
    rest=$(echo "${from_line}" | sed -E 's/^FROM[[:space:]]+//i' | sed -E 's/--platform=[^ ]+[[:space:]]*//')

    # Remove trailing AS alias
    rest=$(echo "${rest}" | sed -E 's/[[:space:]]+AS[[:space:]]+[^ ]+$//i')
    rest=$(echo "${rest}" | xargs)  # trim whitespace

    # Apply ARG variable substitutions
    if [ -n "${arg_sed_script}" ]; then
      rest=$(echo "${rest}" | sed "${arg_sed_script}" || echo "${rest}")
    fi

    # Split image:tag and optional @digest
    local image tag digest base_image
    digest=""

    # Extract @sha256:... digest if present
    if echo "${rest}" | grep -q '@sha256:'; then
      digest=$(echo "${rest}" | grep -oE '@sha256:[a-f0-9]+' | tr -d '@')
      rest=$(echo "${rest}" | sed 's/@sha256:[a-f0-9]*//')
    fi

    # Split on colon for tag
    if echo "${rest}" | grep -q ':'; then
      image=$(echo "${rest}" | cut -d: -f1)
      tag=$(echo "${rest}" | cut -d: -f2)
    else
      image="${rest}"
      tag="latest"
    fi

    base_image="${image}:${tag}"

    # Skip if image is empty (malformed FROM line)
    if [ -z "${image}" ]; then
      continue
    fi

    # Sanitize fields for CSV (escape double-quotes, wrap in quotes)
    local safe_path safe_url
    safe_path=$(echo "${dockerfile_path}" | sed 's/"/""/g')
    safe_url=$(echo "${html_url}" | sed 's/"/""/g')
    local safe_image safe_tag safe_digest safe_base
    safe_image=$(echo "${image}" | sed 's/"/""/g')
    safe_tag=$(echo "${tag}" | sed 's/"/""/g')
    safe_digest=$(echo "${digest}" | sed 's/"/""/g')
    safe_base=$(echo "${base_image}" | sed 's/"/""/g')
    local repo_name
    repo_name=$(echo "${repo_full_name}" | cut -d/ -f2)

    echo "${org},${repo_name},\"${repo_full_name}\",\"${safe_path}\",${stage},\"${safe_image}\",\"${safe_tag}\",\"${safe_digest}\",\"${safe_base}\",\"${safe_url}\"" \
      >> "${DETAIL_TEMP}"

  done < <(echo "${content}" | grep -Ei '^FROM[[:space:]]+' || true)
}

###
## fetch_and_parse_dockerfile <org> <repo_full_name> <path> <html_url>
###
fetch_and_parse_dockerfile() {
  local org="$1"
  local repo_full_name="$2"
  local path="$3"
  local html_url="$4"

  sleep "${CONTENT_SLEEP}"

  local resp
  # URL-encode the path for the API call
  local encoded_path
  encoded_path=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "${path}" 2>/dev/null \
    || echo "${path}" | sed 's/ /%20/g')

  resp=$(gh_api "/repos/${repo_full_name}/contents/${encoded_path}" 2>/dev/null || echo "")

  if [[ -z "${resp}" || "${resp}" == "__404__" || "${resp}" == "__422__" ]]; then
    print_warning "    Could not fetch ${repo_full_name}/${path}"
    return 0
  fi

  local encoding
  encoding=$(echo "${resp}" | jq -r '.encoding // empty')

  if [ "${encoding}" != "base64" ]; then
    print_warning "    Unexpected encoding '${encoding}' for ${repo_full_name}/${path}"
    return 0
  fi

  local content
  content=$(echo "${resp}" | jq -r '.content' | tr -d '\n' | base64 -d 2>/dev/null || true)

  if [ -z "${content}" ]; then
    print_warning "    Empty content for ${repo_full_name}/${path}"
    return 0
  fi

  echo "${content}" | parse_dockerfile_content "${org}" "${repo_full_name}" "${path}" "${html_url}"
}

###
## build_summary_csv
## Reads DETAIL_TEMP and produces SUMMARY_CSV
###
build_summary_csv() {
  print_status "Building summary report..."

  # Write header
  echo "base_image,image,tag,count_dockerfiles,repos" > "${SUMMARY_CSV}"

  # Extract base_image column (col 9) from detail rows, skip header
  # Count occurrences and collect repos (col 3 = repo_full_name)
  # Use awk for aggregation
  awk -F',' 'NR>1 {
    # Strip surrounding quotes
    gsub(/"/, "", $9)
    gsub(/"/, "", $3)
    count[$9]++
    # Avoid duplicate repos
    key = $9 SUBSEP $3
    if (!(key in seen)) {
      seen[key] = 1
      if (repos[$9] == "") {
        repos[$9] = $3
      } else {
        repos[$9] = repos[$9] "; " $3
      }
    }
  }
  END {
    for (img in count) {
      split(img, parts, ":")
      image = parts[1]
      tag = (length(parts) > 1) ? parts[2] : "latest"
      printf "%s,%s,%s,%d,\"%s\"\n", img, image, tag, count[img], repos[img]
    }
  }' "${DETAIL_TEMP}" \
    | sort -t',' -k4 -rn \
    >> "${SUMMARY_CSV}"
}

###
## build_text_summary
## Produces a human-readable summary TXT file
###
build_text_summary() {
  local total_dockerfiles total_repos total_images
  total_dockerfiles=$(awk -F',' 'NR>1' "${DETAIL_TEMP}" | awk -F',' '{print $3","$4}' | sort -u | wc -l | xargs)
  total_repos=$(awk -F',' 'NR>1 {gsub(/"/, "", $3); print $3}' "${DETAIL_TEMP}" | sort -u | wc -l | xargs)
  total_images=$(awk -F',' 'NR>1 {gsub(/"/, "", $9); print $9}' "${DETAIL_TEMP}" | sort -u | wc -l | xargs)

  {
    printf '%.0s=' {1..70}
    echo
    echo "  GitHub Enterprise Dockerfile Discovery — Summary Report"
    echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    printf '%.0s=' {1..70}
    echo
    echo
    printf "  Total Dockerfiles scanned  : %s\n" "${total_dockerfiles}"
    printf "  Total repos with Dockerfiles: %s\n" "${total_repos}"
    printf "  Unique base images found   : %s\n" "${total_images}"
    echo
    printf '%.0s-' {1..70}
    echo
    echo "  TOP BASE IMAGES (by number of Dockerfiles)"
    printf '%.0s-' {1..70}
    echo
    awk -F',' 'NR>1 {printf "  %-55s (%s Dockerfiles)\n", $1, $4}' "${SUMMARY_CSV}" | head -30
    echo
  } > "${SUMMARY_TXT}"
}

###
## MAIN
###
main() {
  require_command curl
  require_command jq
  require_command base64
  require_env_var GITHUB_TOKEN "GITHUB_TOKEN"
  validate_github_token

  mkdir -p "${REPORT_DIR}"

  # Write detail CSV header
  echo "org,repo,repo_full_name,dockerfile_path,stage,image,tag,digest,base_image,dockerfile_url" \
    > "${DETAIL_TEMP}"

  touch "${REFS_TEMP}"

  # ── Determine orgs to scan ───────────────────────────────────────────────
  local orgs=()
  if [ -n "${ORGS_OVERRIDE}" ]; then
    print_status "Using ORGS override: ${ORGS_OVERRIDE}"
    IFS=',' read -ra orgs <<< "${ORGS_OVERRIDE}"
  else
    while IFS= read -r org; do
      orgs+=("${org}")
    done < <(get_enterprise_orgs)
  fi

  if [ "${#orgs[@]}" -eq 0 ]; then
    print_error "No organisations found. Check ENTERPRISE slug and token permissions."
    exit 1
  fi

# ── Apply ORG_FILTER (inclusion) if set ────────────────────────────────
  if [ -n "${ORG_FILTER}" ]; then
    local _rc=0
    echo "" | grep -qE "${ORG_FILTER}" 2>/dev/null || _rc=$?
    if [ "${_rc}" -eq 2 ]; then
      print_error "ORG_FILTER is not a valid ERE regex: ${ORG_FILTER}"
      exit 1
    fi
    local filtered=()
    for org in "${orgs[@]}"; do
      if echo "${org}" | grep -qE "${ORG_FILTER}"; then
        filtered+=("${org}")
      fi
    done
    local removed=$(( ${#orgs[@]} - ${#filtered[@]} ))
    orgs=("${filtered[@]+"${filtered[@]}"}") 
    print_status "ORG_FILTER='${ORG_FILTER}' — kept ${#orgs[@]} org(s), excluded ${removed}"
  fi

  # ── Apply ORG_EXCLUDE (exclusion) if set ────────────────────────────────
  if [ -n "${ORG_EXCLUDE}" ]; then
    local _rc=0
    echo "" | grep -qE "${ORG_EXCLUDE}" 2>/dev/null || _rc=$?
    if [ "${_rc}" -eq 2 ]; then
      print_error "ORG_EXCLUDE is not a valid ERE regex: ${ORG_EXCLUDE}"
      exit 1
    fi
    local kept=()
    for org in "${orgs[@]}"; do
      if ! echo "${org}" | grep -qE "${ORG_EXCLUDE}"; then
        kept+=("${org}")
      fi
    done
    local removed=$(( ${#orgs[@]} - ${#kept[@]} ))
    orgs=("${kept[@]+"${kept[@]}"}") 
    print_status "ORG_EXCLUDE='${ORG_EXCLUDE}' — kept ${#orgs[@]} org(s), excluded ${removed}"
  fi

  if [ "${#orgs[@]}" -eq 0 ]; then
    print_error "No organisations remain after applying ORG_FILTER/ORG_EXCLUDE filters."
    exit 1
  fi
  print_success "Found ${#orgs[@]} organisation(s): ${orgs[*]}"

  # ── Discover Dockerfiles via code search ─────────────────────────────────
  for org in "${orgs[@]}"; do
    print_status "Searching for Dockerfiles in org: ${org}"
    search_dockerfiles_in_org "${org}"
    local found
    found=$(grep -c "^${org}	" "${REFS_TEMP}" 2>/dev/null || true)
    print_status "  Found ${found} Dockerfile(s) in '${org}'"
  done

  local total_refs
  total_refs=$(wc -l < "${REFS_TEMP}" | xargs)
  print_success "Total Dockerfiles discovered: ${total_refs}"

  if [ "${total_refs}" -eq 0 ]; then
    print_warning "No Dockerfiles found across all organisations."
    exit 0
  fi

  # De-duplicate by (repo_full_name, path)
  sort -u -t$'\t' -k2,3 "${REFS_TEMP}" -o "${REFS_TEMP}"
  local unique_refs
  unique_refs=$(wc -l < "${REFS_TEMP}" | xargs)
  print_status "Unique Dockerfiles to fetch: ${unique_refs}"

  # ── Fetch content and parse FROM instructions ─────────────────────────────
  local idx=0
  while IFS=$'\t' read -r org repo_full_name path html_url; do
    (( idx++ )) || true
    print_status "  [${idx}/${unique_refs}] ${repo_full_name}/${path}"
    fetch_and_parse_dockerfile "${org}" "${repo_full_name}" "${path}" "${html_url}"
  done < "${REFS_TEMP}"

  local parsed_rows
  parsed_rows=$(( $(wc -l < "${DETAIL_TEMP}" | xargs) - 1 ))  # subtract header

  if [ "${parsed_rows}" -le 0 ]; then
    print_warning "Could not parse any FROM instructions."
    exit 0
  fi

  print_success "Parsed ${parsed_rows} FROM instruction(s) across all Dockerfiles"

  # ── Copy detail CSV to final location ────────────────────────────────────
  cp "${DETAIL_TEMP}" "${DETAIL_CSV}"

  # ── Build summary reports ─────────────────────────────────────────────────
  build_summary_csv
  build_text_summary

  print_success "Detail CSV  : ${DETAIL_CSV}"
  print_success "Summary CSV : ${SUMMARY_CSV}"
  print_success "Summary TXT : ${SUMMARY_TXT}"

  # ── Print top-10 to stdout ────────────────────────────────────────────────
  echo
  printf '%.0s=' {1..70}
  echo
  echo "  TOP 10 BASE IMAGES"
  printf '%.0s=' {1..70}
  echo
  awk -F',' 'NR>1 && NR<=11 {printf "  %2d. %-50s x%s\n", NR-1, $1, $4}' "${SUMMARY_CSV}"
  echo
}

main "$@"
