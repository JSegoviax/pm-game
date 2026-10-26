extends Node
## Run recorder, registered as the autoload "Recorder".
##
## Every night writes a complete record of what happened to a folder on the player's computer
## (~/PMRuns), the way a QA tester attaches a session to a bug ticket:
## - <run>.json: everything, for Claude. Platform, the night's setup, every event, a position
##   trail several times a second (where the player and the resident were, health, keys held),
##   and the outcome.
## - <run>.txt: the same night as a readable timeline, for a human.
## - <run>_flag<n>.png: a screenshot for every moment flagged with F9 (R3 on a controller).
##
## The file is rewritten every few seconds, so even a crash or a force-quit leaves a record.

const FORMAT := "pm-run/1"
const SAMPLE_EVERY := 0.2   # seconds between trail samples
const FLUSH_EVERY := 5.0    # seconds between writes to disk
const KEEP_RUNS := 40       # older runs are deleted

const TRAIL_FIELDS := ["t", "x", "z", "yaw", "room", "hp", "res_state", "res_x", "res_z", "keys"]

var folder := ""
var run_name := ""          # file name without extension, e.g. 2026-10-25_2031_r3_seed2859317759
var placed := {}            # what went where tonight: {"key_east": "hall_bench_n", ...}
var trail: Array = []       # rows matching TRAIL_FIELDS
var flags := 0
var outcome := {}

var _main: Node = null
var _active := false
var _started_at := ""
var _meta_at_start := {}
var _sample_t := 0.0
var _flush_t := 0.0
var _last_res_state := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	folder = _pick_folder()


func _pick_folder() -> String:
	var home := OS.get_environment("HOME")
	if home != "":
		var f := home.path_join("PMRuns")
		if DirAccess.make_dir_recursive_absolute(f) == OK:
			return f
	var fallback := ProjectSettings.globalize_path("user://runs")
	DirAccess.make_dir_recursive_absolute(fallback)
	return fallback


# ---------------------------------------------------------------- lifecycle

## A new night has started. Call after GameState.new_night().
func begin(main: Node) -> void:
	_main = main
	placed = {}
	trail = []
	flags = 0
	outcome = {"status": "in_progress"}
	_started_at = Time.get_datetime_string_from_system()
	_meta_at_start = GameState.meta.duplicate(true)
	run_name = "%s_r%d_seed%d" % [
		Time.get_datetime_string_from_system().replace("T", "_").replace(":", "").left(15),
		int(GameState.meta.reporter), GameState.night_seed]
	GameState.run_file = run_name
	_last_res_state = ""
	_active = true
	_prune()
	flush()


## A paused night is being picked up again. Reopens the same record and keeps adding to it.
func resume(main: Node) -> void:
	_main = main
	_active = true
	_last_res_state = ""
	placed = {}
	run_name = GameState.run_file
	var data = null
	if run_name != "" and FileAccess.file_exists(_path(".json")):
		data = JSON.parse_string(FileAccess.get_file_as_string(_path(".json")))
	if typeof(data) == TYPE_DICTIONARY:
		_started_at = data.get("started_at", "")
		_meta_at_start = data.get("meta_at_start", {})
		trail = data.get("trail", {}).get("rows", [])
		flags = int(data.get("flags", 0))
	else:
		# No record to continue (older save): start one for the rest of this night.
		if run_name == "":
			run_name = "%s_r%d_seed%d_resumed" % [
				Time.get_datetime_string_from_system().replace("T", "_").replace(":", "").left(15),
				int(GameState.meta.reporter), GameState.night_seed]
			GameState.run_file = run_name
		_started_at = Time.get_datetime_string_from_system()
		_meta_at_start = GameState.meta.duplicate(true)
		trail = []
	outcome = {"status": "in_progress"}
	GameState.log_event("resumed", {})
	flush()


## The night ended or was put aside. `status`: "missing", "paused" or "quit".
func finish(status: String, summary := {}) -> void:
	if not _active:
		return
	_sample()
	outcome = {"status": status}
	outcome.merge(summary)
	flush()
	if status != "paused":
		_active = false
	_main = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and _active:
		GameState.log_event("quit", {})
		finish("quit")


# ---------------------------------------------------------------- recording

func _physics_process(delta: float) -> void:
	if not _active or _main == null or not is_instance_valid(_main):
		return
	if Input.is_action_just_pressed("flag_moment"):
		flag()
	if get_tree().paused:
		return
	_sample_t -= delta
	if _sample_t <= 0.0:
		_sample_t = SAMPLE_EVERY
		_sample()
	_flush_t -= delta
	if _flush_t <= 0.0:
		_flush_t = FLUSH_EVERY
		flush()


