#!/usr/bin/env bash
# =============================================================================
# github-copilot-budget-advisor.sh
#
# Analyses per-user GitHub Copilot AI credit consumption over the last 30 days
# and recommends a Universal per-user budget limit for the Copilot billing
# budget feature (Enterprise → Policies → Budgets → Users).
#
# Usage:
#   export GITHUB_TOKEN=ghp_yourtoken
#   export GITHUB_ENTERPRISE=my-enterprise
#   ./github-copilot-budget-advisor.sh [OPTIONS]
#
# Options:
#   -e, --enterprise SLUG  GitHub Enterprise slug  (or $GITHUB_ENTERPRISE)
#       --days N           Look-back window in days (1–60, default: 30)
#   -h, --help             Show this message
#
# Environment variables:
#   GITHUB_TOKEN        Required. PAT with read:enterprise and
#                       manage_billing:enterprise scopes.
#                       OR resolved automatically from an active gh auth session.
#   GITHUB_ENTERPRISE   Required. GitHub Enterprise slug
#   API_URL_PREFIX      Optional. GitHub API base URL (default: https://api.github.com)
#
# Budget recommendation logic:
#   The script calculates per-user AI credit consumption across the look-back
#   window, then recommends the 90th-percentile value rounded up to the nearest
#   100 credits as the Universal baseline. This covers ~90% of users without
#   interruption while capping the top 10%.
#
#   1 AI credit ≈ $0.01 USD. Code completions are NOT billed in AI credits.
#
# Requirements:
#   - curl
#   - jq
#   - awk
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/github-common.sh
source "${SCRIPT_DIR}/../../lib/github-common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
GITHUB_ENTERPRISE="${GITHUB_ENTERPRISE:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
API_URL_PREFIX="${API_URL_PREFIX:-https://api.github.com}"
LOOKBACK_DAYS=30

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: github-copilot-budget-advisor.sh [OPTIONS]

Analyses per-user GitHub Copilot AI credit consumption over the last 30 days
and recommends a Universal per-user budget limit.

Authentication:
  GitHub  →  export GITHUB_TOKEN=ghp_yourtoken
             (read:enterprise and manage_billing:enterprise scopes required)
             OR resolved automatically from an active gh auth session

Options:
  -e, --enterprise SLUG  GitHub Enterprise slug  (or $GITHUB_ENTERPRISE)
      --days N           Look-back window in days (1–60, default: 30)
  -h, --help             Show this message

Required GITHUB_TOKEN scopes:
  read:enterprise
  manage_billing:enterprise

Example:
  export GITHUB_TOKEN=ghp_xxxxx
  export GITHUB_ENTERPRISE=my-enterprise
  ./github-copilot-budget-advisor.sh
  ./github-copilot-budget-advisor.sh -e my-enterprise --days 14
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--enterprise)
            GITHUB_ENTERPRISE="$2"
            shift 2
            ;;
        --days)
            LOOKBACK_DAYS="$2"
            if ! [[ "$LOOKBACK_DAYS" =~ ^[0-9]+$ ]] || \
               [[ "$LOOKBACK_DAYS" -lt 1 ]] || \
               [[ "$LOOKBACK_DAYS" -gt 60 ]]; then
                err "--days must be a number between 1 and 60"
            fi
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ -z "$GITHUB_ENTERPRISE" ]] && \
    err "GitHub Enterprise slug is required  (-e / \$GITHUB_ENTERPRISE)"

validate_slug "$GITHUB_ENTERPRISE" "GITHUB_ENTERPRISE"

require_command jq
require_command awk

require_env_var GITHUB_TOKEN
validate_github_token "bearer"

