extends Node3D
## P.M. — the vertical slice level.
## Rooms are built in code from simple shapes so we can iterate fast before real assets.

const PLAYER_SCRIPT := preload("res://scripts/player.gd")
const RESIDENT_SCRIPT := preload("res://scripts/resident.gd")
const HUD_SCRIPT := preload("res://scripts/hud.gd")
const INVENTORY_SCRIPT := preload("res://scripts/inventory_ui.gd")

const WALL_H := 4.0
const WALL_T := 0.3
const DOOR_REACH := 1.5
const SHOVE_RANGE := 1.8
const START_POS := Vector3(0, 0.05, 3.5)

const FOYER := Vector3(0, 0, 0)
const HALL := Vector3(40, 0, 0)
const RECORDS := Vector3(80, 0, 0)

var player: CharacterBody3D
var hud: CanvasLayer
var inventory_ui: Control

var zones: Array = []          # { box, camera, room }
var interactables: Array = []  # { pos: Callable, range, prompt: Callable, action: Callable }
var _flicker_lights: Array = []
var _hallway_bounds: AABB
var _room := ""
var _current_zone := -1
var _started := false
var _busy := false
var _dead := false
var _ui_cd := 0.0

var _music_dread: AudioStreamPlayer
var _music_calm: AudioStreamPlayer

# Tutorial
var _tut_step := -1
var _tut_t := 0.0
var _tut_from := Vector3.ZERO
var _tut_run_t := 0.0
var _interacted := false


func _ready() -> void:
	_build_environment()
	_build_foyer()
	_build_hallway()
	_build_records_room()

	hud = HUD_SCRIPT.new()
	add_child(hud)
	inventory_ui = INVENTORY_SCRIPT.new()
	hud.add_child(inventory_ui)
	inventory_ui.closed.connect(func() -> void: _ui_cd = 0.25)
	_setup_audio()

	player = CharacterBody3D.new()
	player.set_script(PLAYER_SCRIPT)
	player.name = "Reporter"
	add_child(player)
	player.global_position = START_POS
	player.frozen = true
	player.hurt.connect(_on_player_hurt)
	player.healed.connect(func(_h: int) -> void: hud.show_condition(player.condition()))
	player.died.connect(_on_player_died)
	inventory_ui.player = player
	inventory_ui.hud = hud
	_update_camera(true)

	hud.set_black(true)
	var mode := GameState.pending
	GameState.pending = ""
	if mode == "":
		mode = await _title_screen()
	_start(mode)


func _title_screen() -> String:
	while true:
		var opts := []
		if GameState.has_save():
			opts.append("Continue the night")
		opts.append("Send the next reporter" if GameState.has_history() else "New Game")
		if GameState.has_history():
			opts.append("Start over")
		var i: int = await hud.choose("P.M.", opts, false, "A reporter. An occult compound.\nIt is not empty.", true)
		match opts[i]:
			"Continue the night":
				return "continue"
			"Start over":
				var c: int = await hud.choose("Start over from nothing?",
					["No", "Yes, erase everything"], true,
					"Every reporter, all evidence sent and everything the compound remembers will be gone.")
				if c == 1:
					return "reset"
			_:
				return "night"
	return "night"


func _start(mode: String) -> void:
	if mode == "reset":
		GameState.reset_all()
	var loaded := mode == "continue" and GameState.load_game()
	if not loaded:
		GameState.new_night()
	player.health = GameState.health
	if loaded:
		var p: Array = GameState.spawn.pos
		player.global_position = Vector3(p[0], p[1], p[2])
		player.face(GameState.spawn.yaw)
	else:
		player.global_position = START_POS
		player.face(0.0)

	_spawn_pickups()
	_spawn_resident()
	_update_camera(true)
	_music_dread.play()
	_music_calm.play()
	_set_music(_room, 0.01)
	_started = true

	hud.fade(0.0, 2.0)
	if loaded:
		hud.show_message("You pick up where you left off.", 3.0)
	else:
		_night_intro()
	if not GameState.tutorial_seen and not GameState.meta.get("tutorial_done", false):
		_tut_step = 0
		_tut_t = -3.0
		_tut_from = player.global_position
	player.frozen = false


## The opening beat of a night: who you are, and what the earlier reporters sent home.
func _night_intro() -> void:
	var n: int = GameState.meta.reporter
	hud.show_message("Reporter #%d\nCompound of the Quiet Hour, 11:52 P.M." % n, 4.0)
	var brief := GameState.briefing()
	if brief == "":
		return
	await get_tree().create_timer(4.5, false).timeout
	hud.show_message("The last reporter never came back. Before leaving, you read what they sent:\n" + brief, 7.0)