func _sample() -> void:
	if _main == null or not is_instance_valid(_main) or _main.player == null:
		return
	var p: Node3D = _main.player
	var r: Node3D = _main.get_node_or_null("Resident")
	var res_state := ""
	var rx := 0.0
	var rz := 0.0
	if r != null:
		res_state = (r.State.keys()[r.state] as String).to_lower()
		rx = snappedf(r.global_position.x, 0.01)
		rz = snappedf(r.global_position.z, 0.01)
		if res_state != _last_res_state:
			if _last_res_state != "":
				GameState.log_event("resident", {"state": res_state,
					"distance": snappedf(r.global_position.distance_to(p.global_position), 0.01)})
			_last_res_state = res_state
	trail.append([
		snappedf(GameState.night_time, 0.01),
		snappedf(p.global_position.x, 0.01),
		snappedf(p.global_position.z, 0.01),
		snappedf(rad_to_deg(p.rotation.y), 1.0),
		_main._room,
		p.health,
		res_state, rx, rz,
		_held(),
	])


## Which controls are held right now, as a short code: F B L R (move, turn), S (run), E (interact).
func _held() -> String:
	var s := ""
	for pair in [["move_forward", "F"], ["move_back", "B"], ["turn_left", "L"], ["turn_right", "R"],
			["run", "S"], ["interact", "E"]]:
		if Input.is_action_pressed(pair[0]):
			s += pair[1]
	return s


## Marks this moment for review: logs it and saves a screenshot next to the run.
func flag() -> void:
	flags += 1
	var shot := "%s_flag%d.png" % [run_name, flags]
	GameState.log_event("flag", {"n": flags, "screenshot": shot})
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(folder.path_join(shot))
	if _main != null and is_instance_valid(_main):
		_main.hud.flash_hint("Flagged #%d. Tell Claude what you saw." % flags, 4.0)
	flush()


# ---------------------------------------------------------------- writing

func _path(ext: String) -> String:
	return folder.path_join(run_name + ext)


func flush() -> void:
	if run_name == "":
		return
	var data := {
		"format": FORMAT,
		"game_version": GameState.VERSION,
		"started_at": _started_at,
		"written_at": Time.get_datetime_string_from_system(),
		"platform": {
			"os": OS.get_name(),
			"os_version": OS.get_version(),
			"device": OS.get_model_name(),
			"gpu": RenderingServer.get_video_adapter_name(),
			"renderer": RenderingServer.get_current_rendering_method(),
			"window": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
			"controller": _main != null and is_instance_valid(_main) and _main.hud.pad,
		},
		"reporter": int(GameState.meta.reporter),
		"seed": GameState.night_seed,
		"meta_at_start": _meta_at_start,
		"placed": placed,
		"outcome": outcome,
		"night_time": snappedf(GameState.night_time, 0.01),
		"flags": flags,
		"inventory": GameState.inventory.duplicate(),
		"leads_carried": GameState.leads.duplicate(),
		"events": GameState.events,
		"trail": {"every_seconds": SAMPLE_EVERY, "fields": TRAIL_FIELDS, "rows": trail},
		"meta_now": GameState.meta,
	}
	var f := FileAccess.open(_path(".json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data))
		f.close()
	var t := FileAccess.open(_path(".txt"), FileAccess.WRITE)
	if t != null:
		t.store_string(timeline())
		t.close()


static func clock(seconds: float) -> String:
	var s := int(seconds)
	return "%d:%02d" % [s / 60, s % 60]


## The night as a readable list of steps, like a bug ticket's "steps to reproduce".
func timeline() -> String:
	var lines := [
		"P.M. v%s  Reporter #%d  Seed %d" % [GameState.VERSION, int(GameState.meta.reporter), GameState.night_seed],
		"Started %s  Status: %s" % [_started_at, outcome.get("status", "in_progress")],
		"Placed tonight: " + ", ".join(placed.keys().map(func(k) -> String: return "%s at %s" % [k, placed[k]])),
		"",
	]
	for e in GameState.events:
		var d: Dictionary = e.duplicate()
		var when := clock(float(d.get("t", 0.0)))
		var type: String = d.type
		d.erase("t")
		d.erase("type")
		var detail := ""
		match type:
			"message", "hint":
				detail = "\"%s\"" % str(d.get("text", "")).replace("\n", " / ")
			"menu":
				detail = "%s: %s" % [d.get("title", ""), " | ".join(d.get("options", []))]
			"picked":
				detail = str(d.get("option", "cancelled"))
			_:
				var parts := []
				for k in d:
					var v = d[k]
					if typeof(v) == TYPE_FLOAT and v == floorf(v):
						v = int(v)
					parts.append("%s=%s" % [k, str(v)])
				detail = " ".join(parts)
		lines.append("%6s  %-14s %s" % [when, type, detail])
	return "\n".join(lines) + "\n"


## Keeps the newest KEEP_RUNS runs (and their screenshots); deletes the rest.
func _prune() -> void:
	var dir := DirAccess.open(folder)
	if dir == null:
		return
	var runs: Array = []
	for f in dir.get_files():
		if f.ends_with(".json"):
			runs.append(f.get_basename())
	runs.sort()
	if runs.size() <= KEEP_RUNS:
		return
	var old: Array = runs.slice(0, runs.size() - KEEP_RUNS)
	for f in dir.get_files():
		for r in old:
			if f.begins_with(r):
				dir.remove(f)
				break
