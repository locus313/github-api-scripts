#!/usr/bin/env bash
# =============================================================================
# github-copilot-report.sh
#
# GitHub Copilot Enterprise licence & usage report, optionally enriched with
# Entra ID department data. Output: CSV file + console summary.
#
# Authentication — no secrets required in flags:
#   GitHub : GITHUB_TOKEN env var  (PAT with read:enterprise and
#                                   manage_billing:enterprise scopes)
#            OR provided automatically from an active gh auth session
#            with the required scopes
#   Entra  : az CLI  (optional; run 'az login' once; needs User.Read.All)
#            Skipped automatically if az is not installed or not logged in.
#            Use --no-entra to suppress Entra lookups explicitly.
#
# What this reports:
#   • Every user with a Copilot seat, their plan type, and their pool contribution
#     (credits per assigned seat — credits are pooled at the enterprise level)
#   • Actual per-user AI credit consumption this month (from billing API)
#   • Users grouped by Entra ID department
#   • Enterprise-level model usage breakdown
#
# AI credit pool — credits per assigned seat (GitHub usage-based billing, 2026):
#   Copilot Business  : 1,900 standard  |  3,000 promo (Jun 1 – Sep 1, 2026)
#   Copilot Enterprise: 3,900 standard  |  7,000 promo (Jun 1 – Sep 1, 2026)
#   Note: credits are POOLED at the enterprise level, not per-user buckets.
#   If your portal shows a different per-seat amount, set CREDITS_PER_SEAT_OVERRIDE.
#   Code completions are NOT billed in AI credits — they are unlimited.
#
# Requires API version 2026-03-10 and the new Copilot usage metrics endpoints.
# The legacy /copilot/metrics and /copilot/usage endpoints were closed Apr 2, 2026.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/github-common.sh
source "${SCRIPT_DIR}/../../lib/github-common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
GITHUB_ENTERPRISE="${GITHUB_ENTERPRISE:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
API_URL_PREFIX="${API_URL_PREFIX:-https://api.github.com}"
UPN_DOMAIN="${UPN_DOMAIN:-}"
ENTRA_TENANT="${ENTRA_TENANT:-}"
CREDITS_PER_SEAT_OVERRIDE="${CREDITS_PER_SEAT_OVERRIDE:-}"
OUTPUT_CSV="copilot-report-$(date +%Y%m%d).csv"
NO_ENTRA=false
GRAPH_TOKEN=""
ENTRA_ENABLED=false

# ── Derive UPN from GitHub login when no email is available ─────────────────
# Pattern: 'john_example' + domain 'example.com'  →  'john@example.com'
# Strips everything from the last underscore onwards, then appends @domain.
derive_upn() {
    local login="$1" domain="$2"
    if [[ -z "$domain" ]]; then
        echo "$login"
        return
    fi
    # Remove trailing _{anything} suffix (last underscore and everything after)
    local user="${login%_*}"
    echo "${user}@${domain}"
}

# ── Plan → monthly AI credits contributed to the enterprise pool per seat ─────
# Credits are pooled — not individual user buckets.
# Standard amounts: business=1900, enterprise=3900
# Promo amounts (Jun 1 – Sep 1, 2026): business=3000, enterprise=7000
# Override all of this via $CREDITS_PER_SEAT_OVERRIDE if your portal shows
# a different value (e.g. 1000 if your enterprise is still on the old model).
IN_PROMO_PERIOD=false
_today=$(date +%Y%m%d)
if [[ "$_today" -ge "20260601" && "$_today" -lt "20260901" ]]; then
    IN_PROMO_PERIOD=true
fi

plan_credits() {
    # If an explicit override is set, always use it
    if [[ -n "$CREDITS_PER_SEAT_OVERRIDE" ]]; then
        echo "$CREDITS_PER_SEAT_OVERRIDE"
        return
    fi
    if [[ "$IN_PROMO_PERIOD" == "true" ]]; then
        case "${1,,}" in
            business)          echo "3000" ;;
            enterprise)        echo "7000" ;;
            pro_plus|proplus)  echo "7000" ;;
            free)              echo "50"   ;;
            pro)               echo "3000" ;;
            *)                 echo "3000" ;;
        esac
    else
        case "${1,,}" in
            business)          echo "1900" ;;
            enterprise)        echo "3900" ;;
            pro_plus|proplus)  echo "3900" ;;
            free)              echo "50"   ;;
            pro)               echo "1900" ;;
            *)                 echo "1900" ;;
        esac
    fi
}

