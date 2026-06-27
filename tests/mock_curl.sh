#!/bin/sh
# =============================================================================
# mock_curl.sh
#
# Universal drop-in curl mock for bats tests. Copy into a directory that is
# prepended to PATH; the real curl is then shadowed for the duration of a test.
#
# Response data is read from environment variables so callers never embed
# special characters in the script body:
#
#   MOCK_CURL_CODE   HTTP status code to return  (default: 200)
#   MOCK_CURL_BODY   Response body               (default: empty)
#   MOCK_CURL_LINK   Full URL for Link: next header — set to make the
#                    response look like a paginated "non-last" page;
#                    leave empty (default) to signal the final page
#
# Handles two calling conventions used in lib/github-common.sh:
#
#   stdout mode    (gh_api, get_repo_page_count)
#     curl ... (no -o flag)
#     Output: <body>\n<code>  — gh_api splits on the last line
#
#   file mode      (gh_api_paginate, validate_token)
#     curl ... -o <body-file> [-D <headers-file>]
#     Output: <code>  (body written to -o file; headers written to -D file)
# =============================================================================

HFILE=""
BFILE=""

# Parse only the flags we care about; everything else is ignored
while [ $# -gt 0 ]; do
  case "$1" in
    -D) HFILE="$2"; shift 2 ;;
    -o) BFILE="$2"; shift 2 ;;
    *)  shift ;;
  esac
done

CODE="${MOCK_CURL_CODE:-200}"

if [ -n "$BFILE" ]; then
  # File mode: write body to -o target, write headers to -D target (if set)
  printf '%s' "${MOCK_CURL_BODY:-}" > "$BFILE"
  if [ -n "$HFILE" ]; then
    printf 'HTTP/1.1 %s\r\n' "$CODE" > "$HFILE"
    [ -n "${MOCK_CURL_LINK:-}" ] && \
      printf 'link: <%s>; rel="next"\r\n' "${MOCK_CURL_LINK:-}" >> "$HFILE"
    printf '\r\n' >> "$HFILE"
  fi
  printf '%s' "$CODE"
else
  # Stdout mode: body on first line(s), status code on last line
  printf '%s\n%s' "${MOCK_CURL_BODY:-}" "$CODE"
fi
