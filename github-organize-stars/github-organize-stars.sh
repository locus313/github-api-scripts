#!/usr/bin/env bash
# =============================================================================
# GitHub Stars Organizer
# Fetches all your starred repos and organizes them into GitHub Lists.
#
# Usage:
#   ./organize_stars.sh              # Interactive (shows plan, asks to confirm)
#   ./organize_stars.sh --dry-run    # Preview only, no changes
#   ./organize_stars.sh -y           # Skip confirmation prompt
#   ./organize_stars.sh --show-repos # Also list repo names in each category
#   ./organize_stars.sh --no-cache   # Force re-fetch stars from GitHub
# =============================================================================

set -uo pipefail

# ---- Dependency check -------------------------------------------------------
for cmd in gh jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not installed." >&2
    [[ "$cmd" == "jq" ]] && echo "  Install: sudo dnf install -y jq" >&2
    exit 1
  fi
done

# ---- Defaults ---------------------------------------------------------------
DRY_RUN=false
AUTO_YES=false
SHOW_REPOS=false
CACHE_FILE="${HOME}/.cache/gh-star-organizer/stars.json"
NO_CACHE=false

# ---- Parse arguments --------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=true ;;
    -y|--yes)     AUTO_YES=true ;;
    --show-repos) SHOW_REPOS=true ;;
    --no-cache)   NO_CACHE=true ;;
    -h|--help)
      head -16 "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown argument: $arg  (use --help)" >&2; exit 1 ;;
  esac
done

# =============================================================================
# CATEGORY RULES
# Format of each element: "List Name|LANGUAGES|TOPICS|NAME_KEYWORDS"
#   LANGUAGES    : comma-separated primary language names (case-insensitive)
#   TOPICS       : comma-separated GitHub topic slugs
#   NAME_KEYWORDS: comma-separated substrings matched against the repo name
#
# The FIRST matching rule wins.
# Edit these freely to match your interests.
# =============================================================================
RULES=(
  # AI first so LLM/jailbreak repos land here before Security
  "AI / ML||machine-learning,deep-learning,ai,llm,gpt,neural-network,nlp,diffusion,stable-diffusion,openai,transformers,pytorch,tensorflow,rag,embedding,langchain,generative-ai,artificial-intelligence,mcp|llm,gpt,ollama,bert,whisper,claude,anthropic,copilot,awesome-mcp,mcp-server,l1b3rt4s"
  "World of Warcraft||wow,azerothcore,trinitycore,mangos,cmangos,world-of-warcraft,wow-emulation,warcraft,world-of-warcraft-classic|azerothcore,acore,trinitycore,mangos,mod-playerbots,wotlk,chromiecraft,why-i-hate-wow"
  "Gaming / Game Servers||gaming,game-server,steam,enshrouded,bazzite|enshrouded,bazzite,game-server"
  "Linux / Desktop||linux,desktop,gnome,kde,wayland,framework-laptop,fedora-silverblue|framework-laptop,omarchy,bazzite"
  "DevOps / Infrastructure||docker,kubernetes,k8s,helm,devops,cicd,ci-cd,ansible,jenkins,github-actions,argocd,flux,gitops|k8s,kubernetes,docker,ansible,helm,infra-gitops,ssh-key-sync"
  "Monitoring||monitoring,alerting,metrics,logging,tracing,prometheus,grafana,loki,jaeger,opentelemetry,uptime,check_mk,checkmk|monitor,alert,grafana,prometheus,loki,check_mk,checkmk"
  "Intune / Microsoft 365||intune,winget,endpoint-manager,entra,microsoft-intune,microsoft-365,m365,azure-ad|intune,wintuner,entra,m365"
  "macOS / Apple Admin||macadmin,macos,mac,jamf,jamf-pro,jamf-school,mdm,apple,deployment,enrollment|supportapp,macadmin,jamf,swiftdialog,app-auto-patch,uninstaller,apple/"
  "Security||security,hacking,pentest,ctf,osint,cybersecurity,vulnerability,exploit,cryptography,appsec,red-teaming,adversarial,ssl,tls,jailbreak,ai-jailbreak|pentest,exploit,vuln,audit,testssl"
  "Self-hosted / Homelab||self-hosted,homelab,selfhosted,home-automation,home-assistant,nas,proxmox,homarr,homepage,unraid|homelab,self-host,homarr,unraid,labstack,kometa,pigsty"
  "Notes / Knowledge Base||cheat-sheets,knowledge-base,second-brain,obsidian,wiki,zettelkasten,pkm|cheat-sheet,obsidian,notebook"
  "Static Sites / Blogs||jekyll,blog,static-site,hugo,theme,website|jekyll,chirpy,reverie"
  "CLI Tools||cli,terminal,shell,bash,zsh,fish,command-line,tui,ncurses|aocla"
  "Dotfiles / Config||dotfiles,config,neovim,nvim,vim,tmux,rice,nix,nixos|dotfile,nvim,neovim,tmux"
  "PowerShell|powershell|powershell,posh|powershell-profile,psenv"
  "Python|python|python,django,flask,fastapi,asyncio,pydantic|"
  "JavaScript / TypeScript|javascript,typescript|javascript,typescript,nodejs,node-js,react,vue,angular,svelte,nextjs,nuxt|"
  "Ruby|ruby|ruby,rails,gem,bundler|kamal,campfire"
  "Go|go|go,golang|"
  "Rust|rust|rust,cargo|"
  "PHP|php|php,laravel,symfony,wordpress|"
  "AWS||aws,amazon-web-services,s3,lambda,ec2,cloudformation,cdk,serverless|aws,amazon,boto"
  "Terraform|hcl|terraform,opentofu,terragrunt,hcl|terraform,terragrunt,tflint"
  "GitHub||github,github-actions,octokit|github,octokit"
  "Tailscale / Networking||tailscale,vpn,wireguard,networking,proxy,firewall,pihole,nginx,traefik,dns,zerotier|tailscale,wireguard,zerotier,subnet,xrdp,mta-sts"
  "Windows Tools|c#|screenshot,windows,winforms|greenshot,levelrmm"
  "Smartermail||smartermail,email,smtp,imap,mail-server|smartermail"
  "Miscellaneous|||rnbwkat"
)

