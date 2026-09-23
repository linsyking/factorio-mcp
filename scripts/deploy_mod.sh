#!/usr/bin/env bash
# Package the factorio-mcp mod and install it on a factoriotools/factorio
# Docker server over SSH, then restart the container.
#
# Usage: scripts/deploy_mod.sh SSH_TARGET COMPOSE_DIR [CONTAINER]
#   e.g.  scripts/deploy_mod.sh user@game-host /home/user/factorio factorio
# Clients that join the server need the same mod version installed locally.
# Optional: also publish the zip and a download page to a static web root on
# the same host (e.g. served by Caddy):
#   PUBLISH_DIR=/srv/site/factorio PUBLISH_SERVER_ADDRESS=host:34197 scripts/deploy_mod.sh ...
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -lt 2 ]; then
  echo "usage: $0 SSH_TARGET COMPOSE_DIR [CONTAINER]" >&2
  exit 2
fi
TARGET="$1"
DIR="$2"
CONTAINER="${3:-factorio}"

ZIP="$(uv run -q factorio-mcp package-mod)"
NAME="$(basename "$ZIP")"
echo "packaged $NAME"

ssh -o BatchMode=yes "$TARGET" "cat > /tmp/$NAME" < "$ZIP"
ssh -o BatchMode=yes "$TARGET" bash -s -- "$NAME" "$DIR" "$CONTAINER" <<'REMOTE'
set -euo pipefail
NAME="$1"; DIR="$2"; CONTAINER="$3"
# remove older versions, copy the new zip in as the container's user
docker exec -u 845:845 "$CONTAINER" sh -c 'rm -f /factorio/mods/factorio-mcp_*.zip'
docker exec -i -u 845:845 "$CONTAINER" sh -c "cat > /factorio/mods/$NAME" < "/tmp/$NAME"
rm -f "/tmp/$NAME"
# enable it in mod-list.json
python3 - "$DIR/data/mods/mod-list.json" > /tmp/mod-list.json <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
mods = [m for m in d["mods"] if m["name"] != "factorio-mcp"] + [{"name": "factorio-mcp", "enabled": True}]
json.dump({"mods": mods}, sys.stdout, indent=2)
PY
docker exec -i -u 845:845 "$CONTAINER" sh -c "cat > /factorio/mods/mod-list.json" < /tmp/mod-list.json
rm -f /tmp/mod-list.json
cd "$DIR" && docker compose restart >/dev/null
sleep 8
docker logs --tail 60 "$CONTAINER" 2>&1 | grep -E "Loading mod factorio-mcp|Error|error|Hosting game" | tail -5
REMOTE

if [ -n "${PUBLISH_DIR:-}" ]; then
  ssh -o BatchMode=yes "$TARGET" "mkdir -p '$PUBLISH_DIR' && cat > '$PUBLISH_DIR/$NAME'" < "$ZIP"
  ssh -o BatchMode=yes "$TARGET" "python3 - '$PUBLISH_DIR' ${PUBLISH_SERVER_ADDRESS:+--server '$PUBLISH_SERVER_ADDRESS'}" < scripts/publish_page.py
fi
