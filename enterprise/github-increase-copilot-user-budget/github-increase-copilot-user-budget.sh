#!/usr/bin/env bash
# =============================================================================
# github-increase-copilot-user-budget.sh
#
# Raises the GitHub Copilot AI credit budget for a single enterprise user.
# Looks up the user's effective budget (user-specific or Universal), offers
# preset increases (+$50 to +$250), a custom increase, or an absolute amount,
# then asks for confirmation. The user's own AI credit budget is updated when
# one exists; otherwise a new user budget is created at the new amount.
#
# Usage:
#   export GITHUB_TOKEN=ghp_yourtoken
#   export GITHUB_ENTERPRISE=my-enterprise
#   ./github-increase-copilot-user-budget.sh -u octocat
#   ./github-increase-copilot-user-budget.sh -u octocat --increase 100 -y
#
# Options:
#   -e, --enterprise SLUG  GitHub Enterprise slug (or $GITHUB_ENTERPRISE)
#   -u, --user LOGIN       GitHub username to update (or $TARGET_USER)
#       --increase N       Raise the limit by N whole dollars (skips the menu)
#       --amount N         Set the limit to N whole dollars (skips the menu)
#       --expires DATE     Expire the user budget on DATE (YYYY-MM-DD)
#       --allow-decrease   Permit a new limit at or below the current limit
#       --dry-run          Show the planned change without applying it
#   -y, --yes              Skip the confirmation prompt
#   -h, --help             Show this message
#
# Environment variables:
#   GITHUB_TOKEN        Required. PAT with manage_billing:enterprise scope
#                       (or resolved from an active gh auth session)
#   GITHUB_ENTERPRISE   Required. GitHub Enterprise slug
#   TARGET_USER         Optional. GitHub username (prompted when unset)
#   API_URL_PREFIX      Optional. GitHub API base URL (default: https://api.github.com)
#
# Requirements:
#   - curl
#   - jq
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/github-common.sh
source "${SCRIPT_DIR}/../../lib/github-common.sh"

### GLOBAL VARIABLES
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
GITHUB_ENTERPRISE=${GITHUB_ENTERPRISE:-''}
TARGET_USER=${TARGET_USER:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
API_VERSION="2026-03-10"
INCREASE=""
AMOUNT=""
EXPIRES=""
ALLOW_DECREASE=false
DRY_RUN=false
ASSUME_YES=false
PRESET_INCREASES=(50 100 150 200 250)

usage() {
  cat <<'EOF'
Usage: github-increase-copilot-user-budget.sh [OPTIONS]

Raises the Copilot AI credit budget for a single enterprise user.

Options:
  -e, --enterprise SLUG  GitHub Enterprise slug (or $GITHUB_ENTERPRISE)
  -u, --user LOGIN       GitHub username to update (or $TARGET_USER)
      --increase N       Raise the limit by N whole dollars (skips the menu)
      --amount N         Set the limit to N whole dollars (skips the menu)
      --expires DATE     Expire the user budget on DATE (YYYY-MM-DD)
      --allow-decrease   Permit a new limit at or below the current limit
      --dry-run          Show the planned change without applying it
  -y, --yes              Skip the confirmation prompt
  -h, --help             Show this message

Required GITHUB_TOKEN scope:
  manage_billing:enterprise

Example:
  export GITHUB_TOKEN=ghp_xxxxx
  export GITHUB_ENTERPRISE=my-enterprise
  ./github-increase-copilot-user-budget.sh -u octocat
  ./github-increase-copilot-user-budget.sh -u octocat --increase 100 -y
EOF
}

# Reads from the terminal so prompts work even when stdin is piped.
tty_available() { { : </dev/tty; } 2>/dev/null; }

ask() {
  local prompt="$1" reply
  tty_available || err "Input required but no terminal is available. Pass --user, --increase/--amount and --yes."
  read -r -p "${prompt}" reply </dev/tty
  echo "${reply}"
}

require_value() {
  [[ $# -ge 2 ]] || err "Option $1 requires a value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--enterprise) require_value "$@"; GITHUB_ENTERPRISE="$2"; shift 2 ;;
    -u|--user)       require_value "$@"; TARGET_USER="$2"; shift 2 ;;
    --increase)      require_value "$@"; INCREASE="$2"; shift 2 ;;
    --amount)        require_value "$@"; AMOUNT="$2"; shift 2 ;;
    --expires)       require_value "$@"; EXPIRES="$2"; shift 2 ;;
    --allow-decrease) ALLOW_DECREASE=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    -y|--yes)        ASSUME_YES=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -n "${GITHUB_ENTERPRISE}" ]] || err "GitHub Enterprise slug is required (-e / \$GITHUB_ENTERPRISE)"
