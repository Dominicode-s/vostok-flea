#!/usr/bin/env bash
# Validate every ItemBridge descriptor against the SERVER'S OWN validator.
#
# Phase 1 (POST /v1/listings) records a descriptor and moves nothing: no
# escrow, no fee, no ledger posting, and the item is still in the player's
# inventory when it returns. But it fully validates the descriptor against the
# catalog. So this exercises the real validator against every tradeable item in
# the game without ever putting one at risk -- and confirm is never called, so
# the phase-1 records simply lapse.
#
# This is the loop that turns ItemBridge from guesswork into something checked
# against the authority. tools/run-tests.sh proves the client is
# self-consistent; only this proves it agrees with the server.
#
# Descriptors are built by ItemBridge itself, never reimplemented here. A
# harness that rebuilt the descriptor would only validate the harness.
#
# Usage:
#   tools/validate-descriptors.sh [--limit N] [--key-name dev_seller]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT_BIN:-D:/Projects/tools/godot/Godot_v4.6.2-stable_win64_console.exe}"
GAME_SCRIPTS="${VOSTOK_DECOMPILED:-D:/Projects/vostok-decompiled}/Scripts"
API="${FLEA_API:-https://api.domfragsvostokmods.bid/v1}"
KEYS_FILE="${FLEA_KEYS:-$REPO_ROOT/.dev-keys.json}"

LIMIT=0
KEY_NAME="dev_seller"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    --key-name) KEY_NAME="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$KEYS_FILE" ]]; then
  echo "No dev keys at $KEYS_FILE" >&2
  exit 2
fi
KEY="$(python -c "import json,sys;print(json.load(open(sys.argv[1]))['$KEY_NAME'])" "$KEYS_FILE")"

CATALOG="$REPO_ROOT/docs/catalog/catalog.json"
[[ -f "$CATALOG" ]] || { echo "Missing $CATALOG -- run tools/extract_catalog.py" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/project.godot" <<'PROJECT'
config_version=5

[application]
config/name="fleavalidate"
config/features=PackedStringArray("4.6")
PROJECT

cp -r "$REPO_ROOT/mods" "$WORK/"
cp -r "$REPO_ROOT/tests" "$WORK/"
mkdir -p "$WORK/Scripts"
cp "$GAME_SCRIPTS"/*.gd "$WORK/Scripts/" 2>/dev/null || true
"$GODOT" --headless --path "$WORK" --editor --quit >/dev/null 2>&1 || true

echo "Building descriptors with ItemBridge..."
"$GODOT" --headless --path "$WORK" --script res://tests/dump_descriptors.gd \
  -- "$CATALOG" "$WORK/descriptors.json" 2>&1 \
  | grep -vE '^Godot Engine|^$|leaked at exit|resources still in use|^   at:' || true

[[ -s "$WORK/descriptors.json" ]] || { echo "No descriptors produced." >&2; exit 1; }

echo "Validating against $API ..."
echo

API="$API" KEY="$KEY" LIMIT="$LIMIT" WORK="$WORK" \
  python "$REPO_ROOT/tools/_post_descriptors.py" "$WORK/descriptors.json"
PYSTATUS=$?

echo
if [[ $PYSTATUS -eq 0 ]]; then
  echo "Every descriptor the client sent was accepted by the server."
else
  echo "Validation did not come back clean -- see above."
fi
exit $PYSTATUS