# =============================================================================
# HELPERS
# =============================================================================

# Check if comma-separated list $2 contains word $1
csv_contains() {
  local needle="${1,,}" haystack="${2,,}"
  local IFS=','
  for item in $haystack; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# Check if space-separated string $2 contains any word from comma-sep list $1
topics_match() {
  local rule_topics="$1" repo_topics="$2"
  local IFS=','
  for t in $rule_topics; do
    [[ " $repo_topics " == *" ${t,,} "* ]] && return 0
  done
  return 1
}

# Check if repo name/owner $2 contains any substring from comma-sep list $1
name_match() {
  local rule_kw="$1" fullname="${2,,}"
  local IFS=','
  for k in $rule_kw; do
    [[ "$fullname" == *"${k,,}"* ]] && return 0
  done
  return 1
}

get_category() {
  local lang="$1" topics="$2" repo_short="$3" repo_full="$4"
  for rule in "${RULES[@]}"; do
    local list_name rule_langs rule_topics rule_kw
    IFS='|' read -r list_name rule_langs rule_topics rule_kw <<< "$rule"

    if [[ -n "$rule_langs" ]] && csv_contains "$lang" "$rule_langs"; then
      echo "$list_name"; return
    fi
    if [[ -n "$rule_topics" ]] && topics_match "$rule_topics" "$topics"; then
      echo "$list_name"; return
    fi
    if [[ -n "$rule_kw" ]] && (name_match "$rule_kw" "$repo_short" || name_match "$rule_kw" "$repo_full"); then
      echo "$list_name"; return
    fi
  done
  echo "__UNCATEGORIZED__"
}

# =============================================================================
# GITHUB API HELPERS
# =============================================================================

fetch_stars() {
  # Uses temp files so large JSON is never passed as a shell argument
  local cursor="" has_next="true" page=1
  local tmp_dir
  tmp_dir=$(mktemp -d)

  while [[ "$has_next" == "true" ]]; do
    printf "  Fetching page %d...\r" "$page" >&2

    local page_file="$tmp_dir/page$(printf '%03d' $page).json"
    if [[ -z "$cursor" ]]; then
      gh api graphql -f query='
        query { viewer { starredRepositories(first: 100) {
          pageInfo { hasNextPage endCursor }
          nodes { id nameWithOwner
            primaryLanguage { name }
            repositoryTopics(first: 20) { nodes { topic { name } } }
          }
        }}}' > "$page_file"
    else
      gh api graphql \
        -f query='query($c: String!) { viewer { starredRepositories(first: 100, after: $c) {
          pageInfo { hasNextPage endCursor }
          nodes { id nameWithOwner
            primaryLanguage { name }
            repositoryTopics(first: 20) { nodes { topic { name } } }
          }
        }}}' \
        -f c="$cursor" > "$page_file"
    fi

    has_next=$(jq -r '.data.viewer.starredRepositories.pageInfo.hasNextPage' "$page_file")
    cursor=$(jq -r '.data.viewer.starredRepositories.pageInfo.endCursor' "$page_file")
    ((page++))
  done

  # Merge all pages into a single JSON array (reads from files, not shell vars)
  jq -s '[.[].data.viewer.starredRepositories.nodes[]]' "$tmp_dir"/page*.json
  local total
  total=$(jq -s '[.[].data.viewer.starredRepositories.nodes[]] | length' "$tmp_dir"/page*.json)
  printf "  Fetched %d starred repos.          \n" "$total" >&2
  rm -rf "$tmp_dir"
}

