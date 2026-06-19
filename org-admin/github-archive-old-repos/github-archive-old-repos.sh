#!/bin/bash
# =============================================================================
# github-archive-old-repos.sh
#
# Identifies and archives repositories that have not been updated within a
# configurable number of years. Generates a timestamped CSV report of all
# archived repositories.
#
# Usage:
#   export GITHUB_TOKEN=ghp_yourtoken
#   export ORG=my-org
#   ./github-archive-old-repos.sh
#
# Environment variables:
#   GITHUB_TOKEN      Required. PAT with repo scope
#   ORG               Required. GitHub organization name
#   YEARS_THRESHOLD   Optional. Age threshold in years (default: 5)
#   API_URL_PREFIX    Optional. GitHub API base URL (default: https://api.github.com)
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
## CONFIGURATION
###
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
ORG=${ORG:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
YEARS_THRESHOLD=${YEARS_THRESHOLD:-5}
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_DIR="$(dirname "$0")/reports"
REPORT_FILE="${REPORT_DIR}/old_repos_${TIMESTAMP}.csv"
TEMP_FILE=$(mktemp)

###
## HELPER FUNCTIONS
###
cleanup() {
    rm -f "$TEMP_FILE"
}

trap cleanup EXIT

###
## VALIDATION
###
validate_environment() {
    print_status "Validating environment..."
    require_env_var GITHUB_TOKEN "GitHub token"
    require_env_var ORG "GitHub organization"
    require_command jq
    validate_github_token
    print_success "Environment validation complete"
}

###
## PAGINATION FUNCTIONS
###
get_repo_pagination() {
    repo_pages=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" -I "${API_URL_PREFIX}/orgs/${ORG}/repos?per_page=100" | grep -Eo '&page=[0-9]+' | grep -Eo '[0-9]+' | tail -1;)
    echo "${repo_pages:-1}"
}

limit_repo_pagination() {
    seq "$(get_repo_pagination)"
}

###
## DATE CALCULATION
###
calculate_cutoff_date() {
    # Calculate the cutoff date (5 years ago)
    # Using 'date' command compatible with both GNU and BSD date
    if date -v-1d > /dev/null 2>&1; then
        # BSD date (macOS)
        CUTOFF_DATE=$(date -u -v-${YEARS_THRESHOLD}y +"%Y-%m-%dT%H:%M:%SZ")
    else
        # GNU date (Linux)
        CUTOFF_DATE=$(date -u -d "${YEARS_THRESHOLD} years ago" +"%Y-%m-%dT%H:%M:%SZ")
    fi
    echo "$CUTOFF_DATE"
}

###
## MAIN PROCESSING
###
fetch_old_repos() {
    local cutoff_date="$1"
    local total_old_repos=0
    local PAGE
    local REPOS
    local REPO_NAME
    local REPO_PAYLOAD
    local REPO_FULLNAME
    local REPO_PRIVATE
    local REPO_ARCHIVED
    local REPO_HTMLURL
    local REPO_DESCRIPTION
    local REPO_FORK
    local REPO_UPDATEDAT
    local UPDATED_EPOCH
    local CURRENT_EPOCH
    local DAYS_SINCE
    local ESCAPED_DESC
    
    print_status "Cutoff date: $cutoff_date (repos not updated since this date will be identified)"
    print_status "Fetching repositories from organization: $ORG"
    
    # Initialize CSV with headers
    echo "name,full_name,private,archived,html_url,description,fork,last_updated,days_since_update" > "$REPORT_FILE"
    
    for PAGE in $(limit_repo_pagination); do
        print_status "Processing page $PAGE..."
        
        REPOS=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" "${API_URL_PREFIX}/orgs/${ORG}/repos?page=${PAGE}&per_page=100&sort=updated&direction=asc")
        
        while IFS= read -r REPO_NAME; do
            [ -z "${REPO_NAME}" ] && continue
            REPO_PAYLOAD=$(echo "$REPOS" | jq -r --arg name "$REPO_NAME" '.[] | select(.name == $name)')
            
            REPO_FULLNAME=$(echo "$REPO_PAYLOAD" | jq -r .full_name)
            REPO_PRIVATE=$(echo "$REPO_PAYLOAD" | jq -r .private)
            REPO_ARCHIVED=$(echo "$REPO_PAYLOAD" | jq -r .archived)
            REPO_HTMLURL=$(echo "$REPO_PAYLOAD" | jq -r .html_url)
            REPO_DESCRIPTION=$(echo "$REPO_PAYLOAD" | jq -r .description)
            REPO_FORK=$(echo "$REPO_PAYLOAD" | jq -r .fork)
            REPO_UPDATEDAT=$(echo "$REPO_PAYLOAD" | jq -r .updated_at)
            
            # Skip already archived repos
            if [ "$REPO_ARCHIVED" == "true" ]; then
                continue
            fi
            
            # Compare dates
            if [[ "$REPO_UPDATEDAT" < "$cutoff_date" ]]; then
                # Calculate days since last update
                if date -v-1d > /dev/null 2>&1; then
                    # BSD date (macOS)
                    UPDATED_EPOCH=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$REPO_UPDATEDAT" +%s 2>/dev/null || echo "0")
                else
                    # GNU date (Linux)
                    UPDATED_EPOCH=$(date -d "$REPO_UPDATEDAT" +%s 2>/dev/null || echo "0")
                fi
                
                CURRENT_EPOCH=$(date +%s)
                DAYS_SINCE=$((($CURRENT_EPOCH - $UPDATED_EPOCH) / 86400))
                
                # Write to CSV (escape description for CSV)
                ESCAPED_DESC=$(echo "$REPO_DESCRIPTION" | sed 's/"/""/g')
                echo "${REPO_NAME},${REPO_FULLNAME},${REPO_PRIVATE},${REPO_ARCHIVED},${REPO_HTMLURL},\"${ESCAPED_DESC}\",${REPO_FORK},${REPO_UPDATEDAT},${DAYS_SINCE}" >> "$REPORT_FILE"
                
                total_old_repos=$((total_old_repos + 1))
            fi
        done < <(echo "$REPOS" | jq -r '.[] | .name')
    done
    
    echo "$total_old_repos"
}

archive_repositories() {
    local count=0
    local name
    local last_updated
    local RESPONSE
    
    print_status "Reading repositories from $REPORT_FILE..."
    
    # Skip header line and process each repo
    while IFS=, read -r name _ _ _ _ _ _ last_updated _; do
        print_status "Archiving repository: $name (last updated: $last_updated)"
        
        RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
            -X PATCH \
            -H "Authorization: token $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.v3+json" \
            "${API_URL_PREFIX}/repos/${ORG}/${name}" \
            -d '{"archived":true}')
        
        if [ "$RESPONSE" -eq 200 ]; then
            print_success "Archived: $name"
        else
            print_error "Failed to archive $name (HTTP $RESPONSE)"
        fi
        
        count=$((count + 1))
        
        # Rate limiting
        sleep 2
    done < <(tail -n +2 "$REPORT_FILE")
    
    print_success "Archive operation complete. Processed $count repositories."
}

