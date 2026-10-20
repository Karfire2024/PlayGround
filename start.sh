#!/usr/bin/env bash
# Build the static travel-dossier site into ./dist and serve it in the
# foreground on PORT (default 3000). Writes deployment metadata to
# $OPENCODE_WEB_DIR/deployment-output.json. All source and build output
# stays inside PROJECT_DIR; OPENCODE_WEB_DIR is metadata only.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

WEB_DIR="${OPENCODE_WEB_DIR:-/home/runner/work/_temp/omgithub-web}"
PORT="${PORT:-3000}"
SRC_DIR="$PROJECT_DIR/travel-dossier"
DIST_DIR="$PROJECT_DIR/dist"

t() { /usr/bin/time -p "$@"; }

echo "[start.sh] $(date -Is) project=$PROJECT_DIR port=$PORT web_dir=$WEB_DIR"

# --- prerequisites -----------------------------------------------------------
t python3 -V

# --- install dependencies (none required for this static site) ---------------
if [[ -f package.json ]]; then
  if [[ -f package-lock.json && -d node_modules ]]; then
    t npm ci --no-audit --no-fund
  else
    t npm install --no-audit --no-fund
  fi
fi

# --- build: fresh copy of the site into dist/ (index.html at root) -----------
t rm -rf "$DIST_DIR"
t mkdir -p "$DIST_DIR"
if [[ -d "$SRC_DIR" ]]; then
  t cp -a "$SRC_DIR/." "$DIST_DIR/"
elif [[ -f index.html ]]; then
  t cp -a index.html "$DIST_DIR/index.html"
fi
if [[ ! -f "$DIST_DIR/index.html" ]]; then
  echo "[start.sh] build failed: $DIST_DIR/index.html missing" >&2
  exit 1
fi
echo "[start.sh] built $DIST_DIR"

# --- deployment metadata (worker metadata only, outside the project) ---------
t mkdir -p "$WEB_DIR"
printf '{"project":"%s","directory":"%s"}\n' "$PROJECT_DIR" "$DIST_DIR" > "$WEB_DIR/deployment-output.json"
echo "[start.sh] wrote $WEB_DIR/deployment-output.json"

# --- serve in the foreground -------------------------------------------------
echo "[start.sh] serving $DIST_DIR on 0.0.0.0:$PORT"
exec /usr/bin/time -p python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$DIST_DIR"
