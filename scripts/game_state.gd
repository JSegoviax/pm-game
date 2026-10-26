extends Node
## Global game state, registered as the autoload "GameState".
##
## Two layers:
## - The NIGHT: one reporter's attempt. Inventory, health, evidence carried, the night's seed and
##   its event log. Lost when the reporter goes missing. A paused night lives in SAVE_PATH.
## - The META: what survives. Evidence sent home, facts locked in by that evidence, and the
##   compound's memory (doors that stay open). Lives in META_PATH.

const VERSION := "0.4.0"
const SAVE_PATH := "user://save.json"   # a paused night
const META_PATH := "user://meta.json"   # everything that carries over
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

## Evidence. Leads go in the notebook, not item slots, and only count once sent home.
## `channel`: what the typewriter must be able to send (1 = short text). `reveals`: a fact
## the lead exposes; sending it home locks that fact for every later night.
const LEADS := {
	"lead_code": {
		"name": "Note with numbers",
		"desc": "Torn from a pocket diary: \"Records cabinet. {cabinet_code}. Don't let Brother Ames see.\"",
		"words": "RECORDS CABINET CODE {cabinet_code}.",
		"reveals": "cabinet_code",
		"channel": 1,
	},
	"lead_ledger": {
		"name": "Donation ledger",
		"desc": "A page of member donations. The sums are absurd for a church this size, and every one is marked \"for the Work.\"",
		"words": "CHURCH TAKING HUGE SUMS. FOR THE WORK.",
		"channel": 1,
	},
	"lead_shipping": {
		"name": "Shipping slip",
		"desc": "A courier slip for twelve crates of \"tonic\" to addresses across the city. Dated this week.",
		"words": "TONIC CRATES SHIPPING TO CITY. THIS WEEK.",
		"channel": 1,
	},
}

# ---------------------------------------------------------------- night state

var inventory: Array[String] = []
var flags := {}
var health := MAX_HEALTH
var spawn := {}       # {"pos": [x, y, z], "yaw": float} when resuming a paused night
var night_seed := 0
var leads: Array[String] = []   # found tonight, not yet sent
var night_facts := {}           # facts rolled tonight that aren't locked yet
var events: Array = []             # [{"t": seconds, "type": String, ...}]
var night_time := 0.0           # seconds since the night began

## Set before reloading the scene: "continue", "night" (new reporter) or "reset" skips the title.
var pending := ""
## Survives within a session so the tutorial doesn't repeat after every death.
var tutorial_seen := false

var _streams := {}

# ---------------------------------------------------------------- meta state

var meta := {}


func _ready() -> void:
	load_meta()


func _blank_meta() -> Dictionary:
	return {
		"version": VERSION,
		"reporter": 0,        # how many reporters have been sent
		"sent": [],           # lead ids the office has received
		"dispatches": [],     # [{"reporter": n, "text": String}]
		"facts": {},          # locked facts, e.g. {"cabinet_code": "417"}
		"world": {},          # the compound's memory, e.g. {"door_records_open": true}
		"channel": 1,         # what the typewriter can send
		"history": [],        # one summary per finished night
		"tutorial_done": false,
	}


func load_meta() -> void:
	meta = _blank_meta()
	if not FileAccess.file_exists(META_PATH):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(META_PATH))
	if typeof(data) == TYPE_DICTIONARY:
		meta.merge(data, true)
		meta.reporter = int(meta.reporter)
		meta.channel = int(meta.channel)


func save_meta() -> bool:
	var f := FileAccess.open(META_PATH, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(meta))
	return true


func has_history() -> bool:
	return int(meta.reporter) > 0


## Erase everything: the first reporter starts from absolute zero again.
func reset_all() -> void:
	meta = _blank_meta()
	save_meta()
	clear_save()


# ---------------------------------------------------------------- nights

## Begins a fresh night with the next reporter.
func new_night() -> void:
	inventory.clear()
	flags = {}
	health = MAX_HEALTH
	spawn = {}
	leads.clear()
	night_facts = {}
	events = []
	night_time = 0.0
	_streams = {}
	var r := RandomNumberGenerator.new()
	r.randomize()
	night_seed = r.randi()
	meta.reporter = int(meta.reporter) + 1
	save_meta()
	clear_save()
	log_event("night_start", {"reporter": meta.reporter, "night_seed": night_seed})


## One random stream per system, all derived from the night's seed. Placing items never shifts
## where residents go, and the same seed always rebuilds the same night.
func rng(stream: String) -> RandomNumberGenerator:
	if not _streams.has(stream):
		var r := RandomNumberGenerator.new()
		r.seed = hash("%d:%s" % [night_seed, stream])
		_streams[stream] = r
	return _streams[stream]


## Picks one entry from `options`, deterministically for this night and stream.
func pick(stream: String, options: Array):
	if options.is_empty():
		return null
	return options[rng(stream).randi_range(0, options.size() - 1)]


