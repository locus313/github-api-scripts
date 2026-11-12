#!/usr/bin/env bash
# =============================================================================
# github-enterprise-billing-report.sh
#
# Generates a billing report for a GitHub Enterprise: net cost per billing
# product (Enterprise Cloud, Advanced Security, Actions, Copilot, ...) for the
# last N complete months, with charts showing which products grew over time
# and the top organizations and repositories by cost. Writes a self-contained
# HTML file (inline SVG charts), a PDF rendered from it, and a CSV of the
# monthly figures.
#
# Usage:
#   export GITHUB_TOKEN=ghp_yourtoken
#   export GITHUB_ENTERPRISE=my-enterprise
#   ./github-enterprise-billing-report.sh [options]
#
# Options:
#   --no-pdf     Skip PDF generation
#   -h, --help   Show this message
#
# Environment variables:
#   GITHUB_TOKEN       Required. PAT with manage_billing:enterprise scope
#                      (enterprise admin or billing manager)
#   GITHUB_ENTERPRISE  Required. GitHub Enterprise slug
#   MONTHS             Optional. Complete months to report, 1-24 (default: 3).
#                      GitHub only serves the past 24 months.
#   ORGS               Optional. Comma-separated orgs to limit the report to
#                      (default: whole enterprise)
#   REPORT_DIR         Optional. Output directory (default: ./reports)
#   BRAND_LOGO         Optional. Path to a .png, .jpg, .gif or .svg logo, embedded
#                      in the HTML next to the report title
#   BRAND_NAME         Optional. Wordmark text shown above the report title
#   BRAND_TITLE        Optional. Report title (default: GitHub Enterprise billing
#                      report: <enterprise>)
#   BRAND_COLOR        Optional. Hex accent color such as #0969da, used for
#                      headings and as the first chart color
#   BRAND_FOOTER       Optional. Extra line of text in the report footer
#   BRAND_PALETTE      Optional. Comma-separated hex colors replacing the chart
#                      palette (first color is used for the first billing product)
#   BRAND_CSS          Optional. Path to a CSS file inlined after the default
#                      styles; BRAND_COLOR is exposed to it as --brand
#   API_URL_PREFIX     Optional. GitHub API base URL (default: https://api.github.com)
#
# Requirements:
#   - curl
#   - jq
#   - Chrome/Chromium or wkhtmltopdf (optional, for the PDF)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/github-common.sh
source "${SCRIPT_DIR}/../../lib/github-common.sh"

### GLOBAL VARIABLES
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
GITHUB_ENTERPRISE=${GITHUB_ENTERPRISE:-''}
MONTHS=${MONTHS:-3}
ORGS=${ORGS:-''}
REPORT_DIR=${REPORT_DIR:-./reports}
BRAND_LOGO=${BRAND_LOGO:-''}
BRAND_NAME=${BRAND_NAME:-''}
BRAND_TITLE=${BRAND_TITLE:-''}
BRAND_COLOR=${BRAND_COLOR:-''}
BRAND_FOOTER=${BRAND_FOOTER:-''}
BRAND_PALETTE=${BRAND_PALETTE:-''}
BRAND_CSS=${BRAND_CSS:-''}
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}
BILLING_API_VERSION='2026-03-10'
NO_PDF=false

usage() {
  cat <<'EOF'
Usage: github-enterprise-billing-report.sh [--no-pdf]

Generates HTML, PDF and CSV billing cost reports per billing product.

Environment variables:
  GITHUB_TOKEN       Required. PAT with manage_billing:enterprise scope
  GITHUB_ENTERPRISE  Required. GitHub Enterprise slug
  MONTHS             Optional. Complete months to report, 1-24 (default: 3)
  ORGS               Optional. Comma-separated orgs to limit the report to
  REPORT_DIR         Optional. Output directory (default: ./reports)
  BRAND_LOGO         Optional. Path to a .png, .jpg, .gif or .svg logo
  BRAND_NAME         Optional. Wordmark text above the title
  BRAND_TITLE        Optional. Report title
  BRAND_COLOR        Optional. Hex accent color, e.g. #0969da
  BRAND_FOOTER       Optional. Extra footer text
  BRAND_PALETTE      Optional. Comma-separated hex chart colors
  BRAND_CSS          Optional. Path to a CSS file applied after the default styles
  API_URL_PREFIX     Optional. GitHub API base URL

Options:
  --no-pdf           Skip PDF generation
  -h, --help         Show this message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pdf) NO_PDF=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

