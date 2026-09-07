#!/usr/bin/env bash
# Parse-check every GDScript in this repo without launching the game.
#
# Why this exists: a GDScript parse error takes the WHOLE autoload down, and the
# mod loader reports it as "Autoload script failed to compile" with the mod
# silently absent. Finding that out costs a full game launch each time. This
# finds it in about two seconds.
#
# It uses a real Godot 4.6.2-stable binary -- the same version and build hash
# the game runs (71f334935), so it is the same parser, not an approximation.
#
# Godot's --check-only exits 0 even when it reports a parse error, so the exit
# status is derived from the output rather than trusted.
#
# Usage:  tools/check-gdscript.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT_BIN:-D:/Projects/tools/godot/Godot_v4.6.2-stable_win64_console.exe}"

if [[ ! -f "$GODOT" ]]; then
  echo "Godot binary not found: $GODOT" >&2
  echo "Set GODOT_BIN, or download Godot 4.6.2-stable to that path." >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A bare project so res:// resolves the same way it does once the VMZ is
# mounted. Mod scripts preload each other by absolute res:// path, so the
# directory layout has to match the archive layout exactly.
cat > "$WORK/project.godot" <<'PROJECT'
config_version=5

[application]
config/name="fleacheck"
config/features=PackedStringArray("4.6")
PROJECT

for tree in mods spike/mods; do
  if [[ -d "$REPO_ROOT/$tree" ]]; then
    mkdir -p "$WORK/$(dirname "$tree")"
    cp -r "$REPO_ROOT/$tree" "$WORK/$(dirname "$tree")/"
  fi
done

mapfile -t SCRIPTS < <(cd "$WORK" && find . -name '*.gd' | sed 's|^\./||' | sort)

if [[ ${#SCRIPTS[@]} -eq 0 ]]; then
  echo "No .gd files found."
  exit 0
fi

failed=0
for rel in "${SCRIPTS[@]}"; do
  output="$("$GODOT" --headless --path "$WORK" --check-only \
    --script "res://$rel" 2>&1 | grep -v '^Godot Engine' || true)"

  if echo "$output" | grep -qE 'Parse Error|SCRIPT ERROR|Failed to load script'; then
    echo "FAIL  $rel"
    echo "$output" | sed 's/^/      /'
    failed=$((failed + 1))
  else
    echo "ok    $rel"
  fi
done

echo
if [[ $failed -gt 0 ]]; then
  echo "$failed script(s) failed to parse."
  exit 1
fi
echo "All ${#SCRIPTS[@]} script(s) parsed cleanly."