# ── Help text ─────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: github-copilot-report.sh [OPTIONS]

GitHub Copilot Enterprise licence + usage report, optionally enriched with
Entra ID department information.

Authentication (no secrets in flags):
  GitHub  →  export GITHUB_TOKEN=ghp_yourtoken  (read:enterprise,manage_billing:enterprise)
             OR resolved automatically from an active gh auth session
  Entra   →  az login

Options:
  -e, --enterprise SLUG  GitHub Enterprise slug  (or $GITHUB_ENTERPRISE)
  -d, --upn-domain DOM   Email domain for Entra lookup when GitHub carries no
                         email address  (or $UPN_DOMAIN, e.g. example.com)
                         Login 'john_example' + domain 'example.com' → john@example.com
                         The tenant ID is auto-resolved from this domain via
                         OIDC discovery, so --entra-tenant is rarely needed.
      --entra-tenant ID  Override the Azure AD tenant ID for the Graph lookup
                         (or $ENTRA_TENANT). Auto-resolved from --upn-domain
                         when not set; only needed to override that result.
      --credits N        Override credits-per-seat value  (or $CREDITS_PER_SEAT_OVERRIDE)
                         Use if your portal shows a different pool size than expected
      --output FILE      Output CSV (default: copilot-report-YYYYMMDD.csv)
      --no-entra         Skip Entra ID department lookup
  -h, --help             Show this message

Required GITHUB_TOKEN scopes:
  read:enterprise
  manage_billing:enterprise          (requires enterprise owner or billing manager)

Note: If your enterprise has multiple organisations, the seats endpoint
aggregates across all of them automatically.
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--enterprise)   GITHUB_ENTERPRISE="$2";         shift 2 ;;
        -d|--upn-domain)  UPN_DOMAIN="$2";                 shift 2 ;;
        --entra-tenant)   ENTRA_TENANT="$2";               shift 2 ;;
        --credits)        CREDITS_PER_SEAT_OVERRIDE="$2";  shift 2 ;;
        --output)         OUTPUT_CSV="$2";                 shift 2 ;;
        --no-entra)       NO_ENTRA=true;                   shift   ;;
        -h|--help)        usage; exit 0                             ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# ── Pre-flight checks ─────────────────────────────────────────────────────────
[[ -z "$GITHUB_ENTERPRISE" ]] && \
    err "GitHub Enterprise slug is required  (-e / \$GITHUB_ENTERPRISE)"

require_command jq

require_env_var GITHUB_TOKEN
validate_github_token "bearer"

# ── Acquire Microsoft Graph token via az CLI ──────────────────────────────────
if [[ "$NO_ENTRA" == "true" ]]; then
    print_warning "Entra ID lookup disabled (--no-entra). Department column will be N/A."
elif ! command -v az &>/dev/null; then
    print_warning "az CLI is not installed — department/division grouping will be skipped."
    print_warning "Install the Azure CLI and run 'az login' to enable Entra ID enrichment, or pass --no-entra."