# ---------------------------------------------------------------- environment

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.01, 0.01, 0.015)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.32, 0.34, 0.42)
	env.ambient_light_energy = 0.35
	env.fog_enabled = true
	env.fog_light_color = Color(0.05, 0.05, 0.07)
	env.fog_density = 0.06
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _mat(color: Color, noisy := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 1.0
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	if noisy:
		var noise := FastNoiseLite.new()
		noise.frequency = 0.12
		var tex := NoiseTexture2D.new()
		tex.width = 32
		tex.height = 32
		tex.noise = noise
		tex.seamless = true
		m.albedo_texture = tex
		m.uv1_scale = Vector3(4, 4, 4)
		m.uv1_triplanar = true
	return m


func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material, collide := true) -> Node3D:
	var body: Node3D = StaticBody3D.new() if collide else Node3D.new()
	body.position = pos
	parent.add_child(body)
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	body.add_child(mi)
	if collide:
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		cs.shape = shape
		body.add_child(cs)
	return body


func _room_shell(name_: String, center: Vector3, size_x: float, size_z: float, floor_mat: Material, wall_mat: Material) -> Node3D:
	var room := Node3D.new()
	room.name = name_
	room.position = center
	add_child(room)
	_box(room, Vector3(size_x, 0.2, size_z), Vector3(0, -0.1, 0), floor_mat)
	_box(room, Vector3(size_x, 0.2, size_z), Vector3(0, WALL_H + 0.1, 0), wall_mat, false)
	var hx := size_x / 2.0
	var hz := size_z / 2.0
	_box(room, Vector3(size_x + WALL_T * 2, WALL_H, WALL_T), Vector3(0, WALL_H / 2, -hz - WALL_T / 2), wall_mat)
	_box(room, Vector3(size_x + WALL_T * 2, WALL_H, WALL_T), Vector3(0, WALL_H / 2, hz + WALL_T / 2), wall_mat)
	_box(room, Vector3(WALL_T, WALL_H, size_z), Vector3(-hx - WALL_T / 2, WALL_H / 2, 0), wall_mat)
	_box(room, Vector3(WALL_T, WALL_H, size_z), Vector3(hx + WALL_T / 2, WALL_H / 2, 0), wall_mat)
	return room


func _light(room: Node3D, pos: Vector3, color: Color, energy: float, range_: float, flicker := false) -> void:
	var l := OmniLight3D.new()
	l.position = pos
	l.light_color = color
	l.light_energy = energy
	l.omni_range = range_
	l.shadow_enabled = true
	room.add_child(l)
	if flicker:
		_flicker_lights.append({"light": l, "base": energy, "t": randf() * 10.0})


func _camera(room: Node3D, pos: Vector3, look_at_point: Vector3, fov := 55.0) -> Camera3D:
	var cam := Camera3D.new()
	cam.fov = fov
	room.add_child(cam)
	cam.global_position = room.global_position + pos
	cam.look_at(room.global_position + look_at_point, Vector3.UP)
	return cam


func _zone(room: Node3D, room_name: String, from: Vector3, to: Vector3, cam: Camera3D) -> void:
	var box := AABB(room.global_position + from, Vector3.ZERO).expand(room.global_position + to)
	zones.append({"box": box, "camera": cam, "room": room_name})


func _add_interactable(pos: Callable, range_: float, prompt: Callable, action: Callable) -> Dictionary:
	var entry := {"pos": pos, "range": range_, "prompt": prompt, "action": action}
	interactables.append(entry)
	return entry


## A door. `lock` is optional: {"key": item id, "flag": unlock flag, "text": message when you lack the key}.
func _door(room: Node3D, local_pos: Vector3, to: Vector3, yaw: float, to_room: String, lock := {}) -> void:
	var p := room.global_position + local_pos
	var side_wall := absf(local_pos.x) > absf(local_pos.z)
	var slab := _box(self, Vector3(1.3, 2.4, 0.12), p + Vector3(0, 1.2, 0), _mat(Color(0.22, 0.12, 0.08)), false)
	if side_wall:
		slab.rotation.y = PI / 2
	var knob_off := Vector3(0, 1.1, 0.45) if side_wall else Vector3(0.45, 1.1, 0)
	_box(self, Vector3(0.08, 0.08, 0.08), p + knob_off, _mat(Color(0.75, 0.62, 0.30)), false)

	var d := {"pos": p, "to": to, "yaw": yaw, "room": to_room}
	d.merge(lock)
	_add_interactable(
		func() -> Vector3: return p,
		DOOR_REACH,
		func() -> String: return _door_prompt(d),
		func() -> void: _use_door(d))


