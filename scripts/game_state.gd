extends Node
## Global game state: version, inventory, story flags, and save/load.
## Registered as the autoload "GameState".

const VERSION := "0.3.0"
const SAVE_PATH := "user://save.json"
const MAX_SLOTS := 6
const MAX_HEALTH := 5

const ITEMS := {
	"key_east": {
		"name": "Brass Key",
		"desc": "A small brass key. A paper tag reads: RECORDS.",
		"kind": "key",
	},
	"bandages": {
		"name": "Bandages",
		"desc": "A clean roll of gauze. Restores your condition a little.",
		"kind": "heal",
		"amount": 2,
	},
}

var inventory: Array[String] = []
var flags := {}
var health := MAX_HEALTH
var spawn := {}  # {"pos": [x, y, z], "yaw": float} when loading a save

## Set before reloading the scene: "continue" or "new" skips the title screen.
var pending := ""
## Survives new games within a session so the tutorial doesn't repeat after every death.
var tutorial_seen := false


func new_game() -> void:
	inventory.clear()
	flags = {}
	health = MAX_HEALTH
	spawn = {}


func has_item(id: String) -> bool:
	return inventory.has(id)


func add_item(id: String) -> bool:
	if inventory.size() >= MAX_SLOTS:
		return false
	inventory.append(id)
	return true


func remove_item(id: String) -> void:
	inventory.erase(id)


func item_name(id: String) -> String:
	return ITEMS.get(id, {}).get("name", id)


func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


func save_game(pos: Vector3, yaw: float, hp: int) -> bool:
	health = hp
	var data := {
		"version": VERSION,
		"pos": [pos.x, pos.y, pos.z],
		"yaw": yaw,
		"health": hp,
		"inventory": inventory.duplicate(),
		"flags": flags.duplicate(),
		"saved_at": Time.get_datetime_string_from_system(),
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data))
	return true


func load_game() -> bool:
	if not has_save():
		return false
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return false
	var data = JSON.parse_string(f.get_as_text())
	if typeof(data) != TYPE_DICTIONARY:
		return false
	new_game()
	inventory.assign(data.get("inventory", []))
	flags = data.get("flags", {})
	health = int(data.get("health", MAX_HEALTH))
	spawn = {"pos": data.get("pos", [0, 0, 0]), "yaw": float(data.get("yaw", 0.0))}
	return true