validate_slug "${GITHUB_ENTERPRISE}" "GITHUB_ENTERPRISE"
[[ -z "${TARGET_USER}" ]] || validate_slug "${TARGET_USER}" "user"

if [[ -n "${INCREASE}" && -n "${AMOUNT}" ]]; then
  err "--increase and --amount are mutually exclusive"
fi
[[ -z "${INCREASE}" ]] || [[ "${INCREASE}" =~ ^[1-9][0-9]*$ ]] \
  || err "--increase must be a positive whole number of dollars"
[[ -z "${AMOUNT}" ]] || [[ "${AMOUNT}" =~ ^[0-9]+$ ]] \
  || err "--amount must be a whole number of dollars"
if [[ -n "${EXPIRES}" ]]; then
  [[ "${EXPIRES}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || err "--expires must be in YYYY-MM-DD format"
  [[ "${EXPIRES}" > "$(date +%Y-%m-%d)" ]] || err "--expires must be a future date"
fi

require_command curl
require_command jq
require_env_var GITHUB_TOKEN
validate_github_token "bearer"

if [[ -z "${TARGET_USER}" ]]; then
  TARGET_USER=$(ask "GitHub username to update: ")
  validate_slug "${TARGET_USER}" "user"
fi

BUDGETS_PATH="/enterprises/${GITHUB_ENTERPRISE}/settings/billing/budgets"

# Prints one JSON object with .budgets (all pages) and .effective_budget
# (taken from the first page that provides it).
fetch_budgets() {
  local scope="$1" page=1 resp merged='{"budgets":[],"effective_budget":null}'
  while true; do
    resp=$(gh_api "${BUDGETS_PATH}?scope=${scope}&user=${TARGET_USER}&per_page=100&page=${page}" \
      --api-version "${API_VERSION}")
    if [[ "${resp}" == "__404__" || "${resp}" == "__422__" ]]; then
      err "Budgets endpoint unavailable for enterprise '${GITHUB_ENTERPRISE}' (budgets feature disabled, or the slug is wrong)"
    fi
    merged=$(jq -n --argjson m "${merged}" --argjson r "${resp}" \
      '{budgets: ($m.budgets + ($r.budgets // [])),
        effective_budget: ($m.effective_budget // $r.effective_budget // null),
        has_next_page: ($r.has_next_page // false)}')
    [[ "$(jq -r '.has_next_page' <<<"${merged}")" == "true" ]] || break
    page=$(( page + 1 ))
  done
  echo "${merged}"
}

print_status "Looking up Copilot AI credit budget for '${TARGET_USER}'..."
USER_BUDGETS=$(fetch_budgets "user")

USER_LC=$(tr '[:upper:]' '[:lower:]' <<<"${TARGET_USER}")
MATCHES=$(jq -c --arg u "${USER_LC}" \
  '[.budgets[] | select(.budget_scope == "user" and ((.user // "") | ascii_downcase) == $u and .budget_product_sku == "ai_credits")]' \
  <<<"${USER_BUDGETS}")
MATCH_COUNT=$(jq 'length' <<<"${MATCHES}")
[[ "${MATCH_COUNT}" -le 1 ]] || err "Found ${MATCH_COUNT} AI credit user budgets for '${TARGET_USER}'; refusing to guess which to update"

EFFECTIVE=$(jq -c '.effective_budget' <<<"${USER_BUDGETS}")
if [[ "${EFFECTIVE}" == "null" ]]; then
  EFFECTIVE=$(jq -c '.effective_budget' <<<"$(fetch_budgets "multi_user_customer")")
fi
if [[ "${EFFECTIVE}" == "null" ]]; then
  err "No effective budget found for '${TARGET_USER}'. Verify the username and that a Copilot budget applies to them."
fi

CURRENT=$(jq -r '.budget_amount' <<<"${EFFECTIVE}")
CONSUMED=$(jq -r '.consumed_amount // 0' <<<"${EFFECTIVE}")
BUDGET_ID=$(jq -r '.[0].id // empty' <<<"${MATCHES}")

if [[ -n "${BUDGET_ID}" ]]; then
  KIND="user budget (id ${BUDGET_ID})"
else
  KIND="Universal budget (a new user budget will be created)"
fi

echo
echo "User:             ${TARGET_USER}"
echo "Applies:          ${KIND}"
echo "Current limit:    \$${CURRENT}"
echo "Consumed:         \$${CONSUMED}"
echo

if [[ -n "${INCREASE}" ]]; then
  NEW_LIMIT=$(( CURRENT + INCREASE ))
elif [[ -n "${AMOUNT}" ]]; then
  NEW_LIMIT="${AMOUNT}"
else
  echo "Choose a new limit:"
  idx=1
  for inc in "${PRESET_INCREASES[@]}"; do
    echo "  ${idx}) +\$${inc}  (-> \$$(( CURRENT + inc )))"
    idx=$(( idx + 1 ))
  done
  custom_opt=${idx}
  absolute_opt=$(( idx + 1 ))
  echo "  ${custom_opt}) Custom increase"
  echo "  ${absolute_opt}) Set absolute amount"
  choice=$(ask "Selection [1-${absolute_opt}]: ")
  if [[ "${choice}" =~ ^[0-9]+$ && "${choice}" -ge 1 && "${choice}" -le "${#PRESET_INCREASES[@]}" ]]; then
    NEW_LIMIT=$(( CURRENT + PRESET_INCREASES[choice - 1] ))
  elif [[ "${choice}" == "${custom_opt}" ]]; then
    value=$(ask "Increase by how many dollars? ")
    [[ "${value}" =~ ^[1-9][0-9]*$ ]] || err "Increase must be a positive whole number of dollars"
    NEW_LIMIT=$(( CURRENT + value ))
  elif [[ "${choice}" == "${absolute_opt}" ]]; then
    value=$(ask "New limit in dollars: ")
    [[ "${value}" =~ ^[0-9]+$ ]] || err "Limit must be a whole number of dollars"
    NEW_LIMIT="${value}"
  else
    err "Invalid selection '${choice}'"
  fi
  if [[ -z "${EXPIRES}" ]]; then
    EXPIRES=$(ask "Expiry date YYYY-MM-DD (blank for none): ")
    if [[ -n "${EXPIRES}" ]]; then
      [[ "${EXPIRES}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || err "Expiry must be in YYYY-MM-DD format"
      [[ "${EXPIRES}" > "$(date +%Y-%m-%d)" ]] || err "Expiry must be a future date"
    fi
  fi
fi

if [[ "${NEW_LIMIT}" -le "${CURRENT}" && "${ALLOW_DECREASE}" != true ]]; then
  err "New limit \$${NEW_LIMIT} is not above the current limit \$${CURRENT}. Use --allow-decrease to override."
fi

if [[ -n "${BUDGET_ID}" ]]; then
  PAYLOAD=$(jq -n --argjson amt "${NEW_LIMIT}" --arg exp "${EXPIRES}" \
    '{budget_amount: $amt, prevent_further_usage: true}
     + (if $exp != "" then {expires_at: $exp} else {} end)')
else
  PAYLOAD=$(jq -n --argjson amt "${NEW_LIMIT}" --arg user "${TARGET_USER}" --arg exp "${EXPIRES}" \
    '{budget_amount: $amt, prevent_further_usage: true, budget_scope: "user",
      budget_entity_name: "", budget_type: "BundlePricing", budget_product_sku: "ai_credits",
      budget_alerting: {will_alert: false, alert_recipients: []}, user: $user}
     + (if $exp != "" then {expires_at: $exp} else {} end)')
fi

echo "New limit:        \$${NEW_LIMIT}  (change: \$$(( NEW_LIMIT - CURRENT )))"
[[ -z "${EXPIRES}" ]] || echo "Expires:          ${EXPIRES}"
echo

if [[ "${DRY_RUN}" == true ]]; then
  print_warning "Dry run: no changes made. Payload that would be sent:"
  echo "${PAYLOAD}"
  exit 0
fi

if [[ "${ASSUME_YES}" != true ]]; then
  confirm=$(ask "Apply this change? [y/N]: ")
  [[ "${confirm}" =~ ^[Yy]([Ee][Ss])?$ ]] || { print_warning "Cancelled. No changes made."; exit 0; }
fi

if [[ -n "${BUDGET_ID}" ]]; then
  RESULT=$(gh_api "${BUDGETS_PATH}/${BUDGET_ID}" --api-version "${API_VERSION}" \
    -X PATCH -H "Content-Type: application/json" -d "${PAYLOAD}")
else
  RESULT=$(gh_api "${BUDGETS_PATH}" --api-version "${API_VERSION}" \
    -X POST -H "Content-Type: application/json" -d "${PAYLOAD}")
fi

if [[ "${RESULT}" == "__404__" || "${RESULT}" == "__422__" ]]; then
  err "GitHub rejected the budget change (${RESULT//_/}). Check token scopes and the request values."
fi

print_success "$(jq -r '.message // "Budget updated"' <<<"${RESULT}"): ${TARGET_USER} limit is now \$$(jq -r '.budget.budget_amount // empty' <<<"${RESULT}")"
