# Terminal model

Drop the model in here and it is picked up automatically. No code changes, no
scene edits.

```
mods/FleaMarket/model/
  terminal.obj      required
  terminal.png      optional texture (.jpg / .jpeg also accepted)
```

Then rebuild and deploy:

```powershell
pwsh -File tools\build.ps1
```

The log line `[FleaMarket] terminal mesh: model/terminal.obj` confirms it was
used. `placeholder box (no model supplied)` means it was not found.

Until a model is supplied, the terminal renders as a dark box with a green
emissive glow. It is fully placeable and interactable either way — the art is
the last dependency, not a blocker.

## What the model needs to be

| | |
|---|---|
| **Format** | Wavefront `.obj`, triangles or quads (n-gons are fan-triangulated) |
| **Origin** | At the **base**, centred in X and Z. The mesh runs *upward* from y=0 |
| **Up axis** | +Y |
| **Facing** | The screen should face **−Z**, the direction the player looks from |
| **Size** | About **0.6 m wide × 1.2 m tall × 0.45 m deep** |
| **Scale** | 1 unit = 1 metre |
| **UVs** | Required if you supply a texture; one material/`usemtl` group is simplest |

**Origin at the base is the one that matters.** Vanilla furniture is authored
this way — `Cabinet_Office`'s mesh runs from y=0 upward — and the game's
placement rays fire downward from the bottom face to find the floor. A mesh
centred on its origin sinks half its height through the floor.

Nothing else is rigid. The collision box, the interaction volume and the
placement indicator are all recomputed from the mesh's bounding box at runtime,
so a taller or wider terminal still works; it will just occupy the space it
actually looks like it occupies.

## Fitting the room

Worth checking in the Cabin as well as the Bunker. The Bunker has a canteen
table and stools around `(-3.5, 0, -10)`; the Cabin is a bare shell around the
origin. A kiosk that reads well in one should not dominate the other.

## Why an .obj rather than a .glb or .tscn

A model inside a mounted VMZ has no `.import` sidecar, so Godot will not load
it as a resource — the same wall the physical-money mod hit with its cash
bundle. `TerminalModel.gd` reads the OBJ text at runtime, builds an
`ArrayMesh` with `SurfaceTool`, and saves it to `user://` where the engine
loads it normally. OBJ is used because it is a text format that can be parsed
without the import pipeline.

The parser handles `v`, `vt`, `vn`, `f` and `usemtl`. It ignores `.mtl` files;
materials come from `terminal.png` or, with no texture, a plain dark metal.