func _pickup(id: String, pos: Vector3) -> void:
	if GameState.flags.get("picked_" + id, false):
		return
	var is_lead := GameState.LEADS.has(id)
	var kind: String = "lead" if is_lead else GameState.ITEMS[id].kind
	var node := Node3D.new()
	add_child(node)
	node.global_position = pos
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	match kind:
		"key": mesh.size = Vector3(0.14, 0.05, 0.08)
		"lead": mesh.size = Vector3(0.22, 0.01, 0.28)
		_: mesh.size = Vector3(0.16, 0.12, 0.16)
	mi.mesh = mesh
	if kind == "lead":
		mi.rotation.y = GameState.rng("dressing").randf() * TAU
	var m := StandardMaterial3D.new()
	match kind:
		"key": m.albedo_color = Color(0.85, 0.68, 0.25)
		"lead": m.albedo_color = Color(0.86, 0.80, 0.64)
		_: m.albedo_color = Color(0.92, 0.92, 0.88)
	m.emission_enabled = true
	m.emission = m.albedo_color * 0.4
	mi.material_override = m
	node.add_child(mi)
	var glint := OmniLight3D.new()
	glint.light_color = Color(1.0, 0.92, 0.7)
	glint.light_energy = 0.4
	glint.omni_range = 0.8
	glint.position.y = 0.15
	node.add_child(glint)
	_flicker_lights.append({"light": glint, "base": 0.4, "t": randf() * 10.0})

	var entry := _add_interactable(
		func() -> Vector3: return pos,
		1.5,
		func() -> String: return "Read" if is_lead else "Pick up",
		Callable())
	entry.action = func() -> void: _take(id, node, entry)


# ---------------------------------------------------------------- rooms

func _build_foyer() -> void:
	var foyer := _room_shell("Foyer", FOYER, 12.0, 10.0, _mat(Color(0.30, 0.26, 0.22), true), _mat(Color(0.42, 0.40, 0.36), true))
	var wood := _mat(Color(0.26, 0.16, 0.10))
	var stone := _mat(Color(0.50, 0.48, 0.44), true)
	for x in [-3.0, 3.0]:
		_box(foyer, Vector3(0.6, WALL_H, 0.6), Vector3(x, WALL_H / 2, -1.0), stone)
	# Meeting table with chairs pushed back in a hurry
	_box(foyer, Vector3(3.2, 0.9, 1.1), Vector3(0, 0.45, -2.6), wood)
	_box(foyer, Vector3(0.5, 0.9, 0.5), Vector3(-1.2, 0.45, -1.6), wood).rotation.y = 0.5
	_box(foyer, Vector3(0.5, 0.9, 0.5), Vector3(1.4, 0.45, -3.7), wood).rotation.y = -0.3
	_box(foyer, Vector3(0.5, 0.45, 0.5), Vector3(2.2, 0.22, -1.2), wood).rotation.z = 1.4
	# Reception desk by the entrance
	_box(foyer, Vector3(2.0, 1.0, 0.7), Vector3(-4.2, 0.5, 3.0), wood)
	# The sigil on the north wall
	var sigil := MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.55
	ring.outer_radius = 0.7
	ring.rings = 16
	ring.ring_segments = 6
	sigil.mesh = ring
	sigil.material_override = _mat(Color(0.45, 0.05, 0.04))
	foyer.add_child(sigil)
	sigil.position = Vector3(-3.0, 2.6, -4.8)
	sigil.rotation.x = PI / 2

	_light(foyer, Vector3(0, 3.3, -1.5), Color(1.0, 0.78, 0.5), 1.6, 9.0, true)
	_light(foyer, Vector3(-4.0, 2.5, 3.5), Color(0.6, 0.7, 1.0), 0.9, 6.0)
	_light(foyer, Vector3(2.5, 2.8, 3.0), Color(1.0, 0.8, 0.55), 1.1, 6.5)

	var cam_south := _camera(foyer, Vector3(5.4, 3.6, -4.5), Vector3(-1.5, 0.6, 2.0))
	var cam_north := _camera(foyer, Vector3(-5.4, 3.4, 4.6), Vector3(1.5, 0.8, -2.5))
	_zone(foyer, "Foyer", Vector3(-6, -1, 0.5), Vector3(6, 4, 5), cam_south)
	_zone(foyer, "Foyer", Vector3(-6, -1, -5), Vector3(6, 4, 0.5), cam_north)

	_door(foyer, Vector3(3.5, 0, -4.94), HALL + Vector3(0, 0.05, 6.5), 0.0, "East Hallway")