require_env_var GITHUB_ENTERPRISE
validate_slug "${GITHUB_ENTERPRISE}" "GITHUB_ENTERPRISE"
if ! [[ "${MONTHS}" =~ ^[0-9]+$ ]] || (( MONTHS < 1 || MONTHS > 24 )); then
  err "MONTHS must be a whole number between 1 and 24"
fi
if [[ -n "${BRAND_COLOR}" && ! "${BRAND_COLOR}" =~ ^#[0-9a-fA-F]{6}$ ]]; then
  err "BRAND_COLOR must be a hex color such as #0969da"
fi
PALETTE_JSON='[]'
if [[ -n "${BRAND_PALETTE}" ]]; then
  [[ "${BRAND_PALETTE}" =~ ^#[0-9a-fA-F]{6}(,#[0-9a-fA-F]{6})*$ ]] \
    || err "BRAND_PALETTE must be comma-separated hex colors such as #0969da,#1a7f37"
  PALETTE_JSON="$(jq -cn --arg p "${BRAND_PALETTE}" '$p | split(",")')"
fi
CSS_TEXT=''
if [[ -n "${BRAND_CSS}" ]]; then
  [[ -f "${BRAND_CSS}" ]] || err "BRAND_CSS file not found: ${BRAND_CSS}"
  CSS_TEXT="$(cat "${BRAND_CSS}")"
  # Prevents the stylesheet from closing the style element
  [[ "${CSS_TEXT}" != *"</"* ]] || err "BRAND_CSS must not contain markup"
fi
LOGO_URI=''
if [[ -n "${BRAND_LOGO}" ]]; then
  [[ -f "${BRAND_LOGO}" ]] || err "BRAND_LOGO file not found: ${BRAND_LOGO}"
  case "$(printf '%s' "${BRAND_LOGO}" | tr '[:upper:]' '[:lower:]')" in
    *.png) LOGO_MIME=image/png ;;
    *.jpg|*.jpeg) LOGO_MIME=image/jpeg ;;
    *.gif) LOGO_MIME=image/gif ;;
    *.svg) LOGO_MIME=image/svg+xml ;;
    *) err "BRAND_LOGO must be a .png, .jpg, .gif or .svg file" ;;
  esac
  require_command base64
  LOGO_URI="data:${LOGO_MIME};base64,$(base64 < "${BRAND_LOGO}" | tr -d '\n')"
fi
require_command curl
require_command jq
require_env_var GITHUB_TOKEN
validate_github_token "bearer"

IFS=',' read -r -a ORG_LIST <<< "${ORGS}"
for org in ${ORG_LIST[@]+"${ORG_LIST[@]}"}; do
  [[ -z "${org}" ]] || validate_slug "${org}" "ORGS entry"
done

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
ROWS_FILE="${WORK_DIR}/rows.ndjson"
SPEND_FILE="${WORK_DIR}/spend.ndjson"
: > "${ROWS_FILE}"
: > "${SPEND_FILE}"

# Appends the usage items of one month (optionally one org) to ROWS_FILE.
# Returns 1 when the API has no data for that request.
fetch_month() {
  local month="$1" org="${2:-}" query resp
  query="year=${month%-*}&month=$((10#${month#*-}))"
  [[ -z "${org}" ]] || query+="&organization=${org}"
  resp=$(gh_api "/enterprises/${GITHUB_ENTERPRISE}/settings/billing/usage/summary?${query}" \
    --api-version "${BILLING_API_VERSION}") || return 1
  [[ "${resp}" == "__404__" || "${resp}" == "__422__" ]] && return 1
  jq -c --arg m "${month}" \
    '.usageItems[]? | {month: $m, product, sku, gross: .grossAmount, discount: .discountAmount, net: .netAmount}' \
    <<< "${resp}" >> "${ROWS_FILE}"
}