display_summary() {
    local total_repos="$1"
    
    echo ""
    echo "=========================================="
    echo "          SUMMARY REPORT"
    echo "=========================================="
    echo "Organization: $ORG"
    echo "Cutoff threshold: $YEARS_THRESHOLD years"
    echo "Total old repositories found: $total_repos"
    echo "Report saved to: $REPORT_FILE"
    echo "=========================================="
    echo ""
    
    if [ "$total_repos" -gt 0 ]; then
        print_warning "Found $total_repos repositories not updated in the last $YEARS_THRESHOLD years"
        echo ""
        echo "Top 10 oldest repositories:"
        echo "----------------------------"
        head -n 11 "$REPORT_FILE" | tail -n 10 | while IFS=, read -r name _ _ _ _ _ _ last_updated days_since; do
            echo "  - $name (last updated: $last_updated, $days_since days ago)"
        done
        echo ""
    else
        print_success "No old repositories found!"
    fi
}

prompt_for_archive() {
    local total_repos="$1"
    
    if [ "$total_repos" -eq 0 ]; then
        return
    fi
    
    echo ""
    print_warning "You are about to archive $total_repos repositories."
    print_warning "This action will:"
    print_warning "  - Make repositories read-only"
    print_warning "  - Prevent new issues, pull requests, and comments"
    print_warning "  - Disable Actions workflows"
    echo ""
    
    read -p "Do you want to proceed with archiving these repositories? (yes/no): " -r REPLY
    echo ""
    
    if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        print_status "Proceeding with archival..."
        archive_repositories
    else
        print_status "Archive operation cancelled."
        print_status "Review the report: $REPORT_FILE"
    fi
}

###
## MAIN EXECUTION
###
main() {
    print_status "GitHub Old Repository Archival Tool"
    print_status "====================================="
    
    validate_environment
    
    CUTOFF_DATE=$(calculate_cutoff_date)
    
    print_status "Searching for repositories not updated since: $CUTOFF_DATE"

    mkdir -p "$REPORT_DIR"
    
    TOTAL_OLD_REPOS=$(fetch_old_repos "$CUTOFF_DATE")
    
    display_summary "$TOTAL_OLD_REPOS"
    
    prompt_for_archive "$TOTAL_OLD_REPOS"
    
    print_success "Script execution complete!"
}

# Run main function
main
