extends RefCounted

# No class_name on purpose: a global class registered from inside a mod archive
# collides across mods and survives reloads badly. Callers preload it.

## Builds the terminal's 3D mesh, and makes the real model a drop-in.
##
## Drop `model/terminal.obj` (plus an optional `model/terminal.png` or `.jpg`)
## into this mod folder and it is used automatically. With no model present, a
## placeholder box is generated so the terminal is always placeable and
## interactable -- art is the last dependency, not a blocker for the rest.
##
## Why parse the OBJ instead of shipping a .mesh: a model inside a mounted VMZ
## has no .import sidecar, so Godot will not load it as a resource. The
## physical-money mod hit the same wall and solved it the same way -- read the
## file, build an ArrayMesh with SurfaceTool, and hand the result to
## ResourceSaver so the rest of the engine can load it normally.

const MESH_PATH := "user://FleaMarket_TerminalMesh.res"
const MODEL_DIR := "res://mods/FleaMarket/model"
const OBJ_PATH := MODEL_DIR + "/terminal.obj"

## Placeholder dimensions, and the envelope a real model should fit.
## Roughly a floor-standing kiosk: waist-high, shallow, a little wider than
## deep. Origin at the BASE, matching vanilla furniture -- Cabinet_Office's
## mesh runs upward from y=0, and the placement rays fire down from the
## bottom face.
const PLACEHOLDER_SIZE := Vector3(0.6, 1.2, 0.45)


## Build the mesh and write it where the placed scene expects it.
## Returns true if a real model was used, false if the placeholder was.
static func build() -> bool:
	var mesh: ArrayMesh = null
	var used_model := false

	if FileAccess.file_exists(OBJ_PATH):
		mesh = _parse_obj(OBJ_PATH)
		if mesh != null and mesh.get_surface_count() > 0:
			_apply_material(mesh)
			used_model = true
		else:
			push_warning("FleaMarket: terminal.obj present but produced no geometry")
			mesh = null

	if mesh == null:
		mesh = _placeholder()

	ResourceSaver.save(mesh, MESH_PATH)
	ResourceLoader.load(MESH_PATH, "", ResourceLoader.CACHE_MODE_REPLACE)
	return used_model


static func mesh_size() -> Vector3:
	var res = ResourceLoader.load(MESH_PATH)
	if res is Mesh:
		var aabb: AABB = res.get_aabb()
		if aabb.size.length() > 0.01:
			return aabb.size
	return PLACEHOLDER_SIZE


# --- Placeholder ---

static func _placeholder() -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = PLACEHOLDER_SIZE

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.11, 0.13, 0.12)
	mat.metallic = 0.35
	mat.roughness = 0.55
	mat.emission_enabled = true
	mat.emission = Color(0.24, 0.92, 0.45)
	mat.emission_energy_multiplier = 0.45

	# Baked into an ArrayMesh, offset so the box sits ON the origin rather than
	# straddling it. Vanilla furniture has its origin at the base; a centred
	# mesh would sink half its height through the floor.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(box, 0, Transform3D(Basis(), Vector3(0, PLACEHOLDER_SIZE.y * 0.5, 0)))
	st.generate_normals()
	st.generate_tangents()

	var array_mesh := st.commit()
	array_mesh.surface_set_material(0, mat)
	return array_mesh


# --- OBJ ---

static func _apply_material(mesh: ArrayMesh) -> void:
	var mat := StandardMaterial3D.new()
	mat.roughness = 0.6
	mat.metallic = 0.2
	mat.albedo_color = Color(1, 1, 1)

	var texture := _load_texture()
	if texture != null:
		mat.albedo_texture = texture
	else:
		mat.albedo_color = Color(0.16, 0.18, 0.17)

	for surface in range(mesh.get_surface_count()):
		mesh.surface_set_material(surface, mat)


static func _load_texture() -> ImageTexture:
	for entry in ["terminal.png", "terminal.jpg", "terminal.jpeg"]:
		# Explicitly typed: the loop variable comes from an untyped Array, so it
		# is a Variant and := would have nothing to infer from.
		var file_name: String = str(entry)
		var path: String = MODEL_DIR + "/" + file_name
		if not FileAccess.file_exists(path):
			continue
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.is_empty():
			continue
		var img := Image.new()
		var err := ERR_FILE_UNRECOGNIZED
		if file_name.ends_with(".png"):
			err = img.load_png_from_buffer(bytes)
		else:
			err = img.load_jpg_from_buffer(bytes)
		if err != OK:
			continue
		img.generate_mipmaps()
		return ImageTexture.create_from_image(img)
	return null


## Minimal OBJ reader: vertices, UVs, normals and triangulated faces, split
## into one surface per `usemtl` group. Enough for a prop; it is not a general
## importer and deliberately ignores materials, which are applied above.
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