# ── Date arithmetic (portable: BSD/macOS and GNU/Linux) ───────────────────────
_CURR_YEAR=$(date +%Y)
_CURR_MONTH=$(( 10#$(date +%m) ))   # strip leading zero for arithmetic
_CURR_DAY=$(( 10#$(date +%d) ))

if is_bsd_date; then
    # BSD date (macOS)
    _PREV_YEAR=$(date -v-1m +%Y)
    _PREV_MONTH=$(( 10#$(date -v-1m +%m) ))
    _DAYS_IN_PREV_MONTH=$(( 10#$(date -v1d -v-1d +%d) ))
else
    # GNU date (Linux)
    _PREV_YEAR=$(date -d "$(date +%Y-%m-01) -1 month" +%Y)
    _PREV_MONTH=$(( 10#$(date -d "$(date +%Y-%m-01) -1 month" +%m) ))
    _DAYS_IN_PREV_MONTH=$(( 10#$(date -d "$(date +%Y-%m-01) -1 day" +%d) ))
fi

# Days to pull from the previous month:
# If look-back > days elapsed in current month, we need some days from previous month.
_PREV_DAYS_NEEDED=$(( LOOKBACK_DAYS - _CURR_DAY ))
[[ "$_PREV_DAYS_NEEDED" -lt 0 ]] && _PREV_DAYS_NEEDED=0

_WINDOW_START_LABEL=""
if [[ "$_PREV_DAYS_NEEDED" -gt 0 ]]; then
    _WINDOW_START_LABEL="${_PREV_YEAR}-$(printf '%02d' "$_PREV_MONTH") (partial) + ${_CURR_YEAR}-$(printf '%02d' "$_CURR_MONTH") (to date)"
else
    _WINDOW_START_LABEL="${_CURR_YEAR}-$(printf '%02d' "$_CURR_MONTH") (to date)"
fi

# ── Fetch all active Copilot seats ────────────────────────────────────────────
print_status "Fetching Copilot seats for enterprise '${GITHUB_ENTERPRISE}'..."
SEATS_RAW=$(gh_api_paginate \
    "/enterprises/${GITHUB_ENTERPRISE}/copilot/billing/seats" \
    '.seats[]' \
    '2026-03-10' \
    | jq -s '.')

# Deduplicate by login (keep first occurrence)
SEATS=$(echo "$SEATS_RAW" | jq 'group_by(.assignee.login) | map(.[0])')
SEAT_COUNT=$(echo "$SEATS" | jq 'length')

if [[ "$SEAT_COUNT" -eq 0 ]]; then
    err "No Copilot seats found for enterprise '${GITHUB_ENTERPRISE}'. Verify the slug and token scopes."
fi

print_status "Found ${SEAT_COUNT} unique licensed user(s)."

# ── Fetch per-user AI credit usage ────────────────────────────────────────────
print_status "Fetching AI credit usage for the last ${LOOKBACK_DAYS} days (${_WINDOW_START_LABEL})..."

declare -A _CURR_CREDITS
declare -A _PREV_CREDITS
_ALL_LOGINS=$(echo "$SEATS" | jq -r '.[].assignee.login')
_LOGIN_COUNT=$(echo "$_ALL_LOGINS" | wc -l | tr -d ' ')
_login_i=0
_billing_errors=0

while IFS= read -r _login; do
    [[ -z "$_login" ]] && continue
    _login_i=$(( _login_i + 1 ))
    printf '\r  [%d/%d] %-40s' "$_login_i" "$_LOGIN_COUNT" "$_login" >&2

    # Current month usage
    _resp=$(gh_api \
        "/enterprises/${GITHUB_ENTERPRISE}/settings/billing/ai_credit/usage?user=${_login}&year=${_CURR_YEAR}&month=${_CURR_MONTH}" \
        --api-version 2026-03-10) || _resp=""
    if [[ "${_resp}" == "__404__" || "${_resp}" == "__422__" || -z "$_resp" ]]; then
        _CURR_CREDITS["$_login"]=0
        [[ -z "$_resp" ]] && _billing_errors=$(( _billing_errors + 1 ))
    else
        _CURR_CREDITS["$_login"]=$(echo "$_resp" | \
            jq '[.usageItems[]?.grossQuantity // 0] | add // 0 | round' 2>/dev/null || echo "0")
    fi

    # Previous month usage (only when the look-back window extends into it)
    if [[ "$_PREV_DAYS_NEEDED" -gt 0 ]]; then
        _resp=$(gh_api \
            "/enterprises/${GITHUB_ENTERPRISE}/settings/billing/ai_credit/usage?user=${_login}&year=${_PREV_YEAR}&month=${_PREV_MONTH}" \
            --api-version 2026-03-10) || _resp=""
        if [[ "${_resp}" == "__404__" || "${_resp}" == "__422__" || -z "$_resp" ]]; then
            _PREV_CREDITS["$_login"]=0
        else
            _PREV_CREDITS["$_login"]=$(echo "$_resp" | \
                jq '[.usageItems[]?.grossQuantity // 0] | add // 0 | round' 2>/dev/null || echo "0")
        fi
    else
        _PREV_CREDITS["$_login"]=0
    fi
done <<< "$_ALL_LOGINS"
printf '\r%-60s\r' '' >&2   # clear progress line

if [[ "$_billing_errors" -gt 0 ]]; then
    print_warning "${_billing_errors} billing API call(s) returned empty responses."
    print_warning "Ensure GITHUB_TOKEN has the manage_billing:enterprise scope."
fi

# ── Compute prorated 30-day usage per user ────────────────────────────────────
# Current month: full usage to date (already covers _CURR_DAY days).
# Previous month: scale to _PREV_DAYS_NEEDED / _DAYS_IN_PREV_MONTH.
declare -A _USER_30D
declare -a _USAGE_VALUES
_USAGE_VALUES=()

while IFS= read -r _login; do
    [[ -z "$_login" ]] && continue
    _curr="${_CURR_CREDITS[$_login]:-0}"
    _prev="${_PREV_CREDITS[$_login]:-0}"

    if [[ "$_PREV_DAYS_NEEDED" -gt 0 && "$_DAYS_IN_PREV_MONTH" -gt 0 ]]; then
        _prev_contrib=$(awk \
            "BEGIN { printf \"%d\", int(${_prev} * ${_PREV_DAYS_NEEDED} / ${_DAYS_IN_PREV_MONTH} + 0.5) }")
    else
        _prev_contrib=0
    fi

    _total=$(( _curr + _prev_contrib ))
    _USER_30D["$_login"]="$_total"
    _USAGE_VALUES+=("$_total")
done <<< "$_ALL_LOGINS"

# ── Statistical analysis ──────────────────────────────────────────────────────
_num_users="${#_USAGE_VALUES[@]}"

IFS=$'\n' mapfile -t _sorted < <(printf '%s\n' "${_USAGE_VALUES[@]}" | sort -n)

_stats=$(printf '%s\n' "${_sorted[@]}" | awk '
BEGIN { sum=0; count=0 }
{ vals[count++] = $1; sum += $1 }
END {
    if (count == 0) { print "count=0"; exit }
    mean = sum / count
    # nearest-rank percentile indices (1-based ceiling, clamped)
    p50i = int(50 * count / 100 + 0.999999) - 1; if (p50i < 0) p50i = 0; if (p50i >= count) p50i = count-1
    p75i = int(75 * count / 100 + 0.999999) - 1; if (p75i < 0) p75i = 0; if (p75i >= count) p75i = count-1
    p90i = int(90 * count / 100 + 0.999999) - 1; if (p90i < 0) p90i = 0; if (p90i >= count) p90i = count-1
    p95i = int(95 * count / 100 + 0.999999) - 1; if (p95i < 0) p95i = 0; if (p95i >= count) p95i = count-1
    printf "count=%d\n",  count
    printf "sum=%d\n",    sum
    printf "mean=%d\n",   int(mean + 0.5)
    printf "max=%d\n",    vals[count-1]
    printf "p50=%d\n",    vals[p50i]
    printf "p75=%d\n",    vals[p75i]
    printf "p90=%d\n",    vals[p90i]
    printf "p95=%d\n",    vals[p95i]
}')

_count=$(echo "$_stats" | grep "^count=" | cut -d= -f2)
_sum=$(echo "$_stats"   | grep "^sum="   | cut -d= -f2)
_mean=$(echo "$_stats"  | grep "^mean="  | cut -d= -f2)
_max=$(echo "$_stats"   | grep "^max="   | cut -d= -f2)
_p50=$(echo "$_stats"   | grep "^p50="   | cut -d= -f2)
_p75=$(echo "$_stats"   | grep "^p75="   | cut -d= -f2)
_p90=$(echo "$_stats"   | grep "^p90="   | cut -d= -f2)
_p95=$(echo "$_stats"   | grep "^p95="   | cut -d= -f2)

# Suggested budget: P90 rounded up to the nearest 100, minimum 100.
_suggested=$(awk "BEGIN {
    v = ${_p90}
    r = (v == 0) ? 100 : int((v + 99) / 100) * 100
    print r
}")

# Helper: convert credits to a dollar string with 2 decimal places (1 credit = $0.01)
_to_usd() { awk "BEGIN { printf \"%.2f\", $1 / 100 }"; }

_suggested_usd=$(_to_usd "$_suggested")
_p75_suggested=$(awk "BEGIN { v=${_p75}; print (v==0)?100:int((v+99)/100)*100 }")
_p95_suggested=$(awk "BEGIN { v=${_p95}; print (v==0)?100:int((v+99)/100)*100 }")
_p75_usd=$(_to_usd "$_p75_suggested")
_p95_usd=$(_to_usd "$_p95_suggested")

# ── Users affected at each threshold ─────────────────────────────────────────
_count_above() {
    printf '%s\n' "${_sorted[@]}" | awk -v t="$1" 'BEGIN{c=0} $1>t{c++} END{print c}'
}
_affected_p50=$(_count_above "$_p50")
_affected_p75=$(_count_above "$_p75")
_affected_p90=$(_count_above "$_p90")
_affected_p95=$(_count_above "$_p95")

# ── Console output ────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
printf "  Copilot Budget Advisor  ·  %s  ·  Enterprise: %s\n" \
       "$(date +%Y-%m-%d)" "$GITHUB_ENTERPRISE"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
printf "  Look-back window : %d days  (%s)\n" "$LOOKBACK_DAYS" "$_WINDOW_START_LABEL"
printf "  Licensed users   : %d\n"             "$_count"
printf "  Total AI credits : %d  (mean %d / user)\n" "$_sum" "$_mean"
echo ""

echo "  ── Per-user usage distribution ───────────────────────────────────"
printf "  %-6s  %8s  %7s  %-s\n" "Pctile" "Credits" "USD" "Users that would exceed this limit"
printf "  %-6s  %8s  %7s  %-s\n" "──────" "────────" "───────" "──────────────────────────────────"
printf "  %-6s  %8d  %7s  %d of %d (%.0f%%)\n" \
       "P50"  "$_p50"  "\$$(_to_usd "$_p50")"  "$_affected_p50" "$_count" \
       "$(awk "BEGIN { printf \"%.0f\", ${_affected_p50} / ${_count} * 100 }")"
printf "  %-6s  %8d  %7s  %d of %d (%.0f%%)\n" \
       "P75"  "$_p75"  "\$$(_to_usd "$_p75")"  "$_affected_p75" "$_count" \
       "$(awk "BEGIN { printf \"%.0f\", ${_affected_p75} / ${_count} * 100 }")"
printf "  %-6s  %8d  %7s  %d of %d (%.0f%%)\n" \
       "P90"  "$_p90"  "\$$(_to_usd "$_p90")"  "$_affected_p90" "$_count" \
       "$(awk "BEGIN { printf \"%.0f\", ${_affected_p90} / ${_count} * 100 }")"
printf "  %-6s  %8d  %7s  %d of %d (%.0f%%)\n" \
       "P95"  "$_p95"  "\$$(_to_usd "$_p95")"  "$_affected_p95" "$_count" \
       "$(awk "BEGIN { printf \"%.0f\", ${_affected_p95} / ${_count} * 100 }")"
printf "  %-6s  %8d  %7s  %s\n" \
       "Max"  "$_max"  "\$$(_to_usd "$_max")"  "0 (no cap on current patterns)"
echo ""

echo "  ── Suggested Universal budget ────────────────────────────────────"
printf "  \033[1m\$%s per user\033[0m  (%d credits)\n\n" "$_suggested_usd" "$_suggested"
echo "  Based on: P90 (${_p90} credits) rounded up to the nearest 100."
echo "  ~90% of users stay within this limit; the top 10% are capped."
echo ""
echo "  To set this in GitHub:"
echo "    Enterprise → Policies → Copilot → Budgets → Create budget"
echo "    Scope: Users  |  Type: Universal"
printf "    Budget amount: \033[1m\$%s\033[0m per user\n" "$_suggested_usd"
echo ""
printf "  Adjust upward   → \$%s / user (P95, %d credits) for minimal disruption.\n" \
       "$_p95_usd" "$_p95_suggested"
printf "  Adjust downward → \$%s / user (P75, %d credits) for tighter cost control.\n" \
       "$_p75_usd" "$_p75_suggested"
echo ""
echo "  1 AI credit = \$0.01 USD. Code completions are NOT billed in AI credits."
echo "  Budget tracks both included and additional (overage) usage."
echo ""

# Individual budget suggestion: 30-day usage rounded up to the nearest $10
# (1000 credits), giving a small natural buffer over observed usage.
_individual_budget() {
    awk "BEGIN { v=$1; print (v==0) ? 1000 : int((v + 999) / 1000) * 1000 }"
}

# Top consumers above P90 → candidates for Individual user budgets
if [[ "$_affected_p90" -gt 0 ]]; then
    _p90_usd_label=$(_to_usd "$_p90")
    echo "  ── Individual user budget suggestions ────────────────────────────"
    printf "  These %d user(s) exceed the Universal budget (\$%s) and should each\n" \
           "$_affected_p90" "$_suggested_usd"
    echo "  receive an Individual user budget to avoid being blocked."
    echo ""
    printf "  %-32s  %14s  %9s  %16s\n" \
           "Login" "Credits (${LOOKBACK_DAYS}d)" "USD" "Suggested budget"
    printf "  %-32s  %14s  %9s  %16s\n" \
           "────────────────────────────────" "──────────────" "─────────" "────────────────"
    while IFS=$'\t' read -r _usage _login; do
        [[ -z "$_login" || "$_usage" -le "$_p90" ]] && continue
        _ind_cr=$(_individual_budget "$_usage")
        _ind_usd=$(_to_usd "$_ind_cr")
        printf "  %-32s  %14d  %9s  %16s\n" \
               "$_login" "$_usage" "\$$(_to_usd "$_usage")" "\$${_ind_usd} / user"
    done < <(
        for _l in "${!_USER_30D[@]}"; do
            printf '%d\t%s\n' "${_USER_30D[$_l]}" "$_l"
        done | sort -rn
    )
    echo ""
    echo "  Suggested budget = 30-day usage rounded up to the nearest \$10."
    echo "  Individual budgets take precedence over the Universal baseline."
    echo ""
    echo "  To set each individual budget in GitHub:"
    echo "    Enterprise → Policies → Copilot → Budgets → Create budget"
    echo "    Scope: Users  |  Type: Individual user  |  Select user  |  Amount: see above"
    echo ""
fi

print_success "Universal budget: \$${_suggested_usd} per user  (${_suggested} credits)"
echo ""