func _build_hallway() -> void:
	var hall := _room_shell("EastHallway", HALL, 4.0, 16.0, _mat(Color(0.22, 0.24, 0.22), true), _mat(Color(0.34, 0.33, 0.30), true))
	var wood := _mat(Color(0.24, 0.15, 0.10))
	_box(hall, Vector3(0.6, 0.5, 2.4), Vector3(-1.6, 0.25, 2.0), wood)
	_box(hall, Vector3(0.6, 0.5, 2.4), Vector3(1.6, 0.25, -3.5), wood)
	for i in 3:
		_box(hall, Vector3(0.35, 1.3, 0.12), Vector3(1.75, 1.35, 3.0 + i * 0.5), _mat(Color(0.12, 0.12, 0.14)), false)
	for z in [-6.0, -4.5, -1.0, 1.5]:
		_box(hall, Vector3(0.05, 0.5, 0.4), Vector3(-1.95, 2.0, z), _mat(Color(0.65, 0.60, 0.50)), false)

	_light(hall, Vector3(0, 3.3, 4.0), Color(1.0, 0.8, 0.55), 1.0, 6.0)
	_light(hall, Vector3(0, 3.3, -4.5), Color(0.9, 0.95, 1.0), 0.9, 6.0, true)

	var cam_south := _camera(hall, Vector3(1.6, 3.4, -7.6), Vector3(-0.2, 0.6, 3.5), 50.0)
	var cam_north := _camera(hall, Vector3(-1.6, 3.2, 7.6), Vector3(0.2, 0.8, -4.0), 50.0)
	_zone(hall, "East Hallway", Vector3(-2, -1, 0), Vector3(2, 4, 8), cam_south)
	_zone(hall, "East Hallway", Vector3(-2, -1, -8), Vector3(2, 4, 0), cam_north)
	_hallway_bounds = AABB(HALL + Vector3(-2, -1, -8), Vector3(4, 5, 16))

	_door(hall, Vector3(0, 0, 7.94), FOYER + Vector3(3.5, 0.05, -3.9), PI, "Foyer")
	_door(hall, Vector3(0, 0, -7.94), RECORDS + Vector3(0, 0.05, 2.0), 0.0, "Records Room", {
		"key": "key_east",
		"flag": "door_records_open",
		"label": "the Records Room door",
		"text": "Locked. Someone has scratched two letters into the wood: P.M.",
	})


func _build_records_room() -> void:
	var room := _room_shell("RecordsRoom", RECORDS, 6.0, 6.0, _mat(Color(0.30, 0.20, 0.13), true), _mat(Color(0.30, 0.34, 0.28), true))
	var wood := _mat(Color(0.32, 0.20, 0.12))
	# Desk and typewriter
	_box(room, Vector3(1.6, 0.8, 0.8), Vector3(-1.6, 0.4, -2.2), wood)
	_box(room, Vector3(0.5, 0.18, 0.4), Vector3(-1.6, 0.89, -2.2), _mat(Color(0.10, 0.10, 0.11)), false)
	_box(room, Vector3(0.28, 0.02, 0.2), Vector3(-1.6, 1.06, -2.32), _mat(Color(0.92, 0.9, 0.84)), false).rotation.x = -0.9
	# Filing shelves and a cot
	_box(room, Vector3(0.5, 2.2, 2.2), Vector3(2.7, 1.1, -1.5), wood)
	_box(room, Vector3(1.0, 0.4, 2.0), Vector3(2.4, 0.2, 1.8), _mat(Color(0.35, 0.35, 0.40)))

	_light(room, Vector3(-1.4, 2.0, -1.6), Color(1.0, 0.76, 0.45), 1.7, 7.0)
	_light(room, Vector3(1.5, 3.2, 1.5), Color(1.0, 0.85, 0.65), 0.6, 6.0)

	var cam_a := _camera(room, Vector3(2.6, 3.2, 2.6), Vector3(-1.2, 0.6, -1.6), 60.0)
	var cam_b := _camera(room, Vector3(-2.6, 3.2, -2.6), Vector3(1.0, 0.5, 1.6), 60.0)
	_zone(room, "Records Room", Vector3(-3, -1, -3), Vector3(3, 4, 0), cam_a)
	_zone(room, "Records Room", Vector3(-3, -1, 0), Vector3(3, 4, 3), cam_b)

	_door(room, Vector3(0, 0, 2.94), HALL + Vector3(0, 0.05, -7.0), PI, "East Hallway")
	_add_interactable(
		func() -> Vector3: return RECORDS + Vector3(-1.6, 0, -1.7),
		1.3,
		func() -> String: return "Use typewriter",
		_save_prompt)
	# A chain and a three-digit padlock on the filing shelves
	_box(room, Vector3(0.06, 0.12, 0.1), Vector3(2.42, 1.0, -1.5), _mat(Color(0.6, 0.6, 0.62)), false)
	_add_interactable(
		func() -> Vector3: return RECORDS + Vector3(2.0, 0, -1.5),
		1.2,
		_cabinet_prompt,
		_cabinet_action)


