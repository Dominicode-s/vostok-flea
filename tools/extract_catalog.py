"""Extract the real Road to Vostok item table from the decompiled game.

The server ships a placeholder catalog (52 invented entries). Escrowing real
items against invented keys would round-trip a rifle as the wrong thing, so the
server side asked for the actual table. This produces it.

Godot .tres files are plain text, so no engine is needed: parse the
[ext_resource] header into an id -> path map, parse the [resource] body into
fields, then resolve resource-valued fields (compatible, ammo, used) back to
the item_key of whatever they point at.

item_key is ItemData.file, NOT the filename or the resource path. The modding
guide is explicit that resource_path is empty at runtime and `file` is the
identity field the game itself uses.

Usage:
    python tools/extract_catalog.py <decompiled-root> <out-dir>
"""

from __future__ import annotations

import csv
import json
import re
import sys
from pathlib import Path

# Resource script_classes that represent a tradeable-or-not game item. Anything
# else in Items/ is audio, materials or track metadata.
ITEM_CLASSES = {
    "ItemData",
    "WeaponData",
    "AttachmentData",
    "GrenadeData",
    "KnifeData",
    "InstrumentData",
    "FishingData",
    "CasetteData",
    "CatData",
}

HEADER_RE = re.compile(r'^\[gd_resource\b.*?script_class="(?P<cls>[A-Za-z]+)"', re.M)
EXT_RE = re.compile(
    r'^\[ext_resource\s+type="(?P<type>[^"]+)"'
    r'(?:\s+uid="(?P<uid>[^"]+)")?'
    r'\s+path="(?P<path>[^"]+)"'
    r'\s+id="(?P<id>[^"]+)"\]',
    re.M,
)
# Field assignments inside [resource]. Values may be quoted strings, numbers,
# bools, Vector2(...), or an array spanning one line.
FIELD_RE = re.compile(r"^(?P<key>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?P<val>.*)$", re.M)
EXTREF_RE = re.compile(r'ExtResource\("([^"]+)"\)')
VEC2_RE = re.compile(r"Vector2\(\s*([-\d.eE]+)\s*,\s*([-\d.eE]+)\s*\)")


def parse_value(raw: str):
    """Turn a .tres right-hand side into a Python value, best effort."""
    raw = raw.strip()
    if not raw:
        return None
    if raw == "true":
        return True
    if raw == "false":
        return False
    if raw == "null":
        return None
    if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
        return raw[1:-1]
    m = VEC2_RE.fullmatch(raw)
    if m:
        return [float(m.group(1)), float(m.group(2))]
    if EXTREF_RE.search(raw):
        # One or more resource references. Keep the ids; resolved in pass 2.
        return {"__extrefs__": EXTREF_RE.findall(raw)}
    if raw.startswith("[") and raw.endswith("]"):
        # Plain array literal, e.g. slots = ["Primary"]. Only string and
        # numeric members occur on the fields we care about.
        inner = raw[1:-1].strip()
        if not inner:
            return []
        out = []
        for part in inner.split(","):
            out.append(parse_value(part))
        return out
    try:
        return int(raw)
    except ValueError:
        pass
    try:
        return float(raw)
    except ValueError:
        pass
    return raw