elif az account show &>/dev/null 2>&1; then
    # Auto-resolve tenant ID from UPN domain via OIDC discovery when not explicitly set.
    # GET https://login.microsoftonline.com/{domain}/.well-known/openid-configuration
    # returns an issuer like https://sts.windows.net/{tenant-id}/ — extract the GUID.
    if [[ -z "$ENTRA_TENANT" && -n "$UPN_DOMAIN" ]]; then
        _resolved_tenant=$(curl -sf \
            "https://login.microsoftonline.com/${UPN_DOMAIN}/.well-known/openid-configuration" \
            2>/dev/null \
            | jq -r '.issuer // empty' \
            | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') || true
        if [[ -n "$_resolved_tenant" ]]; then
            ENTRA_TENANT="$_resolved_tenant"
            print_status "Auto-resolved Entra tenant '${ENTRA_TENANT}' from domain '${UPN_DOMAIN}'."
        else
            print_warning "Could not resolve tenant from domain '${UPN_DOMAIN}' — using default az tenant."
        fi
    fi
    print_status "Acquiring Microsoft Graph token via az CLI..."
    GRAPH_TOKEN=$(az account get-access-token \
        --resource https://graph.microsoft.com \
        ${ENTRA_TENANT:+--tenant "$ENTRA_TENANT"} \
        --query accessToken -o tsv 2>/dev/null) || true
    if [[ -n "$GRAPH_TOKEN" ]]; then
        ENTRA_ENABLED=true
        [[ -n "$ENTRA_TENANT" ]] && print_status "Graph token acquired (tenant: ${ENTRA_TENANT})." \
                                  || print_status "Graph token acquired."
    else
        print_warning "az is logged in but could not get a Graph token — department lookup disabled."
        print_warning "Ensure your account has User.Read.All permission in the target tenant."
        [[ -z "$ENTRA_TENANT" ]] && \
            print_warning "If you have multiple tenants, try: --entra-tenant <TENANT_ID>"
    fi
else
    print_warning "az CLI is not logged in — department/division grouping will be skipped."
    print_warning "Run 'az login' to enable Entra ID enrichment, or pass --no-entra."
fi

# ── GitHub API via curl with Copilot API version ──────────────────────────────
# The Copilot usage-metrics endpoints require API version 2026-03-10.
_copilot_api() {
    local url="$1"; shift
    gh_api "${url}" --api-version 2026-03-10 "$@"
}

# fetch_usage_ndjson REPORT_PATH
# Calls the new usage metrics API (which returns signed download_links to NDJSON
# files rather than inline JSON), downloads each file, and emits one NDJSON
# object per line on stdout.  Exits cleanly with empty output if unavailable.
fetch_usage_ndjson() {
    local path="$1"
    local resp links
    resp=$(_copilot_api "${path}" 2>/dev/null) || return 0
    [[ "${resp}" == "__404__" || "${resp}" == "__422__" ]] && return 0
    links=$(echo "$resp" | jq -r '.download_links[]? // empty' 2>/dev/null) || return 0
    [[ -z "$links" ]] && return 0
    while IFS= read -r url; do
        curl -sf "$url" 2>/dev/null || true
    done <<< "$links"
}

# Fetches all active Copilot seats for the enterprise, returns a JSON array.
# The enterprise seats endpoint does not expose a total_seats wrapper, so
# TOTAL_ASSIGNED_SEATS falls back to the deduplicated unique-user count.
TOTAL_ASSIGNED_SEATS=0

fetch_seats() {
    local slug="$1"
    gh_api_paginate "/enterprises/${slug}/copilot/billing/seats" '.seats[]' '2026-03-10' \
    | jq -s '.'
}

# ── Microsoft Graph helpers ───────────────────────────────────────────────────
declare -A _GRAPH_CACHE

# graph_user_info EMAIL_OR_UPN
# Returns JSON: {department, jobTitle, displayName, mail}
graph_user_info() {
    local query="$1"

    if [[ "$ENTRA_ENABLED" != "true" || -z "$query" ]]; then
        echo '{"department":"N/A","jobTitle":"","displayName":"","mail":""}'
        return
    fi

    if [[ -n "${_GRAPH_CACHE[$query]+_}" ]]; then
        echo "${_GRAPH_CACHE[$query]}"
        return
    fi

    # Use curl with the explicit GRAPH_TOKEN for reliable auth and proper URL encoding.
    local resp
    resp=$(curl -sfG \
        -H "Authorization: Bearer ${GRAPH_TOKEN}" \
        -H "ConsistencyLevel: eventual" \
        --data-urlencode "\$filter=mail eq '${query}' or userPrincipalName eq '${query}'" \
        --data-urlencode "\$select=displayName,department,jobTitle,mail,userPrincipalName" \
        "https://graph.microsoft.com/v1.0/users" \
        2>/dev/null) || resp='{"value":[]}'

    local result
    result=$(echo "$resp" | jq -c '
        .value[0] // {} |
        {
            department:  (.department  // "Unknown"),
            jobTitle:    (.jobTitle    // ""),
            displayName: (.displayName // ""),
            mail:        (.mail        // "")
        }')

    _GRAPH_CACHE["$query"]="$result"
    echo "$result"
}

# ── Fetch seats ───────────────────────────────────────────────────────────────
print_status "Fetching Copilot seats for enterprise '${GITHUB_ENTERPRISE}'..."
SEATS_RAW=$(fetch_seats "$GITHUB_ENTERPRISE")

# The seats endpoint returns one entry per org per user — deduplicate by login,
# keeping the first occurrence (earliest org assignment).
# Collect all org assignments per user into a comma-separated "organisations" field.
SEATS=$(echo "$SEATS_RAW" | jq '
    group_by(.assignee.login) |
    map(
        (.[0] | del(.organization)) +
        { organisations: (map(.organization.login // "") | map(select(. != "")) | unique | join(", ")) }
    )
')

SEAT_COUNT=$(echo "$SEATS" | jq 'length')
print_status "Found ${SEAT_COUNT} unique licensed user(s)  ($(echo "$SEATS_RAW" | jq 'length') raw seat entries across orgs)."
# Enterprise seats endpoint has no total_seats field; use unique user count.
TOTAL_ASSIGNED_SEATS=$SEAT_COUNT

# ── Fetch per-user AI credit consumption (billing API, current month) ──────────
# Calls GET /enterprises/{slug}/settings/billing/ai_credit/usage?user={login}
# for each licensed user and sums grossQuantity across all usageItems.
# Requires manage_billing:enterprise scope (classic/OAuth token; not fine-grained PATs).
_BILLING_YEAR=$(date +%Y)
_BILLING_MONTH=$(( 10#$(date +%m) ))   # strip leading zero (macOS compatible)
print_status "Fetching per-user AI credit consumption (billing API, ${_BILLING_YEAR}-$(printf '%02d' $_BILLING_MONTH))..."
declare -A USER_CREDITS_USED
declare -A USER_MODEL_CREDITS   # key: "login|model"  value: credits
declare -A _ALL_MODELS_SET      # keys are unique model names seen
_billing_ok=true
_billing_fail_statuses=""

_ALL_LOGINS=$(echo "$SEATS" | jq -r '.[].assignee.login')
_LOGIN_COUNT=$(echo "$_ALL_LOGINS" | wc -l | tr -d ' ')
_login_i=0
while IFS= read -r _login; do
    [[ -z "$_login" ]] && continue
    _login_i=$(( _login_i + 1 ))
    printf '\r  [%d/%d] %s          ' "$_login_i" "$_LOGIN_COUNT" "$_login" >&2
    _resp=$(_copilot_api \
        "/enterprises/${GITHUB_ENTERPRISE}/settings/billing/ai_credit/usage?user=${_login}&year=${_BILLING_YEAR}&month=${_BILLING_MONTH}") || _resp=""
    if [[ "${_resp}" == "__404__" || "${_resp}" == "__422__" ]]; then
        # No usage data this month — valid, treat as 0 credits.
        _credits="0"
    elif [[ -n "$_resp" ]]; then
        # Success: parse credit usage
        _credits=$(echo "$_resp" | jq '[.usageItems[]?.grossQuantity // 0] | add // 0 | round' 2>/dev/null || echo "0")
        # Store per-model breakdown
        while IFS=$'\t' read -r _model _qty; do
            [[ -z "$_model" ]] && continue
            USER_MODEL_CREDITS["${_login}|${_model}"]="$_qty"
            _ALL_MODELS_SET["$_model"]=1
        done < <(echo "$_resp" | jq -r '.usageItems[] | [(.model // "Unknown"), (.grossQuantity // 0 | round | tostring)] | @tsv' 2>/dev/null)
    else
        _credits="0"
        _billing_ok=false
        _billing_fail_statuses="${_billing_fail_statuses} ${_login}(empty)"
    fi
    USER_CREDITS_USED["$_login"]="$_credits"
done <<< "$_ALL_LOGINS"
printf '\r%-60s\r' '' >&2   # clear progress line

if [[ "$_billing_ok" == "true" ]]; then
    print_status "Loaded billing data for ${#USER_CREDITS_USED[@]} user(s)."
else
    print_warning "Some billing API calls failed — credits may show 0 for affected users."
    print_warning "Ensure manage_billing:enterprise scope: set GITHUB_TOKEN with the required scopes"
    [[ -n "$_billing_fail_statuses" ]] && \
        print_warning "Failed users:${_billing_fail_statuses}"
fi

# Build sorted list of all model names seen across all users
ALL_MODELS=()
while IFS= read -r _m; do
    [[ -n "$_m" ]] && ALL_MODELS+=("$_m")
done < <(printf '%s\n' "${!_ALL_MODELS_SET[@]}" | sort)

# ── Fetch enterprise-level model usage (new usage metrics API, 28-day) ────────
print_status "Fetching enterprise model usage metrics (last 28 days)..."
ENT_NDJSON=$(fetch_usage_ndjson \
    "/enterprises/${GITHUB_ENTERPRISE}/copilot/metrics/reports/enterprise-28-day/latest")

# Summarise: model → unique active users, features used
MODEL_SUMMARY="[]"
if [[ -n "$ENT_NDJSON" ]]; then
    MODEL_SUMMARY=$(echo "$ENT_NDJSON" | jq -sc '
        [ .[] | select(.model != null) |
          { model: (.model // "unknown"),
            users: (.active_users // .total_active_users // .engaged_users // 0),
            ctx:   (.feature // .copilot_feature // "unknown") } ] |
        group_by(.model) |
        map({
            model:      .[0].model,
            peak_users: (map(.users) | max),
            contexts:   (map(.ctx)   | unique | join(", "))
        }) |
        sort_by(.model)
    ' 2>/dev/null || echo "[]")
fi

# ── Write CSV header ──────────────────────────────────────────────────────────
_model_header_cols=$(printf ',"Credits: %s"' "${ALL_MODELS[@]}")
printf '%s\n' \
    "GitHub Login,Display Name,Email / UPN,Organisation,Plan Type,Pool Contribution (Credits/Seat),AI Credits Used (Month)${_model_header_cols},Department,Job Title,Last Active,Last Editor" \
    > "$OUTPUT_CSV"

# ── Per-department counters ───────────────────────────────────────────────────
declare -A DEPT_USERS
declare -A DEPT_CREDITS
TOTAL_CREDITS=0

# ── Process each seat ────────────────────────────────────────────────────────
print_status "Enriching ${SEAT_COUNT} users with Entra ID info (this may take a moment)..."

while IFS= read -r seat; do
    login=$(       echo "$seat" | jq -r '.assignee.login          // ""')
    email=$(       echo "$seat" | jq -r '.assignee.email          // ""')
    gh_name=$(     echo "$seat" | jq -r '.assignee.name           // ""')
    plan=$(        echo "$seat" | jq -r '.plan_type               // "business"')
    org=$(         echo "$seat" | jq -r '.organisations               // ""')
    last_active=$( echo "$seat" | jq -r '.last_activity_at        // ""')
    last_editor=$( echo "$seat" | jq -r '.last_activity_editor    // ""')

    credits=$(plan_credits "$plan")
    credits_used="${USER_CREDITS_USED[$login]:-}"

    # Prefer email; fall back to UPN derived from login + --upn-domain
    if [[ -n "$email" ]]; then
        lookup="$email"
    elif [[ -n "$UPN_DOMAIN" ]]; then
        lookup=$(derive_upn "$login" "$UPN_DOMAIN")
    else
        lookup="$login"
    fi

    user_info=$(graph_user_info "$lookup")
    dept=$(  echo "$user_info" | jq -r '.department  // "Unknown"')
    title=$( echo "$user_info" | jq -r '.jobTitle    // ""')
    disp=$(  echo "$user_info" | jq -r '.displayName // ""')
    [[ -z "$disp" ]] && disp="$gh_name"

    # Append to CSV — double-quote all fields, escape embedded quotes
    printf '"%s","%s","%s","%s","%s","%s","%s"' \
        "${login//\"/\"\"}" \
        "${disp//\"/\"\"}" \
        "${lookup//\"/\"\"}" \
        "${org//\"/\"\"}" \
        "${plan//\"/\"\"}" \
        "$credits" \
        "${credits_used}" \
        >> "$OUTPUT_CSV"
    # Per-model credit columns (0 if user had no usage on that model)
    for _m in "${ALL_MODELS[@]}"; do
        printf ',"%s"' "${USER_MODEL_CREDITS[${login}|${_m}]:-0}" >> "$OUTPUT_CSV"
    done
    printf ',"%s","%s","%s","%s"\n' \
        "${dept//\"/\"\"}" \
        "${title//\"/\"\"}" \
        "${last_active//\"/\"\"}" \
        "${last_editor//\"/\"\"}" \
        >> "$OUTPUT_CSV"

    [[ -z "${DEPT_USERS[$dept]+x}" ]]   && DEPT_USERS["$dept"]=0
    [[ -z "${DEPT_CREDITS[$dept]+x}" ]] && DEPT_CREDITS["$dept"]=0
    DEPT_USERS["$dept"]=$(( DEPT_USERS["$dept"] + 1 ))
    DEPT_CREDITS["$dept"]=$(( DEPT_CREDITS["$dept"] + credits ))
    TOTAL_CREDITS=$(( TOTAL_CREDITS + credits ))

done < <(echo "$SEATS" | jq -c '.[]')

# Total pool = all assigned seats × credits per seat.
# Uses the most common plan seen in active seats as the per-seat rate.
MOST_COMMON_PLAN=$(echo "$SEATS" | jq -r '[.[].plan_type] | group_by(.) | max_by(length) | .[0] // "business"')
CREDITS_PER_SEAT=$(plan_credits "$MOST_COMMON_PLAN")
TOTAL_ALLOCATED_CREDITS=$(( TOTAL_ASSIGNED_SEATS * CREDITS_PER_SEAT ))
PROMO_NOTE=""
[[ "$IN_PROMO_PERIOD" == "true" && -z "$CREDITS_PER_SEAT_OVERRIDE" ]] && \
    PROMO_NOTE=" [promo rate Jun–Sep 2026]"
[[ -n "$CREDITS_PER_SEAT_OVERRIDE" ]] && \
    PROMO_NOTE=" [override]"

# ── Console output ────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
printf "  GitHub Copilot Report  ·  %s  ·  Enterprise: %s\n" \
       "$(date +%Y-%m-%d)" "$GITHUB_ENTERPRISE"
echo "═══════════════════════════════════════════════════════════════════"

# Department summary table
echo ""
printf "  %-38s %7s %16s\n" "Department" "Users" "Allocated Credits"
printf "  %-38s %7s %16s\n" "──────────────────────────────────────" "───────" "────────────────"
while IFS= read -r dept; do
    printf "  %-38s %7d %16d\n" "$dept" "${DEPT_USERS[$dept]:-0}" "${DEPT_CREDITS[$dept]:-0}"
done < <(printf '%s\n' "${!DEPT_USERS[@]}" | sort)
printf "  %-38s %7s %16s\n" "──────────────────────────────────────" "───────" "────────────────"
printf "  %-38s %7d %16d\n" "Active seats (subtotal)" "$SEAT_COUNT" "$TOTAL_CREDITS"
printf "  %-38s %7d %16d\n" "All assigned seats (pool total)" "$TOTAL_ASSIGNED_SEATS" "$TOTAL_ALLOCATED_CREDITS"
printf "  %s\n\n" "  (${MOST_COMMON_PLAN} plan · ${CREDITS_PER_SEAT} credits/seat × ${TOTAL_ASSIGNED_SEATS} seats${PROMO_NOTE})"


# Model usage table
MODEL_COUNT=$(echo "$MODEL_SUMMARY" | jq 'length')
if [[ "$MODEL_COUNT" -gt 0 ]]; then
    echo "  ── Model usage (enterprise-level, last 28 days) ──────────────"
    printf "  %-42s %11s  %s\n" "Model" "Peak Users" "Used in"
    printf "  %-42s %11s  %s\n" \
        "──────────────────────────────────────────" "──────────" "────────────────────────────────"
    echo "$MODEL_SUMMARY" | jq -r '.[] | [.model, (.peak_users | tostring), .contexts] | @tsv' | \
    while IFS=$'\t' read -r model users contexts; do
        printf "  %-42s %11s  %s\n" "$model" "$users" "$contexts"
    done
    echo ""
fi

# Notes on credit accounting
echo "  ── Notes ─────────────────────────────────────────────────────"
echo "  Credits are POOLED at the enterprise level — the per-seat figure"
echo "  shown above is each seat's contribution to the shared pool."
echo "  Code completions are not billed in AI credits (unlimited)."
echo ""
echo "  'AI Credits Used (Month)' = actual AI credits consumed this billing month"
echo "  (from GET /enterprises/.../settings/billing/ai_credit/usage)."
echo "  1 AI credit = \$0.01 USD. Code completions are not billed (unlimited)."
echo "  A value of 0 means no metered AI usage this month."
echo ""

print_success "Report saved → ${OUTPUT_CSV}"
echo ""