## Marked spots, Rogue Legacy style: rooms are hand-built and always the same; what sits on
## these spots changes every night. `before_lock` spots can be reached without the Brass Key,
## so the key always lands on one of them and every night can be finished.
const MARKERS := [
	{"id": "foyer_desk", "pos": FOYER + Vector3(-4.2, 1.05, 3.0), "before_lock": true},
	{"id": "foyer_table", "pos": FOYER + Vector3(0.8, 0.93, -2.6), "before_lock": true},
	{"id": "foyer_floor", "pos": FOYER + Vector3(4.6, 0.06, 1.5), "before_lock": true},
	{"id": "hall_bench_n", "pos": HALL + Vector3(1.55, 0.53, -3.5), "before_lock": true},
	{"id": "hall_bench_s", "pos": HALL + Vector3(-1.55, 0.53, 2.6), "before_lock": true},
	{"id": "records_desk", "pos": RECORDS + Vector3(-1.0, 0.83, -2.1), "before_lock": false},
	{"id": "records_cot", "pos": RECORDS + Vector3(2.4, 0.43, 1.4), "before_lock": false},
]


func _spawn_pickups() -> void:
	var free := MARKERS.duplicate()
	# Every spot is always drawn in the same order, even for things that won't appear, so a
	# resumed night rebuilds exactly as it was.
	var place := func(id: String, early_only: bool, show: bool) -> void:
		var pool := free.filter(func(m) -> bool: return m.before_lock or not early_only)
		var m = GameState.pick("items", pool)
		if m == null:
			return
		free.erase(m)
		if show:
			_pickup(id, m.pos)

	# The key first, on a spot you can reach. Once the door is open for good, no key is needed.
	place.call("key_east", true, not GameState.world("door_records_open"))
	place.call("bandages", false, true)
	# Evidence the office doesn't have yet. Sent leads don't come back.
	for id in ["lead_code", "lead_ledger"]:
		place.call(id, false, not GameState.is_sent(id) or GameState.flags.get("picked_" + id, false))


func _spawn_resident() -> void:
	var r := CharacterBody3D.new()
	r.set_script(RESIDENT_SCRIPT)
	r.name = "Resident"
	add_child(r)
	# Where he stands tonight, from the residents' own stream
	var spot: Dictionary = GameState.pick("residents", [
		{"pos": Vector3(0.6, 0.05, -5.8), "yaw": 0.0},        # facing the far wall
		{"pos": Vector3(-1.3, 0.05, -1.0), "yaw": PI / 2},    # facing the photographs
		{"pos": Vector3(1.2, 0.05, -1.8), "yaw": -PI / 2},    # facing the sign-in sheets
	])
	r.global_position = HALL + spot.pos
	r.rotation.y = spot.yaw
	r.target = player
	r.bounds = _hallway_bounds
	r.spoke.connect(hud.show_message)
	r.hit_player.connect(func() -> void: player.take_hit(r.global_position))
	r.turned_hostile.connect(_on_resident_hostile)
	if GameState.flags.get("met_resident", false):
		r.start_hostile()

	_add_interactable(
		func() -> Vector3: return r.global_position,
		r.TALK_RANGE,
		func() -> String: return _resident_prompt(r),
		func() -> void: _resident_action(r))


# ---------------------------------------------------------------- audio

