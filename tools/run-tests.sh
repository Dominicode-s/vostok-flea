#!/usr/bin/env bash
# Run the mod's headless test suite.
#
# The tests need the game's classes -- SlotData and ItemData in particular --
# so this assembles the same throwaway project tools/check-gdscript.sh builds:
# mod scripts at their real res:// paths, the game's scripts alongside, and an
# editor import pass so class_name types resolve.
#
# No game launch, no save file at risk.
#
# Usage:  tools/run-tests.sh [test_name]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT_BIN:-D:/Projects/tools/godot/Godot_v4.6.2-stable_win64_console.exe}"
GAME_SCRIPTS="${VOSTOK_DECOMPILED:-D:/Projects/vostok-decompiled}/Scripts"
FILTER="${1:-}"

if [[ ! -f "$GODOT" ]]; then
  echo "Godot binary not found: $GODOT" >&2
  exit 2
fi

if [[ ! -d "$GAME_SCRIPTS" ]]; then
  echo "Game scripts not found: $GAME_SCRIPTS" >&2
  echo "The tests need SlotData and ItemData from the decompiled game." >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/project.godot" <<'PROJECT'
config_version=5

[application]
config/name="fleatests"
config/features=PackedStringArray("4.6")
PROJECT

cp -r "$REPO_ROOT/mods" "$WORK/"
cp -r "$REPO_ROOT/tests" "$WORK/"
mkdir -p "$WORK/Scripts"
cp "$GAME_SCRIPTS"/*.gd "$WORK/Scripts/" 2>/dev/null || true

# Registers every class_name into the project's class cache. Without this,
# SlotData and ItemData are unresolved and every test fails to parse.
"$GODOT" --headless --path "$WORK" --editor --quit >/dev/null 2>&1 || true

failed=0
ran=0
for test_file in "$WORK"/tests/test_*.gd; do
  [[ -e "$test_file" ]] || continue
  name="$(basename "$test_file")"
  if [[ -n "$FILTER" && "$name" != *"$FILTER"* ]]; then
    continue
  fi

  ran=$((ran + 1))
  "$GODOT" --headless --path "$WORK" --script "res://tests/$name" 2>&1 \
    | grep -vE '^Godot Engine|^$'
  status=${PIPESTATUS[0]}
  if [[ $status -ne 0 ]]; then
    failed=$((failed + 1))
  fi
done

echo
if [[ $ran -eq 0 ]]; then
  echo "No tests matched${FILTER:+ filter '$FILTER'}."
  exit 1
fi
if [[ $failed -gt 0 ]]; then
  echo "$failed test file(s) failed."
  exit 1
fi
echo "All $ran test file(s) passed."
