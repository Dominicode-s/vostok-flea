extends RefCounted

# No class_name on purpose: a global class registered from inside a mod archive
# collides across mods and survives reloads badly. Callers preload it.

## Builds the mod's physical fixtures -- the terminal and the courier crate --
## and makes their 3D models drop-in.
##
## Both are placeable furniture, so they need the same four generated pieces:
## an ItemData, an inventory icon, an inventory sprite, and a mesh. Rather than
## two near-identical files, each fixture is a spec and the pipeline is shared.
##
## ## Why any of this is generated at runtime
##
## A .png or a model inside a mounted VMZ has no .import sidecar, so Godot will
## not load it as a resource. The physical-money mod hit the same wall with its
## cash bundle and solved it the same way: read the file, build the resource in
## code, and hand it to ResourceSaver so the rest of the engine can load it
## normally.
##
## ## Why they live in a subdirectory
##
## The game's Loader.FormatSave() deletes every *.tres at the TOP LEVEL of
## user:// when a save is reset, sparing only Validator.tres and
## Preferences.tres. It lists the directory non-recursively, so anything one
## level down survives. Every mod that generates resources is exposed to this --
## the same sweep takes XP Skills' skillbooks and the money mod's item data.

const ASSET_DIR := "user://FleaMarket"
const MODEL_DIR := "res://mods/FleaMarket/model"

## The terminal: a floor-standing kiosk you trade at.
const TERMINAL := {
	"key": "FleaTerminal",
	"asset": "Terminal",
	"display_name": "Flea Market Terminal",
	"scene_path": "res://mods/FleaMarket/FleaTerminal_F.tscn",
	"model": "terminal",
	"mesh_size": Vector3(0.6, 1.2, 0.45),
	"grid_size": Vector2(2, 2),
	"weight": 8.0,
	"tint": Color(0.11, 0.13, 0.12),
	"glow": Color(0.24, 0.92, 0.45),
}

## The courier crate: where bought goods and sale proceeds arrive, and the only
## place they ever do.
const CRATE := {
	"key": "CourierCrate",
	"asset": "Crate",
	"display_name": "Courier Crate",
	"scene_path": "res://mods/FleaMarket/CourierCrate_F.tscn",
	"model": "crate",
	"mesh_size": Vector3(0.9, 0.6, 0.6),
	"grid_size": Vector2(2, 2),
	"weight": 12.0,
	"tint": Color(0.22, 0.17, 0.11),
	"glow": Color(0.62, 0.45, 0.20),
}

const ALL := [TERMINAL, CRATE]

const ICON_PX := 128


# --- Paths ---

static func item_path(spec: Dictionary) -> String:
	return "%s/%sItem.tres" % [ASSET_DIR, spec["asset"]]


static func icon_path(spec: Dictionary) -> String:
	return "%s/%sIcon.tres" % [ASSET_DIR, spec["asset"]]


static func tetris_path(spec: Dictionary) -> String:
	return "%s/%sTetris.tscn" % [ASSET_DIR, spec["asset"]]


static func mesh_path(spec: Dictionary) -> String:
	return "%s/%sMesh.res" % [ASSET_DIR, spec["asset"]]


static func obj_path(spec: Dictionary) -> String:
	return "%s/%s.obj" % [MODEL_DIR, spec["model"]]


# --- Build ---