func _setup_audio() -> void:
	_music_dread = AudioStreamPlayer.new()
	_music_dread.stream = _make_loop([41.0, 55.0, 58.5, 110.5], [0.22, 0.32, 0.24, 0.10], 1.0 / 3.0, 0.5, 0.02)
	_music_dread.volume_db = -80.0
	add_child(_music_dread)
	_music_calm = AudioStreamPlayer.new()
	_music_calm.stream = _make_loop([110.0, 220.0, 277.0, 329.5], [0.14, 0.16, 0.10, 0.10], 0.5, 0.35, 0.0)
	_music_calm.volume_db = -80.0
	add_child(_music_calm)


## Builds a seamless 6-second drone. Frequencies are chosen to complete whole cycles in 6 s.
func _make_loop(freqs: Array, amps: Array, trem_hz: float, trem_depth: float, noise: float) -> AudioStreamWAV:
	var rate := 16000
	var n := rate * 6
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in n:
		var t := float(i) / rate
		var s := 0.0
		for k in freqs.size():
			s += amps[k] * sin(TAU * freqs[k] * t)
		s *= 1.0 - trem_depth * 0.5 * (1.0 + sin(TAU * trem_hz * t))
		s += (rng.randf() * 2.0 - 1.0) * noise
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0 * 0.6))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = n
	return w


func _set_music(room: String, seconds := 2.0) -> void:
	var safe := room == "Records Room"
	var t := create_tween().set_parallel(true)
	t.tween_property(_music_calm, "volume_db", -12.0 if safe else -80.0, seconds)
	t.tween_property(_music_dread, "volume_db", -80.0 if safe else -14.0, seconds)


# ---------------------------------------------------------------- loop

func _physics_process(delta: float) -> void:
	_ui_cd = maxf(0.0, _ui_cd - delta)
	_flicker_lights = _flicker_lights.filter(func(f) -> bool: return is_instance_valid(f.light))
	for f in _flicker_lights:
		f.t += delta
		var l: OmniLight3D = f.light
		var dip := 0.15 if fmod(f.t, 3.7) < 0.12 or fmod(f.t, 5.3) < 0.06 else 1.0
		l.light_energy = f.base * dip * (0.92 + 0.08 * sin(f.t * 23.0))
	if not _started:
		return

	if not _dead:
		GameState.night_time += delta
	_update_camera()
	_tutorial_tick(delta)

	if _busy or _dead:
		hud.set_prompt("")
		return
	if Input.is_action_just_pressed("inventory") and _ui_cd <= 0.0 and player.can_act():
		hud.set_prompt("")
		inventory_ui.open()
		return

	var best = null
	var best_d := INF
	var best_prompt := ""
	for it in interactables:
		var p: Vector3 = it.pos.call()
		var d := Vector2(player.global_position.x - p.x, player.global_position.z - p.z).length()
		if d <= it.range and d < best_d:
			var text: String = it.prompt.call()
			if text != "":
				best = it
				best_d = d
				best_prompt = text
	hud.set_prompt("" if best == null else "[{interact}] " + best_prompt)
	if best != null and _ui_cd <= 0.0 and player.can_act() and Input.is_action_just_pressed("interact"):
		_interacted = true
		best.action.call()


func _update_camera(force := false) -> void:
	if player == null:
		return
	var p := player.global_position + Vector3(0, 0.5, 0)
	for i in zones.size():
		if zones[i].box.has_point(p):
			if i != _current_zone or force:
				_current_zone = i
				(zones[i].camera as Camera3D).make_current()
				if zones[i].room != _room:
					_room = zones[i].room
					if _started:
						_on_room_entered(_room)
			return


func _on_room_entered(room: String) -> void:
	GameState.log_event("room", {"room": room})
	_set_music(room)
	match room:
		"East Hallway":
			if not GameState.flags.get("seen_hallway", false):
				GameState.flags["seen_hallway"] = true
				await get_tree().create_timer(2.2, false).timeout
				hud.show_message("Someone is standing at the end of the hall. Facing the wall.", 3.5)
		"Records Room":
			if not GameState.flags.get("seen_records", false):
				GameState.flags["seen_records"] = true
				await get_tree().create_timer(2.2, false).timeout
				hud.show_message("Warm light. A typewriter. For the first time tonight, it's quiet.", 4.0)


# ---------------------------------------------------------------- interactions

func _door_prompt(d: Dictionary) -> String:
	if d.has("key") and not GameState.world(d.flag):
		return "Use " + GameState.item_name(d.key) if GameState.has_item(d.key) else "Examine door"
	return "Open door"


