extends Node3D

## The market terminal as the game sees it: an interactable fixture in the
## shelter.
##
## `Interact()` and `UpdateTooltip()` are the two methods Scripts/Interactor.gd
## calls on a collider's owner. Their names and zero-argument signatures are the
## engine-side contract and are not ours to change.
##
## This class holds NO market logic and never will. It is the physical handle
## the player grabs; everything behind it belongs to the terminal UI, which in
## turn only renders what the server sends. See the non-negotiables in README.

signal opened

var _game_data: Resource = null
var _open_handler: Callable = Callable()


func _ready() -> void:
	# GameData is a preloaded .tres singleton shared by the whole game. Reaching
	# it via ResourceLoader rather than preload keeps this script loadable from
	# a mod archive even when the resource path moves under us.
	_game_data = load("res://Resources/GameData.tres")


## Wire the terminal to whatever opens the market UI. Kept as an injected
## Callable so this node has no reference to, and no opinion about, the UI.
func set_open_handler(handler: Callable) -> void:
	_open_handler = handler


func UpdateTooltip() -> void:
	if _game_data == null:
		return
	_game_data.tooltip = "Flea Market Terminal [Open]"


func Interact() -> void:
	opened.emit()
	if _open_handler.is_valid():
		_open_handler.call()
