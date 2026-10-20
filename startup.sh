#!/usr/bin/env bash
# Once-per-worker prerequisites for start.sh and capture.sh.
set -euo pipefail

t() { /usr/bin/time -p "$@"; }

t python3 -V
t curl --version
if ! command -v chromium >/dev/null 2>&1 \
  && ! command -v chromium-browser >/dev/null 2>&1 \
  && ! command -v google-chrome >/dev/null 2>&1; then
  echo "startup.sh: no chromium/chrome binary found (required by capture.sh)" >&2
  exit 1
fi
t mkdir -p "${OPENCODE_WEB_DIR:-/home/runner/work/_temp/omgithub-web}"
echo "startup.sh: prerequisites OK"