func _use_door(d: Dictionary) -> void:
	if d.has("key") and not GameState.world(d.flag):
		if GameState.has_item(d.key):
			GameState.remove_item(d.key)
			GameState.remember(d.flag)  # the compound remembers: it stays unlocked for every reporter
			GameState.log_event("opened", {"what": d.label})
			hud.show_message("You used the %s. The door is unlocked." % GameState.item_name(d.key), 3.0)
		else:
			hud.show_message(d.text, 4.0)
		return
	if d.has("key") and not GameState.flags.get("through_" + d.flag, false):
		GameState.flags["through_" + d.flag] = true
		if GameState.meta.reporter > 1 and GameState.events.filter(func(e) -> bool: return e.type == "opened").is_empty():
			hud.show_message("The lock hangs open. Someone came through here before you.", 3.0)
			_busy = true
			player.frozen = true
			await get_tree().create_timer(1.5, false).timeout
	_busy = true
	player.frozen = true
	await hud.fade(1.0, 0.45).finished
	await get_tree().create_timer(0.9, false).timeout  # the long door beat
	player.global_position = d.to
	player.face(d.yaw)
	player.velocity = Vector3.ZERO
	_update_camera(true)
	await hud.fade(0.0, 0.45).finished
	hud.show_message(d.room, 2.0)
	player.frozen = false
	_busy = false


func _take(id: String, node: Node3D, entry: Dictionary) -> void:
	if GameState.LEADS.has(id):
		GameState.add_lead(id)
		GameState.flags["picked_" + id] = true
		interactables.erase(entry)
		node.queue_free()
		_read_lead(id)
		return
	if not GameState.add_item(id):
		hud.show_message("You can't carry any more.", 2.5)
		return
	GameState.flags["picked_" + id] = true
	GameState.log_event("pickup", {"id": id})
	interactables.erase(entry)
	node.queue_free()
	hud.show_message("Picked up the %s." % GameState.item_name(id), 2.5)
	if not GameState.flags.get("hint_inventory", false):
		GameState.flags["hint_inventory"] = true
		hud.flash_hint("[{inventory}] Open your items", 5.0)


func _resident_prompt(r: Node3D) -> String:
	if r.can_talk():
		return "Talk"
	var d := r.global_position.distance_to(player.global_position)
	if r.is_hostile() and d <= SHOVE_RANGE and player.shove_cd <= 0.0 and r.state != r.State.STUNNED:
		return "Shove"
	return ""


func _resident_action(r: Node3D) -> void:
	if r.can_talk():
		player.face_point(r.global_position)
		GameState.log_event("talk", {"who": "resident"})
		r.engage(true)
	elif r.is_hostile():
		GameState.log_event("shove", {})
		player.shove(r.global_position)
		r.stagger(player.global_position)
		hud.show_message("You shove him back. Go.", 1.6)


func _on_resident_hostile() -> void:
	GameState.flags["met_resident"] = true
	if not GameState.flags.get("hint_shove", false):
		GameState.flags["hint_shove"] = true
		hud.flash_hint("You can't win a fight. [{interact}] Shove to break free, then get to a door.", 7.0)


## Shows a lead you just found, then files it in the notebook.
func _read_lead(id: String) -> void:
	_busy = true
	get_tree().paused = true
	await hud.choose(GameState.item_name(id), ["Put it in your notebook"], false, GameState.lead_text(id, "desc"))
	get_tree().paused = false
	_busy = false
	_ui_cd = 0.3
	if not GameState.meta.get("hint_evidence", false):
		GameState.meta["hint_evidence"] = true
		GameState.save_meta()
		hud.flash_hint("Evidence only counts once it's sent home. Find a typewriter.", 7.0)
	else:
		hud.show_message("Noted. It isn't safe until it's sent.", 2.5)


func _cabinet_prompt() -> String:
	if GameState.world("cabinet_open"):
		return "" if GameState.flags.get("cabinet_searched", false) else "Search cabinet"
	return "Open padlock" if GameState.knows("cabinet_code") else "Examine cabinet"


func _cabinet_action() -> void:
	if not GameState.world("cabinet_open"):
		if not GameState.knows("cabinet_code"):
			hud.show_message("A filing cabinet, chained shut with a three-digit padlock. You don't know the code.", 4.0)
			return
		GameState.remember("cabinet_open")
		GameState.log_event("opened", {"what": "the records cabinet"})
		hud.show_message("You dial %s. The padlock falls open." % GameState.fact("cabinet_code"), 3.0)
		return
	GameState.flags["cabinet_searched"] = true
	if not GameState.is_sent("lead_shipping"):
		GameState.add_lead("lead_shipping")
		_read_lead("lead_shipping")
	elif GameState.add_item("bandages"):
		GameState.log_event("pickup", {"id": "bandages"})
		hud.show_message("Behind the files, a first-aid tin. You take the Bandages.", 3.0)
	else:
		hud.show_message("Only files. Nothing you can use.", 2.5)