get_existing_lists() {
  gh api graphql \
    -f query='{ viewer { lists(first: 50) { nodes { id name } } } }' \
    --jq '.data.viewer.lists.nodes'
}

create_list() {
  local name="$1"
  gh api graphql \
    -f query='mutation($n: String!) { createUserList(input: { name: $n }) { list { id name } } }' \
    -f n="$name" \
    --jq '.data.createUserList.list.id'
}

add_to_list() {
  local list_id="$1"; shift
  local ids_json
  ids_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)

  gh api graphql --input - <<EOF
{
  "query": "mutation(\$lid: ID!, \$ids: [ID!]!) { addStarredReposToUserList(input: { listId: \$lid, starrableIds: \$ids }) { list { name itemCount } } }",
  "variables": { "lid": "$list_id", "ids": $ids_json }
}
EOF
}

# =============================================================================
# MAIN
# =============================================================================

echo "=== GitHub Stars Organizer ==="
echo

# ---- Fetch or load cached stars ---------------------------------------------
if [[ "$NO_CACHE" == "true" ]]; then
  rm -f "$CACHE_FILE"
fi

if [[ -f "$CACHE_FILE" ]]; then
  echo "Using cached stars (run with --no-cache to refresh)"
else
  echo "Fetching your starred repos..."
  mkdir -p "$(dirname "$CACHE_FILE")"
  fetch_stars > "$CACHE_FILE"
fi

TOTAL=$(jq 'length' "$CACHE_FILE")
echo "  Total stars: $TOTAL"
echo

# ---- Fetch existing lists ---------------------------------------------------
echo "Fetching existing lists..."
EXISTING_LISTS=$(get_existing_lists)
EXISTING_NAMES=$(jq -r '.[].name' <<< "$EXISTING_LISTS" | paste -sd ', ')
echo "  Existing: ${EXISTING_NAMES:-(none)}"
echo

# ---- Categorize repos -------------------------------------------------------
echo "Categorizing repos..."