## A fact about the compound (a code, a name). Locked facts never change; others are rolled
## once per night from the "facts" stream.
func fact(name: String) -> String:
	if meta.facts.has(name):
		return str(meta.facts[name])
	if not night_facts.has(name):
		match name:
			"cabinet_code":
				night_facts[name] = "%03d" % rng("facts").randi_range(100, 999)
			_:
				night_facts[name] = "?"
	return str(night_facts[name])


## Whether this reporter knows a fact: briefed from evidence sent home, or found tonight.
func knows(name: String) -> bool:
	return meta.facts.has(name) or flags.get("know_" + name, false)


func world(key: String) -> bool:
	return bool(meta.world.get(key, false))


## The compound remembers: nobody comes back to lock up.
func remember(key: String) -> void:
	meta.world[key] = true
	save_meta()


func log_event(type: String, data := {}) -> void:
	var e := {"t": snappedf(night_time, 0.1), "type": type}
	e.merge(data)
	events.append(e)


func count_events(type: String) -> int:
	return events.filter(func(e) -> bool: return e.type == type).size()


# ---------------------------------------------------------------- items and leads

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
	if LEADS.has(id):
		return LEADS[id].name
	return ITEMS.get(id, {}).get("name", id)


func lead_text(id: String, key: String) -> String:
	var t: String = LEADS[id][key]
	for f in ["cabinet_code"]:
		if t.contains("{%s}" % f):
			t = t.replace("{%s}" % f, fact(f))
	return t


func is_sent(id: String) -> bool:
	return meta.sent.has(id)


func add_lead(id: String) -> void:
	if leads.has(id) or is_sent(id):
		return
	leads.append(id)
	if LEADS[id].has("reveals"):
		flags["know_" + LEADS[id].reveals] = true
	log_event("lead_found", {"id": id})


## Leads the typewriter can send right now.
func sendable() -> Array:
	return leads.filter(func(id) -> bool: return int(LEADS[id].channel) <= int(meta.channel))


## Sends evidence home. Returns the dispatch text. What's sent is permanent.
func send_leads() -> String:
	var ids := sendable()
	if ids.is_empty():
		return ""
	var words := []
	for id in ids:
		words.append(lead_text(id, "words"))
		if LEADS[id].has("reveals"):
			var f: String = LEADS[id].reveals
			meta.facts[f] = fact(f)
		meta.sent.append(id)
		leads.erase(id)
	var text := " ".join(words) + " STOP."
	meta.dispatches.append({"reporter": meta.reporter, "text": text})
	log_event("dispatch", {"ids": ids, "text": text})
	save_meta()
	return text


## What the next reporter read before leaving for the compound.
func briefing() -> String:
	if meta.dispatches.is_empty():
		return ""
	var lines := []
	for d in meta.dispatches.slice(-3):
		lines.append(d.text)
	return "\n".join(lines)


# ---------------------------------------------------------------- the end of a night

## Closes the night: the reporter is gone. Unsent leads are lost. Returns the summary
## the post-mortem shows.
func end_night(cause: String) -> Dictionary:
	log_event("missing", {"cause": cause})
	var rooms := []
	for e in events:
		if e.type == "room" and not rooms.has(e.room):
			rooms.append(e.room)
	var sent_ids := []
	for e in events:
		if e.type == "dispatch":
			sent_ids.append_array(e.ids)
	var summary := {
		"reporter": meta.reporter,
		"night_seed": night_seed,
		"time": night_time,
		"rooms": rooms,
		"found": count_events("lead_found"),
		"sent": sent_ids.map(func(id) -> String: return item_name(id)),
		"lost": leads.map(func(id) -> String: return item_name(id)),
		"hits": count_events("hurt"),
		"shoves": count_events("shove"),
		"opened": events.filter(func(e) -> bool: return e.type == "opened").map(func(e) -> String: return e.what),
		"cause": cause,
	}
	meta.history.append(summary)
	leads.clear()
	save_meta()
	clear_save()
	return summary


# ---------------------------------------------------------------- pausing a night

func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


func clear_save() -> void:
	if has_save():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))


## Pauses the night so you can stop and pick it up later. It never protects you from death.
func save_game(pos: Vector3, yaw: float, hp: int) -> bool:
	health = hp
	var data := {
		"version": VERSION,
		"pos": [pos.x, pos.y, pos.z],
		"yaw": yaw,
		"health": hp,
		"inventory": inventory.duplicate(),
		"flags": flags.duplicate(),
		"night_seed": night_seed,
		"leads": leads.duplicate(),
		"night_facts": night_facts.duplicate(),
		"log": events.duplicate(true),
		"night_time": night_time,
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
	var data = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if typeof(data) != TYPE_DICTIONARY or not data.has("night_seed"):
		return false  # saves from before v0.4 can't be resumed
	inventory.assign(data.get("inventory", []))
	flags = data.get("flags", {})
	health = int(data.get("health", MAX_HEALTH))
	spawn = {"pos": data.get("pos", [0, 0, 0]), "yaw": float(data.get("yaw", 0.0))}
	night_seed = int(data.night_seed)
	leads.assign(data.get("leads", []))
	night_facts = data.get("night_facts", {})
	events = data.get("log", [])
	night_time = float(data.get("night_time", 0.0))
	_streams = {}
	return true