def parse_tres(path: Path) -> dict | None:
    text = path.read_text(encoding="utf-8", errors="replace")

    m = HEADER_RE.search(text)
    if not m or m.group("cls") not in ITEM_CLASSES:
        return None

    ext: dict[str, dict] = {}
    for em in EXT_RE.finditer(text):
        ext[em.group("id")] = {
            "path": em.group("path"),
            "uid": em.group("uid"),
            "type": em.group("type"),
        }

    # Only fields after the [resource] marker are the resource's own.
    body_start = text.find("[resource]")
    body = text[body_start:] if body_start != -1 else text

    fields: dict = {}
    for fm in FIELD_RE.finditer(body):
        key = fm.group("key")
        if key in ("script",):
            continue
        fields[key] = parse_value(fm.group("val"))

    return {
        "script_class": m.group("cls"),
        "source_path": path.as_posix(),
        "ext": ext,
        "fields": fields,
    }


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2

    root = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    if not root.is_dir():
        print(f"not a directory: {root}")
        return 2

    # --- Pass 1: parse every item resource in the project ---
    parsed: list[dict] = []
    for tres in sorted(root.rglob("*.tres")):
        # .godot/ holds import caches and re-exported copies; skip them.
        if ".godot" in tres.parts or ".autoconverted" in tres.parts:
            continue
        rec = parse_tres(tres)
        if rec is not None:
            parsed.append(rec)

    # res:// path -> item_key, so resource-valued fields can be resolved.
    by_res_path: dict[str, str] = {}
    for rec in parsed:
        key = rec["fields"].get("file")
        if isinstance(key, str) and key:
            res_path = "res://" + rec["source_path"].split(root.as_posix() + "/", 1)[-1]
            by_res_path[res_path] = key

    def resolve(rec: dict, field: str) -> list[str]:
        """Resolve a resource-valued field to the item_keys it points at."""
        val = rec["fields"].get(field)
        if not isinstance(val, dict) or "__extrefs__" not in val:
            return []
        out = []
        for ref_id in val["__extrefs__"]:
            info = rec["ext"].get(ref_id)
            if not info:
                continue
            k = by_res_path.get(info["path"])
            if k:
                out.append(k)
            else:
                # Points at something that is not an item (audio, mesh) or an
                # item we failed to key. Record it so nothing is silently lost.
                out.append("?" + info["path"])
        return out

    # --- Pass 2: build catalog rows ---
    rows: list[dict] = []
    dupes: dict[str, list[str]] = {}

    for rec in parsed:
        f = rec["fields"]
        key = f.get("file")
        if not isinstance(key, str) or not key:
            continue

        compatible = resolve(rec, "compatible")
        # A weapon's `compatible` array mixes its magazine in with its optics
        # and suppressors. Split them so the server gets a real
        # allowed_attachments list rather than a grab bag.
        attachments = [c for c in compatible if not c.startswith("?")]

        row = {
            "item_key": key,
            "display_name": f.get("display") or f.get("name") or key,
            "internal_name": f.get("name"),
            "script_class": rec["script_class"],
            "class": f.get("type"),
            "subclass": f.get("subtype"),
            "value": f.get("value"),
            "weight": f.get("weight"),
            "size": f.get("size") or [1, 1],
            "rarity": f.get("rarity", 0),
            "stackable": bool(f.get("stackable", False)),
            "max_stack": f.get("maxAmount", 0),
            "default_amount": f.get("defaultAmount", 0),
            "show_amount": bool(f.get("showAmount", False)),
            "has_condition": bool(f.get("showCondition", False)),
            "usable": bool(f.get("usable", False)),
            "repairs": bool(f.get("repairs", False)),
            "capacity": f.get("capacity", 0.0),
            "slots": f.get("slots") if isinstance(f.get("slots"), list) else [],
            "compatible": attachments,
            "ammo": (resolve(rec, "ammo") or [None])[0],
            "caliber": f.get("caliber"),
            "magazine_size": f.get("magazineSize"),
            "weapon_type": f.get("weaponType"),
            "weapon_action": f.get("weaponAction"),
            "plate": bool(f.get("plate", False)),
            "carrier": bool(f.get("carrier", False)),
            "helmet": bool(f.get("helmet", False)),
            "protection": f.get("protection", 0),
            "armor_rating": f.get("rating"),
            "loot_civilian": bool(f.get("civilian", False)),
            "loot_industrial": bool(f.get("industrial", False)),
            "loot_military": bool(f.get("military", False)),
            "source_path": rec["source_path"],
        }

        # bulk: the server wants "any consistent scalar" feeding delivery ETA.
        # Grid footprint times weight captures both senses of bulk better than
        # either alone -- a feather-light 6x2 rifle is still awkward cargo.
        w, h = (row["size"] + [1, 1])[:2]
        cells = max(1.0, float(w) * float(h))
        weight = float(row["weight"] or 0.0)
        row["grid_cells"] = cells
        row["bulk"] = round(cells * max(weight, 0.05), 3)

        rows.append(row)
        dupes.setdefault(key, []).append(rec["source_path"])

    rows.sort(key=lambda r: (str(r["class"] or ""), str(r["item_key"])))

    collisions = {k: v for k, v in dupes.items() if len(v) > 1}

    # --- Write outputs ---
    payload = {
        "generated_from": root.as_posix(),
        "item_count": len(rows),
        "key_collisions": collisions,
        "classes": sorted({str(r["class"]) for r in rows}),
        "items": rows,
    }
    (out_dir / "catalog.json").write_text(
        json.dumps(payload, indent=2), encoding="utf-8"
    )

    csv_cols = [
        "item_key", "display_name", "class", "subclass", "stackable",
        "max_stack", "has_condition", "bulk", "weight", "grid_cells",
        "value", "rarity", "compatible", "ammo", "caliber", "magazine_size",
        "armor_rating", "protection", "capacity", "script_class",
    ]
    with (out_dir / "catalog.csv").open("w", newline="", encoding="utf-8") as fh:
        wr = csv.DictWriter(fh, fieldnames=csv_cols, extrasaction="ignore")
        wr.writeheader()
        for r in rows:
            out = dict(r)
            out["compatible"] = "|".join(r["compatible"])
            wr.writerow(out)

    print(f"parsed {len(parsed)} item resources -> {len(rows)} keyed items")
    print(f"classes: {', '.join(payload['classes'])}")
    if collisions:
        print(f"WARNING {len(collisions)} duplicate item_key(s):")
        for k, paths in collisions.items():
            print(f"  {k}")
            for p in paths:
                print(f"    {p}")
    print(f"wrote {out_dir / 'catalog.json'}")
    print(f"wrote {out_dir / 'catalog.csv'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