# Extract TSV: id <tab> nameWithOwner <tab> lang <tab> topics(space-sep)
REPOS_TSV=$(jq -r '
  .[] | [
    .id,
    .nameWithOwner,
    (.primaryLanguage.name // ""),
    ([.repositoryTopics.nodes[].topic.name] | join(" "))
  ] | @tsv' "$CACHE_FILE")

declare -A CAT_IDS    # category -> space-sep repo node IDs
declare -A CAT_NAMES  # category -> space-sep repo names (for display)
UNCAT_COUNT=0
UNCAT_NAMES=()  # uncategorized repo names with lang for display

while IFS=$'\t' read -r repo_id repo_name repo_lang repo_topics; do
  repo_short="${repo_name##*/}"
  category=$(get_category "$repo_lang" "$repo_topics" "$repo_short" "$repo_name")

  if [[ "$category" == "__UNCATEGORIZED__" ]]; then
    ((UNCAT_COUNT++)) || true
    UNCAT_NAMES+=("$repo_name [${repo_lang:-no language}]")
  else
    CAT_IDS["$category"]+=" $repo_id"
    CAT_NAMES["$category"]+=" $repo_name"
  fi
done <<< "$REPOS_TSV"

echo

# ---- Preview ----------------------------------------------------------------
echo "=== Proposed Plan ==="
total_assigned=0

# Collect and sort output
plan_lines=()
for category in "${!CAT_IDS[@]}"; do
  ids_str="${CAT_IDS[$category]:-}"
  count=$(echo "$ids_str" | wc -w)
  total_assigned=$((total_assigned + count))

  existing_id=$(jq -r --arg n "$category" '.[] | select(.name == $n) | .id' <<< "$EXISTING_LISTS")
  [[ -n "$existing_id" ]] && status="existing" || status="new list"

  plan_lines+=("$(printf "  [%-10s] %-35s %d repos" "$status" "$category" "$count")")
done

# Print sorted by repo count (descending)
printf '%s\n' "${plan_lines[@]}" | sort -t ']' -k3 -rn

printf "  [%-10s] %-35s %d repos\n" "---" "Uncategorized" "$UNCAT_COUNT"
echo
echo "  Total: $total_assigned assigned / $UNCAT_COUNT unassigned / $TOTAL total"

if [[ "$SHOW_REPOS" == "true" ]]; then
  echo
  echo "=== Repo Details ==="
  for category in $(printf '%s\n' "${!CAT_NAMES[@]}" | sort); do
    echo "  $category:"
    for name in ${CAT_NAMES[$category]:-}; do
      echo "    - $name"
    done
  done
  echo
  echo "  Uncategorized ($UNCAT_COUNT):"
  for entry in "${UNCAT_NAMES[@]}"; do
    echo "    - $entry"
  done
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo
  echo "Dry run — no changes made."
  echo "Tip: re-run with --show-repos to see which repos go where."
  exit 0
fi

# ---- Confirm ----------------------------------------------------------------
if [[ "$AUTO_YES" != "true" ]]; then
  echo
  read -rp "Proceed with creating/updating lists? [y/N] " answer
  [[ "${answer,,}" != "y" ]] && echo "Aborted." && exit 0
fi

# ---- Execute ----------------------------------------------------------------
echo
echo "Applying changes..."

for category in "${!CAT_IDS[@]}"; do
  ids_str="${CAT_IDS[$category]:-}"
  [[ -z "${ids_str// }" ]] && continue
  read -ra ids_arr <<< "$ids_str"

  # Get or create the list
  list_id=$(jq -r --arg n "$category" '.[] | select(.name == $n) | .id' <<< "$EXISTING_LISTS")
  if [[ -z "$list_id" || "$list_id" == "null" ]]; then
    echo "  Creating list: '$category'..."
    list_id=$(create_list "$category")
    if [[ -z "$list_id" || "$list_id" == "null" ]]; then
      echo "  ERROR: Could not create list '$category', skipping." >&2
      continue
    fi
  fi

  echo "  Adding ${#ids_arr[@]} repos to '$category'..."

  # Batch in groups of 25 (API limit)
  batch_start=0
  while [[ $batch_start -lt ${#ids_arr[@]} ]]; do
    batch=("${ids_arr[@]:$batch_start:25}")
    result=$(add_to_list "$list_id" "${batch[@]}" 2>&1) || true
    item_count=$(jq -r '.data.addStarredReposToUserList.list.itemCount // "error"' <<< "$result" 2>/dev/null || echo "error")
    echo "    '$category': $item_count total items"
    batch_start=$((batch_start + 25))
  done
done

echo
echo "Done!"
username=$(gh api user --jq .login)
echo "View your lists at: https://github.com/${username}?tab=stars"
