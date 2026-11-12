#!/usr/bin/env bash
# =============================================================================
# screenshot-html.sh
#
# Renders an HTML report to full-page PNG screenshots at screen width (1280px)
# and US Letter print width (816px), for checking report layout visually.
#
# Usage:
#   ./tools/screenshot-html.sh <report.html> [output-dir]
#
# Output:
#   <output-dir>/<name>-screen.png and <output-dir>/<name>-print.png
#   (output-dir defaults to a new temporary directory, printed on success)
#
# Requirements:
#   - node and npx
#   - Playwright Chromium: npx playwright install chromium
# =============================================================================

set -euo pipefail

if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  sed -n '9,10p' "$0" | sed 's/^# *//'
  [[ $# -lt 1 ]] && exit 1 || exit 0
fi

html="$1"
[[ -f "${html}" ]] || { echo "No such file: ${html}" >&2; exit 1; }
out_dir="${2:-$(mktemp -d)}"
mkdir -p "${out_dir}"

url="file://$(cd "$(dirname "${html}")" && pwd)/$(basename "${html}")"
name="$(basename "${html}" .html)"

for target in screen:1280 print:816; do
  npx --yes playwright screenshot --full-page --viewport-size="${target#*:},900" \
    "${url}" "${out_dir}/${name}-${target%%:*}.png" >/dev/null
done

echo "${out_dir}/${name}-screen.png"
echo "${out_dir}/${name}-print.png"
