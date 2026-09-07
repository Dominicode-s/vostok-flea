#!/usr/bin/env bash
# Parse-check this repo's GDScript without launching the game.
#
# Why this exists: a GDScript parse error takes the WHOLE autoload down, and the
# mod loader reports it as "Autoload script failed to compile" with the mod
# silently absent. Finding that out costs a full game launch each time. This
# finds it in a few seconds.
#
# It uses a real Godot 4.6.2-stable binary -- the same version and build hash
# the game runs (71f334935), so it is the same parser, not an approximation.
#
# Two details make the difference between a useful checker and a misleading one:
#
#   * The game's own scripts are copied in, so `class_name` types the mod uses
#     (ItemData, SlotData, LootContainer, Furniture) resolve.
#   * An editor import pass runs first to build
#     .godot/global_script_class_cache.cfg. Without it those class names are
#     still unresolved even though the files are present, and the checker
#     reports errors on code that is perfectly valid at runtime -- which is
#     worse than no checker, because it trains you to ignore the output.
#
# Only this repo's scripts are checked. The game's scripts are context, not
# subjects: they are decompiler output and some do not round-trip cleanly.
#
# Godot's --check-only exits 0 even when it reports a parse error, so the exit
# status is derived from the output rather than trusted.
#
# Usage:  tools/check-gdscript.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT_BIN:-D:/Projects/tools/godot/Godot_v4.6.2-stable_win64_console.exe}"
GAME_SCRIPTS="${VOSTOK_DECOMPILED:-D:/Projects/vostok-decompiled}/Scripts"

if [[ ! -f "$GODOT" ]]; then
  echo "Godot binary not found: $GODOT" >&2
  echo "Set GODOT_BIN, or download Godot 4.6.2-stable to that path." >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/project.godot" <<'PROJECT'
config_version=5

[application]
config/name="fleacheck"
config/features=PackedStringArray("4.6")
PROJECT

# Mod scripts, laid out exactly as they are inside the mounted VMZ so the
# res:// paths in preload() resolve identically.
SUBJECTS=()
for tree in mods spike/mods; do
  if [[ -d "$REPO_ROOT/$tree" ]]; then
    mkdir -p "$WORK/$(dirname "$tree")"
    cp -r "$REPO_ROOT/$tree" "$WORK/$(dirname "$tree")/"
    while IFS= read -r f; do
      SUBJECTS+=("${f#"$WORK/"}")
    done < <(find "$WORK/$tree" -name '*.gd' | sort)
  fi
done

if [[ ${#SUBJECTS[@]} -eq 0 ]]; then
  echo "No .gd files found in this repo."
  exit 0
fi

if [[ -d "$GAME_SCRIPTS" ]]; then
  mkdir -p "$WORK/Scripts"
  cp "$GAME_SCRIPTS"/*.gd "$WORK/Scripts/" 2>/dev/null || true
else
  echo "warning: game scripts not found at $GAME_SCRIPTS" >&2
  echo "         class_name types from the game will report as unresolved." >&2
fi

# Import pass: registers every class_name into the project's class cache.
"$GODOT" --headless --path "$WORK" --editor --quit >/dev/null 2>&1 || true

if [[ ! -f "$WORK/.godot/global_script_class_cache.cfg" ]]; then
  echo "warning: class cache was not generated; results may be unreliable." >&2
fi

failed=0
for rel in "${SUBJECTS[@]}"; do
  output="$("$GODOT" --headless --path "$WORK" --check-only \
    --script "res://$rel" 2>&1 | grep -vE '^Godot Engine|^$' || true)"

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
echo "All ${#SUBJECTS[@]} script(s) parsed cleanly."
