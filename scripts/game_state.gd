extends Node
## Global game state, registered as the autoload "GameState".
##
## Two layers:
## - The NIGHT: one reporter's attempt. Inventory, health, evidence carried, the night's seed and
##   its event log. Lost when the reporter goes missing. A paused night lives in SAVE_PATH.
## - The META: what survives. Evidence sent home, facts locked in by that evidence, and the
##   compound's memory (doors that stay open). Lives in META_PATH.

const VERSION := "0.5.5"
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
	"key_infirmary": {
		"name": "Infirmary Key",
		"desc": "A steel key on a red cord. Stamped: INFIRMARY. STAFF ONLY.",
		"kind": "key",
	},
	"bandages": {
		"name": "Bandages",
		"desc": "A clean roll of gauze. Restores your condition a little.",
		"kind": "heal",
		"amount": 2,
	},
	"pipe": {
		"name": "Lead Pipe",
		"desc": "Heavy enough. It won't hold up for long. Hold [{aim}] to ready it, [{interact}] to swing.",
		"kind": "melee",
		"damage": 2,
		"uses": 6,
		"reach": 2.0,
	},
	"fire_axe": {
		"name": "Fire Axe",
		"desc": "From an emergency cabinet. Hits hard, and a blow on someone stunned puts them down. It can finish a body on the floor.",
		"kind": "melee",
		"damage": 3,
		"uses": 4,
		"reach": 2.2,
	},
	"revolver": {
		"name": "Revolver",
		"desc": "Six chambers, mostly empty. Loud: anyone asleep in the room will wake. Hold [{aim}], then [{interact}] to fire.",
		"kind": "gun",
		"damage": 3,
	},
	"rounds": {
		"name": "Revolver Rounds",
		"desc": "A few loose rounds in a paper sleeve.",
		"kind": "ammo",
		"amount": 3,
	},
	"lamp_oil": {
		"name": "Lamp Oil",
		"desc": "A tin of lamp oil and a book of matches. Enough to burn one body, so it doesn't get back up.",
		"kind": "finisher",
	},
}

## Evidence. Leads go in the notebook, not item slots, and only count once sent home.
## `channel`: what the typewriter must be able to send (1 = short text). `reveals`: a fact
## the lead exposes; sending it home locks that fact for every later night.
const LEADS := {
	"lead_code": {
		"name": "Note with numbers",
		"desc": "Torn from a pocket diary: \"Records cabinet. {cabinet_code}. Don't let Brother Ames see.\"",
		"words": "RECORDS ROOM CABINET PADLOCK CODE IS {cabinet_code}",
		"reveals": "cabinet_code",
		"channel": 1,
	},
	"lead_ledger": {
		"name": "Donation ledger",
		"desc": "A page of member donations. The sums are absurd for a church this size, and every one is marked \"for the Work.\"",
		"words": "CHURCH TAKING HUGE DONATIONS FOR THE WORK",
		"channel": 1,
	},
	"lead_benefactors": {
		"name": "Benefactor roll",
		"desc": "A leather-bound roll of members by giving. The top names have gold stars and a note: \"Diamond Circle. Separate tonic. Dines with the Founder.\"",
		"words": "RICH MEMBERS GET SEPARATE TONIC AND THE FOUNDER",
		"channel": 1,
	},
	"lead_batch": {
		"name": "Batch label",
		"desc": "Peeled from a crate: \"Batch 41. General membership. Benefactor batches are drawn separately, by hand.\"",
		"words": "TONIC BOTTLED HERE IN TWO GRADES",
		"channel": 1,
	},
	"lead_reel": {
		"name": "Sermon reel",
		"desc": "A reel of tape labeled with last month's date. You know the voice from photographs that are sixty years old.",
		"words": "FOUNDER VOICE ON TAPE DATED LAST MONTH",
		"channel": 1,
	},
	"lead_shipping": {
		"name": "Shipping slip",
		"desc": "A courier slip for twelve crates of \"tonic\" to addresses across the city. Dated this week.",
		"words": "TWELVE CRATES OF TONIC SHIPPING ACROSS CITY THIS WEEK",
		"channel": 1,
	},
}

# ---------------------------------------------------------------- night state

var inventory: Array[String] = []
var equipped := ""      # the weapon in hand, or ""
var wear := {}          # uses left per melee weapon: {"pipe": 4}
var ammo := 0           # revolver rounds carried

## Debug switches (F4, debug builds only). Kept for the session, not saved; every run report
## records which were on, so a debug night is never mistaken for a real one.
var debug := {"infinite_ammo": false}
var flags := {}
var health := MAX_HEALTH
var spawn := {}       # {"pos": [x, y, z], "yaw": float} when resuming a paused night
var night_seed := 0
var leads: Array[String] = []   # found tonight, not yet sent
var night_facts := {}           # facts rolled tonight that aren't locked yet
var events: Array = []             # [{"t": seconds, "type": String, ...}]
var night_time := 0.0           # seconds since the night began
var run_file := ""              # the Recorder's file for this night

