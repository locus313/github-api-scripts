#!/bin/sh
# =============================================================================
# mock_curl_permissions.sh
#
# Purpose-built curl mock for github-add-repo-permissions tests. Unlike the
# universal mock_curl.sh, this variant returns endpoint-specific responses so
# the full repo-processing flow can be exercised:
#
#   HEAD request (-I)          page-count probe -> single page (no next header)
#   GET .../user (-o target)   token validation -> HTTP 200
#   PUT team permissions       -> HTTP 204
#   GET .../repos              repo list -> JSON array from MOCK_REPOS_JSON
#
# MOCK_REPOS_JSON overrides the repo list body (default: two repos).
# =============================================================================

is_put=0
is_head=0
ofile=""
prev=""
for arg in "$@"; do
  case "${arg}" in
    PUT) is_put=1 ;;
    -I)  is_head=1 ;;
  esac
  [ "${prev}" = "-o" ] && ofile="${arg}"
  prev="${arg}"
done

if [ "${is_put}" = 1 ]; then
  printf '204'
  exit 0
fi

if [ "${is_head}" = 1 ]; then
  printf 'HTTP/1.1 200\r\n'
  exit 0
fi

if [ -n "${ofile}" ]; then
  : > "${ofile}"
  printf '200'
  exit 0
fi

DEFAULT_REPOS='[{"name":"repo-keep"},{"name":"repo-skip"}]'
printf '%s' "${MOCK_REPOS_JSON:-${DEFAULT_REPOS}}"