## Build every generated asset for one fixture. Returns true when its ItemData
## is on disk, which is the precondition for the placed scene resolving.
static func build(spec: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(ASSET_DIR)

	var used_model := _build_mesh(spec)
	print("[FleaMarket] %s mesh: %s" % [spec["key"],
		("model/%s.obj" % spec["model"]) if used_model
		else "placeholder (no model supplied)"])

	var icon := _build_icon(spec)
	if ResourceSaver.save(icon, icon_path(spec)) != OK:
		push_error("FleaMarket: could not save %s icon" % spec["key"])
		return false
	# CACHE_MODE_REPLACE so a rebuilt asset is picked up rather than serving
	# the copy cached from a previous launch.
	ResourceLoader.load(icon_path(spec), "", ResourceLoader.CACHE_MODE_REPLACE)

	var f := FileAccess.open(tetris_path(spec), FileAccess.WRITE)
	if f == null:
		push_error("FleaMarket: could not write %s inventory sprite" % spec["key"])
		return false
	f.store_string(_tetris_text(spec))
	f.close()
	var tetris = ResourceLoader.load(tetris_path(spec), "", ResourceLoader.CACHE_MODE_REPLACE)

	var item := ItemData.new()
	item.file = spec["key"]
	item.name = spec["display_name"]
	item.inventory = spec["display_name"]
	item.rotated = spec["display_name"]
	item.equipment = spec["display_name"]
	item.display = spec["display_name"]
	# Vanilla branches on this exact string when the player takes the item and
	# routes "Furniture" to the catalog grid rather than the inventory grid.
	# Getting it wrong makes the fixture unplaceable.
	item.type = "Furniture"
	item.value = 0
	# Rarity.Null keeps it out of every loot bucket: these are granted, not found.
	item.rarity = ItemData.Rarity.Null
	item.weight = spec["weight"]
	item.size = spec["grid_size"]
	item.icon = ResourceLoader.load(icon_path(spec))
	item.tetris = tetris
	item.stackable = false
	item.showCondition = false
	item.showAmount = false

	if ResourceSaver.save(item, item_path(spec)) != OK:
		push_error("FleaMarket: could not save %s ItemData" % spec["key"])
		return false
	ResourceLoader.load(item_path(spec), "", ResourceLoader.CACHE_MODE_REPLACE)
	return true


static func load_item(spec: Dictionary) -> ItemData:
	var res = ResourceLoader.load(item_path(spec))
	return res as ItemData


# --- Mesh ---

static func _build_mesh(spec: Dictionary) -> bool:
	var mesh: ArrayMesh = null
	var used_model := false

	var path := obj_path(spec)
	if FileAccess.file_exists(path):
		mesh = _parse_obj(path)
		if mesh != null and mesh.get_surface_count() > 0:
			_apply_model_material(spec, mesh)
			used_model = true
		else:
			push_warning("FleaMarket: %s.obj produced no geometry" % spec["model"])
			mesh = null

	if mesh == null:
		mesh = _placeholder_mesh(spec)

	ResourceSaver.save(mesh, mesh_path(spec))
	ResourceLoader.load(mesh_path(spec), "", ResourceLoader.CACHE_MODE_REPLACE)
	return used_model


static func _placeholder_mesh(spec: Dictionary) -> ArrayMesh:
	var size: Vector3 = spec["mesh_size"]
	var box := BoxMesh.new()
	box.size = size

	var mat := StandardMaterial3D.new()
	mat.albedo_color = spec["tint"]
	mat.metallic = 0.3
	mat.roughness = 0.6
	mat.emission_enabled = true
	mat.emission = spec["glow"]
	mat.emission_energy_multiplier = 0.4

	# Offset so the box sits ON the origin rather than straddling it. Vanilla
	# furniture has its origin at the base, and the placement rays fire down
	# from the bottom face; a centred mesh sinks half its height through the
	# floor.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(box, 0, Transform3D(Basis(), Vector3(0, size.y * 0.5, 0)))
	st.generate_normals()
	st.generate_tangents()

	var mesh := st.commit()
	mesh.surface_set_material(0, mat)
	return mesh


static func _apply_model_material(spec: Dictionary, mesh: ArrayMesh) -> void:
	var mat := StandardMaterial3D.new()
	mat.roughness = 0.6
	mat.metallic = 0.2
	mat.albedo_color = Color(1, 1, 1)

	var texture := _load_texture(spec)
	if texture != null:
		mat.albedo_texture = texture
	else:
		mat.albedo_color = spec["tint"]

	for surface in range(mesh.get_surface_count()):
		mesh.surface_set_material(surface, mat)


static func _load_texture(spec: Dictionary) -> ImageTexture:
	for suffix in [".png", ".jpg", ".jpeg"]:
		# Explicitly typed: the loop variable comes from an untyped Array, so it
		# is a Variant and := would have nothing to infer from.
		var ext: String = str(suffix)
		var path: String = "%s/%s%s" % [MODEL_DIR, spec["model"], ext]
		if not FileAccess.file_exists(path):
			continue
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.is_empty():
			continue
		var img := Image.new()
		var err := ERR_FILE_UNRECOGNIZED
		if ext == ".png":
			err = img.load_png_from_buffer(bytes)
		else:
			err = img.load_jpg_from_buffer(bytes)
		if err != OK:
			continue
		img.generate_mipmaps()
		return ImageTexture.create_from_image(img)
	return null


## Minimal OBJ reader: vertices, UVs, normals and triangulated faces, split into
## one surface per `usemtl` group. Enough for a prop; it is not a general
## importer and ignores .mtl files, since materials are applied above.
static func _parse_obj(path: String) -> ArrayMesh:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null

	var vertices: Array = []
	var uvs: Array = []
	var normals: Array = []
	var surfaces: Array = [[]]
	var current := 0

	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.begins_with("v "):
			var p := line.split(" ", false)
			if p.size() >= 4:
				vertices.append(Vector3(float(p[1]), float(p[2]), float(p[3])))
		elif line.begins_with("vt "):
			var p := line.split(" ", false)
			if p.size() >= 3:
				# OBJ's V axis runs opposite to Godot's.
				uvs.append(Vector2(float(p[1]), 1.0 - float(p[2])))
		elif line.begins_with("vn "):
			var p := line.split(" ", false)
			if p.size() >= 4:
				normals.append(Vector3(float(p[1]), float(p[2]), float(p[3])))
		elif line.begins_with("usemtl "):
			if surfaces[current].size() > 0:
				surfaces.append([])
				current += 1
		elif line.begins_with("f "):
			var parts := line.split(" ", false)
			# Fan-triangulate any n-gon.
			for i in range(3, parts.size()):
				for idx in [1, i, i - 1]:
					surfaces[current].append(parts[idx])
	file.close()

	if vertices.is_empty():
		return null

	var mesh := ArrayMesh.new()
	for surface in surfaces:
		if surface.is_empty():
			continue
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for face in surface:
			var c := str(face).split("/")
			var vi := int(c[0]) - 1
			if vi < 0 or vi >= vertices.size():
				continue
			if c.size() > 2 and c[2] != "":
				var ni := int(c[2]) - 1
				if ni >= 0 and ni < normals.size():
					st.set_normal(normals[ni])
			if c.size() > 1 and c[1] != "":
				var ti := int(c[1]) - 1
				if ti >= 0 and ti < uvs.size():
					st.set_uv(uvs[ti])
			st.add_vertex(vertices[vi])
		if normals.is_empty():
			st.generate_normals()
		st.generate_tangents()
		mesh = st.commit(mesh)

	return mesh


# --- Icons ---

static func _build_icon(spec: Dictionary) -> ImageTexture:
	var img := Image.create(ICON_PX, ICON_PX, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	var casing: Color = spec["tint"]
	var bezel := casing.darkened(0.4)
	var glow: Color = spec["glow"]

	if spec["key"] == TERMINAL["key"]:
		# A screen with scanlines and a keypad, so it reads as a machine.
		_rect(img, 8, 6, ICON_PX - 16, ICON_PX - 12, casing)
		_rect(img, 14, 12, ICON_PX - 28, 68, bezel)
		_rect(img, 18, 16, ICON_PX - 36, 60, glow.darkened(0.55))
		for y in range(20, 72, 6):
			_rect(img, 22, y, ICON_PX - 44, 2, glow)
		for row in range(2):
			for col in range(3):
				_rect(img, 26 + col * 28, 90 + row * 16, 20, 10, bezel)
	else:
		# A crate: planks, banding and a stencil stripe.
		_rect(img, 6, 22, ICON_PX - 12, ICON_PX - 46, casing)
		for x in range(12, ICON_PX - 12, 22):
			_rect(img, x, 26, 3, ICON_PX - 54, bezel)
		_rect(img, 6, 34, ICON_PX - 12, 6, bezel)
		_rect(img, 6, ICON_PX - 34, ICON_PX - 12, 6, bezel)
		_rect(img, 28, 62, ICON_PX - 56, 10, glow)

	return ImageTexture.create_from_image(img)


static func _rect(img: Image, x: int, y: int, w: int, h: int, c: Color) -> void:
	for py in range(maxi(0, y), mini(y + h, img.get_height())):
		for px in range(maxi(0, x), mini(x + w, img.get_width())):
			img.set_pixel(px, py, c)


## The inventory-grid sprite. Vanilla items centre the sprite at 32px per grid
## cell and halve its scale, so a 2x2 item sits at (64, 64).
static func _tetris_text(spec: Dictionary) -> String:
	var centre: Vector2 = spec["grid_size"] * 32.0
	return """[gd_scene format=3]

[ext_resource type="Material" path="res://UI/Effects/MT_Item.tres" id="1"]
[ext_resource type="Texture2D" path="%s" id="2"]

[node name="%s" type="Sprite2D"]
material = ExtResource("1")
position = Vector2(%d, %d)
scale = Vector2(0.5, 0.5)
texture = ExtResource("2")
""" % [icon_path(spec), spec["key"], int(centre.x), int(centre.y)]
