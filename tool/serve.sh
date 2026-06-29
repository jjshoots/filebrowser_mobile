#!/usr/bin/env bash
# Quantum test-server harness for the integration tests.
#
# Downloads the official filebrowser-quantum release (if absent), writes a
# config, seeds a small data tree, and runs the server on :8080. All generated
# artifacts live under the gitignored ./.quantum-test/ dir, so the working tree
# stays clean.
#
# Usage:
#   ./tool/serve.sh setup   # idempotent: fetch binary + write config + seed data
#   ./tool/serve.sh run     # setup, then exec the server in the foreground
#
# Server: http://0.0.0.0:8080 (emulator: http://10.0.2.2:8080).
# Admin creds: admin / admin12345 ; source name: files ; data: ./.quantum-test/fbdata
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$HERE/.quantum-test"
BIN="$WORK/fb-official"
CFG="$WORK/config.yaml"
DATA="$WORK/fbdata"
PORT="${FB_TEST_PORT:-8080}"
REL="v1.4.0-stable"
URL="https://github.com/gtsteffaniak/filebrowser/releases/download/$REL/linux-amd64-filebrowser"

setup() {
  mkdir -p "$WORK"
  if [ ! -x "$BIN" ]; then
    echo "downloading official quantum $REL ..."
    curl -sSL --max-time 300 -o "$BIN" "$URL"
    chmod +x "$BIN"
  fi
  if [ ! -f "$CFG" ]; then
    cat > "$CFG" <<EOF
server:
  port: $PORT
  baseURL: "/"
  sources:
    - path: "$DATA"
      name: "files"
auth:
  adminUsername: "admin"
  adminPassword: "admin12345"
  methods:
    password:
      enabled: true
      minLength: 5
      signup: false
userDefaults:
  account:
    permissions:
      admin: true
      modify: true
      share: true
      delete: true
      create: true
      download: true
EOF
  fi
  if [ ! -d "$DATA" ]; then
    mkdir -p "$DATA/Photos" "$DATA/Documents/Reports" "$DATA/Music"
    printf 'Hello from quantum migration test.\n' > "$DATA/readme.txt"
    printf 'alpha\n'          > "$DATA/Documents/alpha.txt"
    printf 'beta beta beta\n' > "$DATA/Documents/beta.md"
    printf 'Q3 financials\n'  > "$DATA/Documents/Reports/q3-report.txt"
    for n in 1 2 10; do printf 'img placeholder %s\n' "$n" > "$DATA/Photos/img$n.txt"; done
    # tiny 1x1 red PNG so image listing/preview has a real image
    python3 - "$DATA/Photos/red.png" <<'PY' 2>/dev/null || true
import sys,base64
open(sys.argv[1],'wb').write(base64.b64decode(
 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='))
PY
  fi
  echo "setup ok: bin=$BIN cfg=$CFG data=$DATA"
}

case "${1:-run}" in
  setup) setup ;;
  run)   setup; echo "starting quantum on :$PORT"; exec "$BIN" -c "$CFG" ;;
  *)     echo "usage: $0 {setup|run}" >&2; exit 2 ;;
esac
