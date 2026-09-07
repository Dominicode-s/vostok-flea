extends RefCounted

# Deliberately no class_name: a global class registered from inside a mod
# archive collides across mods and survives reloads badly. Callers preload it.

## Places the market's physical fixtures in the player's shelter.
##
## The game's interaction contract, read off Scripts/Interactor.gd, is exact and
## easy to get subtly wrong:
##
##   1. A RayCast3D on the player camera scans collision_mask 16541. That mask
##      includes bit 16 and excludes bit 32, so the body the ray must hit is the
##      one on layer 16 -- vanilla containers put their *physical* collider on
##      layer 32 precisely so the ray ignores it.
##   2. The body must be in the group "Interactable".
##   3. The engine then calls `target.owner.UpdateTooltip()` and
##      `target.owner.Interact()` -- on the collider's OWNER, not the collider.
##
## Point 3 is the trap. `owner` is populated automatically for nodes loaded from
## a PackedScene, but a tree built at runtime has `owner == null` on every node,
## and a null owner means the raycast finds the body, sets the tooltip flag, and
## then hard-crashes on the interact call. So owner is assigned explicitly here,
## after the node is in the tree.

const INTERACT_COLLISION_LAYER := 16
const INTERACTABLE_GROUP := "Interactable"

# INTERIM PLACEMENT.
#
# The first cut hardcoded the Bunker's canteen table at (-3.5, 0, -10). That was
# wrong: there are four shelters -- Bunker, Cabin, Tent, Attic -- and all of them
# declare mapType "Shelter", so the terminal was placed in every one of them at
# coordinates that only mean anything in the Bunker. In the Cabin, which is an
# empty shell around the origin, those coordinates are outside the building.
#
# Per-shelter coordinate tables would only move the guesswork around, because
# nothing in the scenes tells us where a wall is. So placement is anchored to
# the player instead: it works in any shelter, including ones the developer adds
# later, without knowing any geometry.
#
# The real answer is the game's own furniture system -- Furniture nodes carry an
# ItemData and persist through ShelterSave.furnitures, so the player places the
# terminal where they want it and it stays there. That is the follow-up, and the
# courier crate needs it too (FurnitureSave has `container` and `storage`).
const TERMINAL_SIZE := Vector3(0.42, 0.5, 0.28)

## How far in front of the player the terminal is placed, and how high off their
## origin. Chest height at just under two metres reads as "on a surface in front
## of you" rather than "embedded in the floor".
const PLACE_DISTANCE := 1.8
const PLACE_HEIGHT := 0.6

const TERMINAL_NODE_NAME := "FleaMarketTerminal"


## Build the terminal fixture. The caller adds it to the shelter and then calls
## finalise() once it is in the tree.
static func build_terminal(interact_script: Script) -> Node3D:
	var root := Node3D.new()
	root.name = TERMINAL_NODE_NAME
	root.set_script(interact_script)

	# --- Visible body ---
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Mesh"
	var box := BoxMesh.new()
	box.size = TERMINAL_SIZE
	mesh_instance.mesh = box

	# Placeholder look: a dark casing with a glowing screen-green emission, so
	# it is unmistakably the mod's object and not a vanilla prop. Replaced by a
	# real model before this ships to players.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.09, 0.11, 0.10)
	mat.emission_enabled = true
	mat.emission = Color(0.25, 0.95, 0.45)
	mat.emission_energy_multiplier = 0.6
	mat.roughness = 0.7
	mat.metallic = 0.2
	mesh_instance.material_override = mat
	root.add_child(mesh_instance)

	# --- Interaction body (layer 16, group "Interactable") ---
	var body := StaticBody3D.new()
	body.name = "InteractBody"
	body.collision_layer = INTERACT_COLLISION_LAYER
	# It is scanned, never scanning: leaving a mask on costs physics work and
	# buys nothing.
	body.collision_mask = 0
	body.add_to_group(INTERACTABLE_GROUP)

	var shape_node := CollisionShape3D.new()
	shape_node.name = "CollisionShape3D"
	var shape := BoxShape3D.new()
	# Slightly proud of the mesh so the ray catches the object rather than
	# slipping past an exactly-coincident face.
	shape.size = TERMINAL_SIZE * 1.05
	shape_node.shape = shape
	body.add_child(shape_node)
	root.add_child(body)

	return root


## Assign `owner` across the built subtree. MUST be called after the root is
## inside the scene tree -- Godot rejects an owner that is not an ancestor of
## the node, and an unowned collider makes Interactor.Interact() call a method
## on null.
static func finalise(root: Node) -> void:
	for child in root.get_children():
		child.owner = root
		for grandchild in child.get_children():
			grandchild.owner = root


## The shelter map node, or null when the player is not in a shelter.
##
## Map.gd exports mapType; the bunker sets it to "Shelter" (Scenes/Bunker.tscn).
## Testing that property rather than the node name means this keeps working if
## the developer adds a second shelter.
static func find_shelter(tree: SceneTree) -> Node3D:
	var map := tree.root.get_node_or_null("Map")
	if map == null:
		return null
	if not "mapType" in map:
		return null
	if str(map.mapType) != "Shelter":
		return null
	return map as Node3D


## Where fixtures get parented. Content is the NavigationRegion3D holding the
## shelter geometry; falling back to the map root keeps this from failing hard
## if that layer is ever renamed.
static func fixture_parent(map: Node3D) -> Node3D:
	var content := map.get_node_or_null("Content")
	if content != null and content is Node3D:
		return content as Node3D
	return map


## The player body, or null if the scene has not finished building.
##
## Two nodes sit in the "Player" group -- the Controller (CharacterBody3D) and a
## line-of-sight StaticBody3D under the camera. Only the Controller is the body
## whose position means "where the player is standing", so it is matched by type
## rather than by taking the first group member.
static func find_player(map: Node3D) -> Node3D:
	var controller := map.get_node_or_null("Core/Controller")
	if controller is CharacterBody3D:
		return controller as Node3D
	return null


## Where the terminal goes: in front of the player, at chest height.
##
## Returns global coordinates; the caller converts to the parent's local space.
static func placement_for(player: Node3D) -> Vector3:
	var basis := player.global_transform.basis
	# -Z is forward in Godot. Flattened to the horizontal plane so looking up or
	# down does not bury the terminal in the floor or hang it from the ceiling.
	var forward := Vector3(-basis.z.x, 0.0, -basis.z.z)
	if forward.length_squared() < 0.001:
		forward = Vector3(0, 0, -1)
	forward = forward.normalized()
	return player.global_position + forward * PLACE_DISTANCE + Vector3.UP * PLACE_HEIGHT