func _save_prompt() -> void:
	_busy = true
	get_tree().paused = true
	var can_send := GameState.sendable()
	var opts := []
	if not can_send.is_empty():
		opts.append("Send evidence home (%d)" % can_send.size())
	opts.append("Pause the night")
	opts.append("Leave it")
	var sub := "Nothing to send yet." if can_send.is_empty() \
		else "What you send is safe for good. The night goes on."
	var i: int = await hud.choose("The typewriter", opts, true, sub)
	var pick: String = opts[i] if i >= 0 else "Leave it"
	if pick.begins_with("Send"):
		var text := GameState.send_leads()
		await hud.choose("Dispatch sent", ["Keep going"], false, text)
	elif pick == "Pause the night":
		var c: int = await hud.choose("Pause here and return to the title?", ["Pause", "Keep going"], true,
			"You can pick up from this spot later. It won't save you if you die.")
		if c == 0:
			GameState.save_game(player.global_position, player.rotation.y, player.health)
			get_tree().paused = false
			await hud.fade(1.0, 0.8).finished
			get_tree().reload_current_scene()
			return
	get_tree().paused = false
	_busy = false
	_ui_cd = 0.3


func _on_player_hurt(health: int) -> void:
	GameState.log_event("hurt", {"room": _room, "health": health})
	hud.flash()
	hud.show_condition(player.condition())


## The reporter is gone. There's no going back to a safe room: the night is reviewed,
## and the next reporter is sent.
func _on_player_died() -> void:
	_dead = true
	hud.set_prompt("")
	hud.set_hint("")
	var summary := GameState.end_night("caught in " + _room)
	await get_tree().create_timer(0.8).timeout
	await hud.fade(1.0, 1.6).finished
	hud.show_message("The meeting will begin without you.", 4.0)
	await get_tree().create_timer(3.5).timeout
	hud.show_message("")
	await hud.choose("POST-MORTEM", ["Send the next reporter"], false, _post_mortem_text(summary))
	GameState.pending = "night"
	get_tree().reload_current_scene()


func _post_mortem_text(s: Dictionary) -> String:
	var t := int(s.time)
	var lines := [
		"Reporter #%d went missing in the compound after %d:%02d. Last seen: %s." % [s.reporter, t / 60, t % 60, s.cause.trim_prefix("caught in ")],
		"",
		"Went well: " + ("sent %s home." % _join(s.sent) if not s.sent.is_empty() else "nothing reached the office."),
		"Went wrong: " + ("lost %s with them." % _join(s.lost) if not s.lost.is_empty() else "%d %s taken." % [s.hits, "hit" if s.hits == 1 else "hits"]),
	]
	if not s.opened.is_empty():
		lines.append("Left open for the next reporter: " + _join(s.opened) + ".")
	lines.append("")
	lines.append("Night seed %d" % s.night_seed)
	return "\n".join(lines)


func _join(items: Array) -> String:
	if items.size() <= 1:
		return "".join(items)
	return ", ".join(items.slice(0, -1)) + " and " + items[-1]


# ---------------------------------------------------------------- tutorial

func _tutorial_tick(delta: float) -> void:
	if _tut_step < 0:
		return
	_tut_t += delta
	if _tut_t < 0.0:
		return
	var done := false
	match _tut_step:
		0:
			hud.set_hint("[{move}] Walk    [{turn}] Turn")
			done = player.global_position.distance_to(_tut_from) > 1.5
		1:
			hud.set_hint("Hold [{run}] to run")
			if player.running:
				_tut_run_t += delta
			done = _tut_run_t > 0.6 or _tut_t > 10.0
		2:
			_interacted = false if _tut_t < delta * 1.5 else _interacted
			hud.set_hint("[{interact}] Open doors, talk to people, pick things up")
			done = _interacted or _tut_t > 12.0
		3:
			hud.set_hint("[{inventory}] Items    [{debug}] Performance stats")
			done = _tut_t > 6.0
	if done:
		_tut_step += 1
		_tut_t = 0.0
		if _tut_step > 3:
			_tut_step = -1
			hud.set_hint("")
			GameState.tutorial_seen = true
			GameState.meta["tutorial_done"] = true
			GameState.save_meta()