## Set before reloading the scene: "continue", "night" (new reporter) or "reset" skips the title.
var pending := ""
## Survives within a session so the tutorial doesn't repeat after every death.
var tutorial_seen := false

var _streams := {}

# ---------------------------------------------------------------- meta state

var meta := {}


## Player settings. Saved on their own, so "Start over" never resets them.
const SETTINGS_PATH := "user://settings.json"
var settings := {
	"aim_assist": false,   # raising a weapon turns you toward the nearest hostile resident
}


func _ready() -> void:
	load_meta()
	load_settings()


func load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
	if typeof(data) == TYPE_DICTIONARY:
		for k in settings:
			if data.has(k):
				settings[k] = data[k]


func save_settings() -> void:
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(settings))


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
	equipped = ""
	wear = {}
	ammo = 0
	flags = {}
	health = MAX_HEALTH
	spawn = {}
	leads.clear()
	night_facts = {}
	events = []
	night_time = 0.0
	run_file = ""
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


## How roused the compound is tonight: 0 Calm, 1 Uneasy, 2 Roused. Resets each night.
func alert() -> int:
	return int(flags.get("alert", 0))


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

func can_fire() -> bool:
	return debug.infinite_ammo or ammo > 0


func has_item(id: String) -> bool:
	return inventory.has(id)


func add_item(id: String) -> bool:
	# Rounds go in the revolver's box, not a slot of their own.
	if ITEMS.get(id, {}).get("kind", "") == "ammo":
		ammo += int(ITEMS[id].amount)
		return true
	# A second revolver is only worth its rounds.
	if ITEMS.get(id, {}).get("kind", "") == "gun" and inventory.has(id):
		ammo += 2
		return true
	if inventory.size() >= MAX_SLOTS:
		return false
	inventory.append(id)
	if ITEMS.get(id, {}).get("kind", "") == "melee":
		wear[id] = int(ITEMS[id].uses)
	if equipped == "" and ITEMS.get(id, {}).get("kind", "") in ["melee", "gun"]:
		equipped = id
	return true


func remove_item(id: String) -> void:
	inventory.erase(id)
	wear.erase(id)
	if equipped == id:
		equipped = ""


## The equipped weapon's name with its state, e.g. "Lead Pipe (4)" or "Revolver: 3 rounds".
func weapon_label() -> String:
	if equipped == "":
		return ""
	if ITEMS[equipped].kind == "gun":
		if debug.infinite_ammo:
			return "%s: unlimited (debug)" % item_name(equipped)
		return "%s: %d %s" % [item_name(equipped), ammo, "round" if ammo == 1 else "rounds"]
	return "%s (%d)" % [item_name(equipped), int(wear.get(equipped, 0))]


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


## Sends evidence home. Returns the dispatch as telegram lines. What's sent is permanent.
func send_leads() -> Array:
	var ids := sendable()
	if ids.is_empty():
		return []
	var lines := []
	for id in ids:
		lines.append(lead_text(id, "words") + " STOP")
		if LEADS[id].has("reveals"):
			var f: String = LEADS[id].reveals
			meta.facts[f] = fact(f)
		meta.sent.append(id)
		leads.erase(id)
	var header := "TO CITY DESK FROM REPORTER %d  %s" % [int(meta.reporter), clock_time()]
	meta.dispatches.append({"reporter": meta.reporter, "header": header, "lines": lines})
	log_event("dispatch", {"ids": ids, "lines": lines})
	save_meta()
	return [header] + lines


## The time inside the compound: each night starts at 11:52 P.M.
func clock_time() -> String:
	var m := 23 * 60 + 52 + int(night_time / 60.0)
	var h := (m / 60) % 24
	var suffix := "P.M." if h >= 12 else "A.M."
	var h12 := h % 12
	if h12 == 0:
		h12 = 12
	return "%d:%02d %s" % [h12, m % 60, suffix]


## Every line the office has received, oldest first, for the next reporter to read.
func briefing() -> Array:
	var out := []
	for d in meta.dispatches:
		for line in d.get("lines", [d.get("text", "")] if d.has("text") else []):
			if not out.has(line):
				out.append(line)
	return out


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
		"equipped": equipped,
		"wear": wear.duplicate(),
		"ammo": ammo,
		"flags": flags.duplicate(),
		"night_seed": night_seed,
		"leads": leads.duplicate(),
		"night_facts": night_facts.duplicate(),
		"log": events.duplicate(true),
		"night_time": night_time,
		"run_file": run_file,
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
	equipped = str(data.get("equipped", ""))
	wear = data.get("wear", {})
	for k in wear:
		wear[k] = int(wear[k])
	ammo = int(data.get("ammo", 0))
	flags = data.get("flags", {})
	health = int(data.get("health", MAX_HEALTH))
	spawn = {"pos": data.get("pos", [0, 0, 0]), "yaw": float(data.get("yaw", 0.0))}
	night_seed = int(data.night_seed)
	leads.assign(data.get("leads", []))
	night_facts = data.get("night_facts", {})
	events = data.get("log", [])
	night_time = float(data.get("night_time", 0.0))
	run_file = str(data.get("run_file", ""))
	_streams = {}
	return true