# Appends one month's net cost per organization and per repository to
# SPEND_FILE. The usage endpoint ignores organization=, so ORGS is applied here.
fetch_spend() {
  local month="$1" resp
  resp=$(gh_api "/enterprises/${GITHUB_ENTERPRISE}/settings/billing/usage?year=${month%-*}&month=$((10#${month#*-}))" \
    --api-version "${BILLING_API_VERSION}") || return 1
  [[ "${resp}" == "__404__" || "${resp}" == "__422__" ]] && return 1
  jq -c --arg m "${month}" --arg orgs "${ORGS}" '
    ($orgs | ascii_downcase | split(",") | map(select(. != ""))) as $only
    | [.usageItems[]? | select(.organizationName != null) | select(($only | length) == 0 or (.organizationName | ascii_downcase | IN($only[])))]
    | (group_by(.organizationName)[] | {month: $m, kind: "org", name: .[0].organizationName, net: (map(.netAmount) | add)}),
      (map(select((.repositoryName // "") != "")) | group_by([.organizationName, .repositoryName])[]
       | {month: $m, kind: "repo", name: "\(.[0].organizationName)/\(.[0].repositoryName)", net: (map(.netAmount) | add)}),
      (map(select(.organizationName == "")) | group_by([.product, .sku])[]
       | {month: $m, kind: "ent", name: "\(.[0].product): \(.[0].sku)", net: (map(.netAmount) | add)})' \
    <<< "${resp}" >> "${SPEND_FILE}"
}

# The window is the last MONTHS complete months; the current month is excluded.
CUR_YEAR=$(date +%Y)
CUR_MONTH=$((10#$(date +%m)))
MONTH_LIST=()
for ((i = MONTHS; i >= 1; i--)); do
  y=${CUR_YEAR}
  m=$((CUR_MONTH - i))
  while ((m < 1)); do m=$((m + 12)); y=$((y - 1)); done
  MONTH_LIST+=("$(printf '%04d-%02d' "${y}" "${m}")")
done

print_status "Fetching billing usage for ${MONTH_LIST[0]} to ${MONTH_LIST[${#MONTH_LIST[@]} - 1]}..."
AVAILABLE=()
for month in "${MONTH_LIST[@]}"; do
  before=$(wc -l < "${ROWS_FILE}")
  if [[ -z "${ORGS}" ]]; then
    fetch_month "${month}" || true
  else
    for org in "${ORG_LIST[@]}"; do
      [[ -z "${org}" ]] || fetch_month "${month}" "${org}" || true
    done
  fi
  if (( $(wc -l < "${ROWS_FILE}") > before )); then
    AVAILABLE+=("${month}")
    fetch_spend "${month}" || print_warning "No organization or repository detail for ${month}"
  else
    print_warning "No billing data returned for ${month}; skipping"
  fi
done
((${#AVAILABLE[@]} > 0)) || err "No billing data returned for any month in the window"

MONTHS_JSON=$(printf '%s\n' "${AVAILABLE[@]}" | jq -R . | jq -cs .)

mkdir -p "${REPORT_DIR}"
BASE="${REPORT_DIR}/billing-report-${GITHUB_ENTERPRISE}-${AVAILABLE[${#AVAILABLE[@]} - 1]}"

jq -rs '
  ["month","product","gross","discount","net"],
  (group_by([.month, .product])[]
   | [.[0].month, .[0].product, (map(.gross) | add), (map(.discount) | add), (map(.net) | add)])
  | @csv' "${ROWS_FILE}" > "${BASE}.csv"

# shellcheck disable=SC2016  # jq program, not shell
JQ_REPORT='
def n: (. * 10 | round) / 10;
def money:
  (. * 100 | round) as $c
  | ($c | fabs) as $a
  | (($a / 100 | floor) | tostring) as $d
  | (($a % 100) | tostring | if length < 2 then "0" + . else . end) as $f
  | (if $c < 0 then "-$" else "$" end) + $d + "." + $f;
def pct: if . == null then "n/a" else ((. * 10 | round) / 10 | tostring) + "%" end;
def palette:
  (if ($palette | length) > 0 then $palette
   else (if $color == "" then ["#1f77b4"] else [$color] end) + ["#d62728","#2ca02c","#ff7f0e","#9467bd","#8c564b","#e377c2","#17becf","#bcbd22","#7f7f7f"] end);
def esc: tostring | @html;

. as $rows
| $months as $ms
| ($ms | length) as $n
| $ms as $complete
| ($complete | length) as $nc
| def mlabel($i): $ms[$i];
  def monthly($p; $m): [$rows[] | select(.product == $p and .month == $m) | .net] | add // 0;
  def total($p; $f): [$rows[] | select(.product == $p) | .[$f]] | add // 0;
  ([$rows[].product] | unique) as $products
| [ $products[] as $p
    | { product: $p,
        series: [ $ms[] as $m | monthly($p; $m) ],
        gross: total($p; "gross"), discount: total($p; "discount"), net: total($p; "net") }
    | if $nc >= 2 then
        .series[0] as $f | .series[$nc - 1] as $l
        | . + {first: $f, last: $l, change: ($l - $f),
               pct: (if $f > 0 then (($l - $f) / $f * 100) else null end)}
      else . + {first: null, last: null, change: null, pct: null} end
  ] | sort_by(-.net) as $prods
| [ range(0; $n) as $i | ([$prods[].series[$i]] | add // 0) ] as $totals
| def color($j): palette | .[$j % length];

  def stacked:
    ([($totals | max), 1] | max) as $mx
    | (1020 / $n) as $band
    | [ "<svg role=\"img\" aria-labelledby=\"c1t c1d\" viewBox=\"0 0 1100 340\" width=\"100%\" xmlns=\"http://www.w3.org/2000/svg\">",
        "<title id=\"c1t\">Monthly net cost by billing product</title>",
        "<desc id=\"c1d\">Stacked bars of net cost per month. Totals: \([range(0; $n) as $i | "\(mlabel($i)) \($totals[$i] | money)"] | join(", "))</desc>",
        ( (0, 0.25, 0.5, 0.75, 1) as $f
          | (290 - $f * 275 | n) as $y
          | "<line x1=\"70\" x2=\"1090\" y1=\"\($y)\" y2=\"\($y)\" stroke=\"#ddd\"/><text x=\"64\" y=\"\($y + 4)\" text-anchor=\"end\" font-size=\"11\">\($f * $mx | money)</text>" ),
        ( range(0; $n) as $i
          | (70 + $i * $band + $band * 0.2 | n) as $x
          | ($band * 0.6 | n) as $w
          | ( ( $prods | to_entries[]
                | .key as $j | .value as $p
                | ([$prods[:$j][].series[$i]] | add // 0) as $cum
                | ($p.series[$i] / $mx * 275 | n) as $h
                | (290 - ($cum + $p.series[$i]) / $mx * 275 | n) as $y
                | "<rect x=\"\($x)\" y=\"\($y)\" width=\"\($w)\" height=\"\($h)\" fill=\"\(color($j))\"><title>\($p.product | esc), \(mlabel($i)): \($p.series[$i] | money)</title></rect>" ),
              "<text x=\"\($x + $w / 2 | n)\" y=\"310\" text-anchor=\"middle\" font-size=\"11\">\(mlabel($i))</text>" ) ),
        "</svg>"
      ] | join("");

  def legend:
    "<ul class=\"legend\">" + ([ $prods | to_entries[] | "<li><span style=\"background:\(color(.key))\"></span>\(.value.product | esc)</li>" ] | join("")) + "</ul>";

  def line($p; $j):
    ([($p.series | max), 1] | max) as $mx
    | (440 / ([$n - 1, 1] | max)) as $step
    | [ range(0; $n) as $i | [(60 + $i * $step | n), (122 - $p.series[$i] / $mx * 110 | n)] ] as $pts
    | "<figure><svg role=\"img\" aria-labelledby=\"l\($j)t\" viewBox=\"0 0 520 150\" width=\"100%\" xmlns=\"http://www.w3.org/2000/svg\">"
      + "<title id=\"l\($j)t\">\($p.product | esc) net cost per month: \([range(0; $n) as $i | "\(mlabel($i)) \($p.series[$i] | money)"] | join(", "))</title>"
      + "<line x1=\"60\" x2=\"500\" y1=\"122\" y2=\"122\" stroke=\"#999\"/>"
      + "<text x=\"56\" y=\"16\" text-anchor=\"end\" font-size=\"10\">\($mx | money)</text><text x=\"56\" y=\"122\" text-anchor=\"end\" font-size=\"10\">$0.00</text>"
      + "<polyline fill=\"none\" stroke=\"\(color($j))\" stroke-width=\"2\" points=\"\([$pts[] | "\(.[0]),\(.[1])"] | join(" "))\"/>"
      + ([ $pts[] | "<circle cx=\"\(.[0])\" cy=\"\(.[1])\" r=\"3\" fill=\"\(color($j))\"/>" ] | join(""))
      + ([ range(0; $n) as $i | "<text x=\"\($pts[$i][0])\" y=\"140\" text-anchor=\"middle\" font-size=\"9\">\($ms[$i][2:])</text>" ] | join(""))
      + "</svg><figcaption>\($p.product | esc)</figcaption></figure>";

  def growth:
    ([$prods[] | select(.change != null)] | sort_by(-.change)) as $g
    | ([$g[].change | fabs] | max // 0 | if . == 0 then 1 else . end) as $mx
    | "<svg role=\"img\" aria-labelledby=\"gt\" viewBox=\"0 0 1100 \(($g | length) * 28 + 10)\" width=\"100%\" xmlns=\"http://www.w3.org/2000/svg\">"
      + "<title id=\"gt\">Change in monthly net cost, \($complete[0]) to \($complete[-1]), by billing product</title>"
      + ([ $g | to_entries[] | .key as $k | .value as $p
           | ($p.change | fabs / $mx * 380 | n) as $w
           | (if $p.change >= 0 then 500 else 500 - $w end) as $x
           | "<text x=\"10\" y=\"\($k * 28 + 20)\" font-size=\"12\">\($p.product | esc)</text>"
             + "<rect x=\"\($x)\" y=\"\($k * 28 + 6)\" width=\"\($w)\" height=\"18\" fill=\"\(if $p.change >= 0 then "#d62728" else "#2ca02c" end)\"/>"
             + "<text x=\"\(if $p.change >= 0 then $x + $w + 6 else $x - 6 end)\" y=\"\($k * 28 + 20)\" font-size=\"12\" text-anchor=\"\(if $p.change >= 0 then "start" else "end" end)\">\(if $p.change >= 0 then "+" else "" end)\($p.change | money)</text>" ] | join(""))
      + "<line x1=\"500\" x2=\"500\" y1=\"0\" y2=\"\(($g | length) * 28 + 10)\" stroke=\"#666\"/></svg>";

  def card($n; $l): "<div class=\"card\"><div class=\"n\">\($n)</div><div class=\"l\">\($l | esc)</div></div>";
  def cards:
    ([$prods[] | select(.change != null)] | sort_by(-.change) | .[0]) as $top
    | "<div class=\"cards\">"
      + card(([$prods[].net] | add // 0) | money; "Total net, window")
      + (if $nc >= 1 then card($totals[$nc - 1] | money; "Net, \($complete[-1])") else "" end)
      + (if ($prods | length) > 0 then card($prods[0].product | esc; "Largest product: \($prods[0].net | money)") else "" end)
      + (if $top != null and $top.change > 0 then card("+\($top.change | money)"; "Fastest growing: \($top.product)") else "" end)
      + card($prods | length; "Billing products")
      + "</div>";

  def th($t): "<th scope=\"col\">\($t)</th>";
  def td($t): "<td>\($t)</td>";
  def summary_table:
    "<table><caption>Net cost by billing product</caption><thead><tr>"
    + ([th("Billing product")] + [$ms[] | th(.)] + [th("Total net"), th("Change"), th("Change %"), th("Trend")] | join(""))
    + "</tr></thead><tbody>"
    + ([ $prods[] | "<tr><th scope=\"row\">\(.product | esc)</th>"
         + ([.series[] | td(money)] | join(""))
         + td(.net | money) + td(if .change == null then "n/a" else (if .change >= 0 then "+" else "" end) + (.change | money) end)
         + td(.pct | pct)
         + td(if .change == null then "n/a" elif .change > 0 then "Grew" elif .change < 0 then "Shrank" else "Flat" end) + "</tr>" ] | join(""))
    + "<tr><th scope=\"row\">Total</th>" + ([$totals[] | td(money)] | join("")) + td(([$prods[].net] | add) | money) + "<td></td><td></td><td></td></tr>"
    + "</tbody></table>";

  ([$prods[].net] | add // 0) as $grand
  | def top_table($kind; $label; $caption):
    ($spend | map(select(.kind == $kind and .name != "")) | group_by(.name)
     | map(. as $g | {name: .[0].name, net: (map(.net) | add),
                      series: [$ms[] as $m | [$g[] | select(.month == $m) | .net] | add // 0]})
     | sort_by(-.net) | .[:10]) as $t
    | if ($t | length) == 0 then "" else
      "<table><caption>\($caption)</caption><thead><tr>"
      + ([th($label)] + [$ms[] | th(.)] + [th("Total net"), th("Share of total")] | join(""))
      + "</tr></thead><tbody>"
      + ([ $t[] | "<tr><th scope=\"row\">\(.name | esc)</th>"
           + ([.series[] | td(money)] | join(""))
           + td(.net | money) + td(if $grand > 0 then .net / $grand * 100 else null end | pct) + "</tr>" ] | join(""))
      + "</tbody></table>" end;

  def sku_table($p):
    "<h3>\($p.product | esc)</h3><table><caption>\($p.product | esc) net cost by SKU per month, with window totals</caption><thead><tr>"
    + ([th("SKU")] + [$ms[] | th(.)] + [th("Gross"), th("Discount"), th("Total net")] | join(""))
    + "</tr></thead><tbody>"
    + ([ $rows | map(select(.product == $p.product)) | group_by(.sku)
         | map(. as $g | {sku: .[0].sku, gross: (map(.gross) | add), discount: (map(.discount) | add), net: (map(.net) | add),
                          series: [$ms[] as $m | [$g[] | select(.month == $m) | .net] | add // 0]})
         | sort_by(-.net)[]
         | "<tr><th scope=\"row\">\(.sku | esc)</th>" + ([.series[] | td(money)] | join("")) + "\(td(.gross | money))\(td(.discount | money))\(td(.net | money))</tr>" ] | join(""))
    + "</tbody></table>";

  ([ "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>\($heading | esc)</title>",
     "<style>body{font-family:sans-serif;max-width:960px;margin:2rem auto;padding:0 1rem;color:#1f2328}h1,h2,h3{color:\(if $color == "" then "#1f2328" else $color end)}header p{margin:0}table{border-collapse:collapse;width:100%;margin:1rem 0;font-size:.85rem}caption{text-align:left;font-weight:bold;margin-bottom:.4rem}th,td{border:1px solid #d0d7de;padding:.3rem .5rem;text-align:right}th[scope=row],thead th:first-child{text-align:left}thead th{background:#f6f8fa}.legend{list-style:none;padding:0;display:flex;flex-wrap:wrap;gap:.3rem 1rem}.legend span{display:inline-block;width:.8rem;height:.8rem;margin-right:.3rem}.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:1rem}figure{margin:0}figure svg{display:block;max-width:100%;height:auto}figcaption{text-align:center;font-size:.85rem}section{break-inside:avoid}@media print{body{margin:0}}\(if $color == "" then "" else ":root{--brand:\($color)}" end)\(".cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(10rem,1fr));gap:.75rem;margin:1rem 0}.card{border:1px solid #d0d7de;border-radius:6px;padding:.6rem .8rem}.card .n{font-size:1.5rem;font-weight:bold}.card .l{font-size:.75rem;text-transform:uppercase;letter-spacing:.06em}.chart{margin:0}.brand{display:flex;align-items:center;gap:.6rem;font-weight:600;letter-spacing:.3em;text-transform:uppercase}.brand img{height:2rem}.eyebrow{margin-top:1rem;font-size:.75rem;font-weight:600;letter-spacing:.15em;text-transform:uppercase}header h1{margin:.3rem 0}.note{border-left:4px solid #d0d7de;background:#f6f8fa;padding:.6rem 1rem;margin:1rem 0}.note p{margin:.3rem 0}")</style>\(if $css == "" then "" else "<style>\($css)</style>" end)</head><body>",
     "<header>",
     (if $logo != "" or $name != "" then "<div class=\"brand\">\(if $logo != "" then "<img class=\"logo\" src=\"\($logo)\" alt=\"\">" else "" end)\($name | esc)</div>" else "" end),
     "<div class=\"eyebrow\">GitHub Enterprise &nbsp;|&nbsp; Billing report</div>",
     "<h1>\($heading | esc)</h1>",
     "<p class=\"sub\">\($enterprise | esc) &nbsp;|&nbsp; \($ms[0]) to \($ms[-1]) &nbsp;|&nbsp; Generated \($generated)</p></header>",
     "<h2>Overview</h2>", cards,
     "<div class=\"note\"><p>Reporting window: \($ms[0]) to \($ms[-1]), complete months only. Amounts are net USD as returned by GitHub\(if $orgs != "" then ", limited to organizations: \($orgs | esc)" else "" end).</p>",
     (if ([$prods[].product | ascii_downcase | select(test("^ghec$|enterprise|licen[cs]e"))] | length) == 0
      then "<p><strong>Enterprise Cloud licence seats:</strong> not available from the billing API for this enterprise.</p>" else "" end),
     "</div>",
     "<h2>Monthly cost by billing product</h2><figure class=\"chart\">", stacked, legend, "</figure>",
     "<h2>Growth</h2>",
     (if $nc >= 2 then "<p>Change in monthly net cost from \($complete[0]) to \($complete[-1]); red bars grew, green bars shrank.</p><figure class=\"chart\">" + growth + "</figure>"
      else "<p>Growth needs at least two complete months of data.</p>" end),
     (if ($spend | length) > 0 then "<h2>Top organizations and repositories</h2>" + top_table("org"; "Organization"; "Top organizations by net cost per month, ranked by window total")
      + top_table("repo"; "Repository"; "Top repositories by net cost per month, ranked by window total")
      + (top_table("ent"; "Billing product: SKU"; "Billed to the enterprise account, not to any organization") | if . == "" then . else "<h3>Enterprise account</h3><p>Seat licences held by users outside every organization, so they are left out of the organization ranking above.</p>" + . end) else "" end),
     "<h2>Each billing product over time</h2><div class=\"grid\">",
     ([ $prods | to_entries[] | line(.value; .key) ] | join("")),
     "</div><h2>Summary</h2>", summary_table,
     "<h2>Detail by SKU</h2>", ([ $prods[] | sku_table(.) ] | join("")),
     "<footer><p>Generated \($generated). Data as returned by GitHub; it may differ from your invoice.</p>\(if $footer != "" then "<p>\($footer | esc)</p>" else "" end)</footer></body></html>" ] | join("\n"))
'

jq -rs --argjson months "${MONTHS_JSON}" \
  --arg enterprise "${GITHUB_ENTERPRISE}" --arg orgs "${ORGS}" \
  --arg heading "${BRAND_TITLE:-GitHub Enterprise billing report: ${GITHUB_ENTERPRISE}}" \
  --argjson palette "${PALETTE_JSON}" --arg css "${CSS_TEXT}" --slurpfile spend "${SPEND_FILE}" \
  --arg color "${BRAND_COLOR}" --arg name "${BRAND_NAME}" --arg footer "${BRAND_FOOTER}" --arg logo "${LOGO_URI}" \
  --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "${JQ_REPORT}" "${ROWS_FILE}" > "${BASE}.html"
print_success "Wrote ${BASE}.html and ${BASE}.csv"

# Prints the first available PDF renderer's command, or nothing.
find_pdf_renderer() {
  local c
  for c in google-chrome chromium chromium-browser chrome \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
    if command -v "${c}" > /dev/null 2>&1 || [[ -x "${c}" ]]; then echo "${c}"; return; fi
  done
  command -v wkhtmltopdf || true
}

if [[ "${NO_PDF}" == true ]]; then
  exit 0
fi

RENDERER="$(find_pdf_renderer)"
HTML_ABS="$(cd "$(dirname "${BASE}.html")" && pwd)/$(basename "${BASE}.html")"
PDF_ABS="$(dirname "${HTML_ABS}")/$(basename "${BASE}.pdf")"
if [[ -z "${RENDERER}" ]]; then
  print_warning "No Chrome, Chromium or wkhtmltopdf found; skipping PDF"
elif [[ "$(basename "${RENDERER}")" == wkhtmltopdf ]]; then
  "${RENDERER}" --quiet "${HTML_ABS}" "${PDF_ABS}" > /dev/null 2>&1 || true
else
  "${RENDERER}" --headless --disable-gpu --no-pdf-header-footer \
    --print-to-pdf="${PDF_ABS}" "file://${HTML_ABS}" > /dev/null 2>&1 || true
fi
if [[ -n "${RENDERER}" ]]; then
  if [[ -s "${PDF_ABS}" ]]; then
    print_success "Wrote ${BASE}.pdf"
  else
    print_warning "PDF generation failed; the HTML report is still available"
  fi
fi
