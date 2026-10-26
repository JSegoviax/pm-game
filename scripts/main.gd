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
const STAIRS := Vector3(120, 0, 0)
const WELCOME := Vector3(0, 0, 40)
const CHAPEL := Vector3(40, 0, 40)
const INFIRMARY := Vector3(80, 0, 40)
const DORM := Vector3(120, 0, 40)

## One key opens both infirmary doors.
const INFIRMARY_LOCK := {
	"key": "key_infirmary",
	"flag": "door_infirmary_open",
	"label": "the infirmary door",
	"text": "Locked. A brass plate: INFIRMARY. STAFF ONLY. Behind it, glass clinks.",
}

var player: CharacterBody3D
var hud: CanvasLayer
var inventory_ui: Control

var zones: Array = []          # { box, camera, room }
var interactables: Array = []  # { pos: Callable, range, prompt: Callable, action: Callable }
var _flicker_lights: Array = []
var _bounds := {}               # room name -> AABB, so residents stay in their room
var residents: Array = []
var _locked_lamps: Array = []  # {flag, bulb, light}: red until the lock is open for good
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
	_build_welcome_hall()
	_build_chapel()
	_build_infirmary()
	_build_dormitory()
	_build_stairs()

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
	_blob(player, 0.45)
	player.hurt.connect(_on_player_hurt)
	player.healed.connect(func(h: int) -> void:
		GameState.log_event("healed", {"health": h})
		hud.show_condition(player.condition()))
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

	if loaded:
		Recorder.resume(self)
	else:
		Recorder.begin(self)
	_spawn_pickups()
	_spawn_residents()
	if GameState.debug.infinite_ammo:
		_debug_give_gun()
	Recorder.flush()
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
	var brief: Array = GameState.briefing()
	if brief.is_empty():
		return
	await get_tree().create_timer(4.5, false).timeout
	if _dead or _busy:
		return
	_busy = true
	get_tree().paused = true
	var who := "The last reporter never came back." if n == 2 else "%d reporters have gone in. None came back." % (n - 1)
	await hud.choose("Before you left", ["Go in"], false,
		who + " The office has what they sent:\n\n" + "\n".join(brief.slice(-8)))
	get_tree().paused = false
	_busy = false
	_ui_cd = 0.3


# ---------------------------------------------------------------- environment

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.01, 0.01, 0.015)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.40, 0.40, 0.46)
	env.ambient_light_energy = 0.6
	env.fog_enabled = true
	env.fog_light_color = Color(0.05, 0.05, 0.07)
	env.fog_density = 0.03
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
	# Floors get tiles: the lines show how far away things are and which way is level.
	var tiled := _tiles((floor_mat as StandardMaterial3D).albedo_color)
	_box(room, Vector3(size_x, 0.2, size_z), Vector3(0, -0.1, 0), tiled)
	# A dark baseboard marks where every wall meets the floor.
	var base := _mat((wall_mat as StandardMaterial3D).albedo_color * 0.35)
	var bx := size_x / 2.0 - 0.02
	var bz := size_z / 2.0 - 0.02
	_box(room, Vector3(size_x, 0.22, 0.05), Vector3(0, 0.11, -bz), base, false)
	_box(room, Vector3(size_x, 0.22, 0.05), Vector3(0, 0.11, bz), base, false)
	_box(room, Vector3(0.05, 0.22, size_z), Vector3(-bx, 0.11, 0), base, false)
	_box(room, Vector3(0.05, 0.22, size_z), Vector3(bx, 0.11, 0), base, false)
	_box(room, Vector3(size_x, 0.2, size_z), Vector3(0, WALL_H + 0.1, 0), wall_mat, false)
	var hx := size_x / 2.0
	var hz := size_z / 2.0
	_box(room, Vector3(size_x + WALL_T * 2, WALL_H, WALL_T), Vector3(0, WALL_H / 2, -hz - WALL_T / 2), wall_mat)
	_box(room, Vector3(size_x + WALL_T * 2, WALL_H, WALL_T), Vector3(0, WALL_H / 2, hz + WALL_T / 2), wall_mat)
	_box(room, Vector3(WALL_T, WALL_H, size_z), Vector3(-hx - WALL_T / 2, WALL_H / 2, 0), wall_mat)
	_box(room, Vector3(WALL_T, WALL_H, size_z), Vector3(hx + WALL_T / 2, WALL_H / 2, 0), wall_mat)
	return room


## A floor material with tiles 1 m across: grout lines a little darker, a little variation per tile.
func _tiles(color: Color) -> StandardMaterial3D:
	var px := 16
	var img := Image.create(px * 4, px * 4, false, Image.FORMAT_RGB8)
	var r := RandomNumberGenerator.new()
	r.seed = int(color.r * 1000 + color.g * 100 + color.b * 10)
	for ty in 4:
		for tx in 4:
			var shade := 0.88 + r.randf() * 0.2
			for y in px:
				for x in px:
					var c := color * shade
					if x == 0 or y == 0:
						c = color * 0.55
					c = c * (0.95 + r.randf() * 0.1)
					img.set_pixel(tx * px + x, ty * px + y, Color(c.r, c.g, c.b))
	var m := StandardMaterial3D.new()
	m.albedo_texture = ImageTexture.create_from_image(img)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.uv1_triplanar = true
	m.uv1_scale = Vector3(0.25, 0.25, 0.25)  # 4 tiles per texture -> 1 m tiles
	m.roughness = 1.0
	return m


## A soft dark disc on the floor. Under people and things, it shows where they touch the ground.
var _shadow_mat: StandardMaterial3D

func _blob(parent: Node3D, radius: float) -> MeshInstance3D:
	if _shadow_mat == null:
		var g := Gradient.new()
		g.set_color(0, Color(0, 0, 0, 0.7))
		g.set_color(1, Color(0, 0, 0, 0))
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		t.width = 32
		t.height = 32
		_shadow_mat = StandardMaterial3D.new()
		_shadow_mat.albedo_texture = t
		_shadow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_shadow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_shadow_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := MeshInstance3D.new()
	var q := PlaneMesh.new()
	q.size = Vector2(radius * 2, radius * 2)
	mi.mesh = q
	mi.material_override = _shadow_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position.y = 0.02
	mi.top_level = false
	parent.add_child(mi)
	return mi


## Furniture that reads as what it is.
func _table(parent: Node3D, pos: Vector3, size: Vector3, mat: Material) -> void:
	_box(parent, Vector3(size.x, 0.08, size.z), pos + Vector3(0, size.y - 0.04, 0), mat)
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			_box(parent, Vector3(0.08, size.y - 0.08, 0.08), pos + Vector3(sx * (size.x / 2 - 0.08), (size.y - 0.08) / 2, sz * (size.z / 2 - 0.08)), mat, false)
	# Collide as one block so you can't walk under it
	var body := StaticBody3D.new()
	body.position = pos + Vector3(0, size.y / 2, 0)
	parent.add_child(body)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)


func _chair(parent: Node3D, pos: Vector3, yaw: float, mat: Material, tipped := false) -> void:
	var c := Node3D.new()
	c.position = pos
	c.rotation.y = yaw
	if tipped:
		c.rotation.z = 1.45
		c.position.y += 0.25
	parent.add_child(c)
	_box(c, Vector3(0.45, 0.06, 0.45), Vector3(0, 0.45, 0), mat, false)
	_box(c, Vector3(0.45, 0.5, 0.06), Vector3(0, 0.72, 0.2), mat, false)
	for sx in [-0.18, 0.18]:
		for sz in [-0.18, 0.18]:
			_box(c, Vector3(0.05, 0.45, 0.05), Vector3(sx, 0.22, sz), mat, false)
	var body := StaticBody3D.new()
	c.add_child(body)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.45, 0.9, 0.45)
	cs.shape = shape
	cs.position.y = 0.45
	body.add_child(cs)


## A bed (or bunk, with `bunk`): frame, legs, mattress and pillow. Long side along z.
func _bed(parent: Node3D, pos: Vector3, frame: Material, sheet: Material, bunk := false) -> void:
	var pillow := _mat(Color(0.85, 0.84, 0.80))
	var levels := [0.45, 1.55] if bunk else [0.45]
	for y in levels:
		_box(parent, Vector3(0.95, 0.08, 2.0), pos + Vector3(0, y - 0.1, 0), frame, false)
		_box(parent, Vector3(0.88, 0.14, 1.9), pos + Vector3(0, y + 0.01, 0), sheet, false)
		_box(parent, Vector3(0.6, 0.1, 0.32), pos + Vector3(0, y + 0.12, -0.75), pillow, false)
	var top: float = levels[-1] + 0.35
	for sx in [-0.44, 0.44]:
		for sz in [-0.96, 0.96]:
			_box(parent, Vector3(0.06, top, 0.06), pos + Vector3(sx, top / 2, sz), frame, false)
	var body := StaticBody3D.new()
	body.position = pos + Vector3(0, 0.3, 0)
	parent.add_child(body)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.95, 0.6, 2.0)
	cs.shape = shape
	body.add_child(cs)


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
	# Which way the door faces into the room
	var inward := Vector3(-signf(local_pos.x), 0, 0) if side_wall else Vector3(0, 0, -signf(local_pos.z))
	var door := Node3D.new()
	add_child(door)
	door.global_position = p
	door.rotation.y = PI / 2 if side_wall else 0.0
	var local_in := door.global_transform.basis.inverse() * inward
	var wood := _mat(Color(0.42, 0.24, 0.13))
	var trim := _mat(Color(0.62, 0.52, 0.38))
	var dark := _mat(Color(0.25, 0.14, 0.08))
	# Frame
	_box(door, Vector3(0.14, 2.6, 0.2), Vector3(-0.72, 1.3, 0), trim, false)
	_box(door, Vector3(0.14, 2.6, 0.2), Vector3(0.72, 1.3, 0), trim, false)
	_box(door, Vector3(1.58, 0.16, 0.2), Vector3(0, 2.62, 0), trim, false)
	# Door with two raised panels
	_box(door, Vector3(1.3, 2.5, 0.08), Vector3(0, 1.25, 0), wood, false)
	for y in [0.75, 1.75]:
		_box(door, Vector3(0.9, 0.7, 0.1), Vector3(0, y, 0), dark, false)
	# Handle on the room side
	_box(door, Vector3(0.1, 0.06, 0.1), Vector3(0.45, 1.05, 0) + local_in * 0.08, _mat(Color(0.85, 0.70, 0.32)), false)
	# A small lamp above every door, so exits can always be found
	var lamp_pos := Vector3(0, 2.95, 0) + local_in * 0.15
	var bulb := _mat(Color(1.0, 0.85, 0.6))
	bulb.emission_enabled = true
	bulb.emission = Color(1.0, 0.75, 0.45)
	_box(door, Vector3(0.22, 0.12, 0.12), lamp_pos, bulb, false)
	var l := OmniLight3D.new()
	l.position = lamp_pos + local_in * 0.3 - Vector3(0, 0.2, 0)
	l.light_color = Color(1.0, 0.8, 0.55)
	l.light_energy = 0.9
	l.omni_range = 3.2
	door.add_child(l)
	# Locked doors get a red lamp until they're open for good
	if lock.has("flag"):
		_locked_lamps.append({"flag": str(lock.flag), "bulb": bulb, "light": l})

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
	var item := id.get_slice("#", 0)   # "rounds#1" is a second copy of "rounds"
	var is_lead := GameState.LEADS.has(item)
	var kind: String = "lead" if is_lead else GameState.ITEMS[item].kind
	var node := Node3D.new()
	add_child(node)
	node.global_position = pos
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	match kind:
		"key": mesh.size = Vector3(0.14, 0.05, 0.08)
		"lead": mesh.size = Vector3(0.22, 0.01, 0.28)
		"melee": mesh.size = Vector3(0.7, 0.06, 0.08)
		"gun": mesh.size = Vector3(0.28, 0.08, 0.12)
		_: mesh.size = Vector3(0.16, 0.12, 0.16)
	mi.mesh = mesh
	if kind == "lead":
		mi.rotation.y = GameState.rng("dressing").randf() * TAU
	var m := StandardMaterial3D.new()
	match kind:
		"key": m.albedo_color = Color(0.85, 0.68, 0.25)
		"lead": m.albedo_color = Color(0.86, 0.80, 0.64)
		"melee": m.albedo_color = Color(0.55, 0.15, 0.12) if item == "fire_axe" else Color(0.50, 0.52, 0.55)
		"gun": m.albedo_color = Color(0.25, 0.25, 0.27)
		"ammo": m.albedo_color = Color(0.80, 0.62, 0.30)
		"finisher": m.albedo_color = Color(0.45, 0.55, 0.30)
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
	if pos.y > 0.2:
		pass  # on furniture: the furniture's own shape is enough
	else:
		_blob(node, 0.3).position.y = -0.03
	_flicker_lights.append({"light": glint, "base": 0.4, "t": randf() * 10.0})

	var entry := _add_interactable(
		func() -> Vector3: return pos,
		1.5,
		func() -> String: return "Read" if is_lead else "Pick up",
		Callable())
	entry.action = func() -> void: _take(id, node, entry)
	if kind == "melee":
		mi.rotation.y = GameState.rng("dressing").randf() * TAU


# ---------------------------------------------------------------- rooms

func _build_foyer() -> void:
	var foyer := _room_shell("Foyer", FOYER, 12.0, 10.0, _mat(Color(0.30, 0.26, 0.22), true), _mat(Color(0.42, 0.40, 0.36), true))
	var wood := _mat(Color(0.26, 0.16, 0.10))
	var stone := _mat(Color(0.50, 0.48, 0.44), true)
	for x in [-3.0, 3.0]:
		_box(foyer, Vector3(0.6, WALL_H, 0.6), Vector3(x, WALL_H / 2, -1.0), stone)
	# Meeting table with chairs pushed back in a hurry
	_table(foyer, Vector3(0, 0, -2.6), Vector3(3.2, 0.9, 1.1), wood)
	_chair(foyer, Vector3(-1.2, 0, -1.6), PI + 0.5, wood)
	_chair(foyer, Vector3(1.4, 0, -3.7), -0.3, wood)
	_chair(foyer, Vector3(2.2, 0, -1.2), PI, wood, true)
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
	_door(foyer, Vector3(-5.94, 0, -2.5), WELCOME + Vector3(4.0, 0.05, 2.0), PI / 2, "Welcome Hall")


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
	_bounds["East Hallway"] = AABB(HALL + Vector3(-2, -1, -8), Vector3(4, 5, 16))

	_door(hall, Vector3(0, 0, 7.94), FOYER + Vector3(3.5, 0.05, -3.9), PI, "Foyer")
	_door(hall, Vector3(-1.94, 0, 5.2), DORM + Vector3(3.0, 0.05, 2.9), 0.0, "Dormitory")
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
	_table(room, Vector3(-1.6, 0, -2.2), Vector3(1.6, 0.8, 0.8), wood)
	_chair(room, Vector3(-1.6, 0, -1.4), 0.2, wood)
	_box(room, Vector3(0.5, 0.18, 0.4), Vector3(-1.6, 0.89, -2.2), _mat(Color(0.10, 0.10, 0.11)), false)
	_box(room, Vector3(0.28, 0.02, 0.2), Vector3(-1.6, 1.06, -2.32), _mat(Color(0.92, 0.9, 0.84)), false).rotation.x = -0.9
	# Filing shelves and a cot
	_box(room, Vector3(0.5, 2.2, 2.2), Vector3(2.7, 1.1, -1.5), wood)
	_bed(room, Vector3(2.4, 0, 1.6), _mat(Color(0.30, 0.30, 0.32)), _mat(Color(0.45, 0.42, 0.36)))

	_light(room, Vector3(-1.4, 2.0, -1.6), Color(1.0, 0.76, 0.45), 1.7, 7.0)
	_light(room, Vector3(1.5, 3.2, 1.5), Color(1.0, 0.85, 0.65), 0.6, 6.0)

	var cam_a := _camera(room, Vector3(2.6, 3.2, 2.6), Vector3(-1.2, 0.6, -1.6), 60.0)
	var cam_b := _camera(room, Vector3(-2.6, 3.2, -2.6), Vector3(1.0, 0.5, 1.6), 60.0)
	_zone(room, "Records Room", Vector3(-3, -1, -3), Vector3(3, 4, 0), cam_a)
	_zone(room, "Records Room", Vector3(-3, -1, 0), Vector3(3, 4, 3), cam_b)

	_door(room, Vector3(0, 0, 2.94), HALL + Vector3(0, 0.05, -7.0), PI, "East Hallway")
	_door(room, Vector3(-2.94, 0, 1.0), STAIRS + Vector3(0, 0.05, 2.8), 0.0, "Basement Stairs")
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


## The benefactors' entrance. The wealthy members come in here, not through the foyer.
func _build_welcome_hall() -> void:
	var room := _room_shell("WelcomeHall", WELCOME, 10.0, 12.0, _mat(Color(0.22, 0.05, 0.06), true), _mat(Color(0.36, 0.30, 0.24), true))
	var gold := _mat(Color(0.85, 0.66, 0.24))
	gold.emission_enabled = true
	gold.emission = Color(0.25, 0.18, 0.05)
	var leather := _mat(Color(0.30, 0.08, 0.06))
	var wood := _mat(Color(0.20, 0.11, 0.07))
	# Red runner to the chapel doors, gold-edged
	_box(room, Vector3(2.0, 0.02, 11.6), Vector3(0, 0.01, 0), _mat(Color(0.45, 0.06, 0.07)), false)
	for x in [-1.05, 1.05]:
		_box(room, Vector3(0.08, 0.025, 11.6), Vector3(x, 0.012, 0), gold, false)
	# Leather armchairs around a low table
	for c in [Vector3(-3.0, 0, 0.6), Vector3(-3.0, 0, -1.6), Vector3(-1.9, 0, -0.5)]:
		_box(room, Vector3(0.9, 0.9, 0.9), c + Vector3(0, 0.45, 0), leather)
	_table(room, Vector3(-3.0, 0, -0.5), Vector3(0.9, 0.4, 1.4), wood)
	# The donor wall: plaques by tier
	for row in 3:
		for i in 5 - row:
			_box(room, Vector3(0.06, 0.24 - row * 0.04, 0.5 - row * 0.08), Vector3(-4.95, 2.6 - row * 0.5, -3.2 + i * 0.9 + row * 0.4), gold, false)
	# The founder's portrait over the chapel doors
	_box(room, Vector3(1.6, 2.0, 0.08), Vector3(0, 2.6, -5.9), gold, false)
	_box(room, Vector3(1.3, 1.7, 0.1), Vector3(0, 2.6, -5.88), _mat(Color(0.12, 0.10, 0.09)), false)
	# Velvet rope posts and a check-in lectern
	for x in [-1.6, 1.6]:
		_box(room, Vector3(0.12, 1.0, 0.12), Vector3(x, 0.5, -4.2), gold, false)
	_box(room, Vector3(0.7, 1.1, 0.5), Vector3(3.0, 0.55, 3.5), wood)

	_light(room, Vector3(0, 3.6, 0), Color(1.0, 0.82, 0.5), 2.0, 10.0)
	_light(room, Vector3(-4.0, 2.2, -2.0), Color(1.0, 0.75, 0.45), 1.0, 5.0, true)

	var cam_a := _camera(room, Vector3(4.4, 3.6, 5.4), Vector3(-1.5, 0.5, -1.5))
	var cam_b := _camera(room, Vector3(-4.4, 3.5, -5.4), Vector3(1.0, 0.6, 2.5))
	_zone(room, "Welcome Hall", Vector3(-5, -1, -1), Vector3(5, 4, 6), cam_a)
	_zone(room, "Welcome Hall", Vector3(-5, -1, -6), Vector3(5, 4, -1), cam_b)
	_bounds["Welcome Hall"] = AABB(WELCOME + Vector3(-5, -1, -6), Vector3(10, 5, 12))

	_door(room, Vector3(4.94, 0, 2.0), FOYER + Vector3(-5.0, 0.05, -2.5), -PI / 2, "Foyer")
	_door(room, Vector3(0, 0, -5.94), CHAPEL + Vector3(0, 0.05, 6.8), 0.0, "Chapel")


## Where the Quiet Hour is held. The front pews are roped off for the benefactors.
func _build_chapel() -> void:
	var room := _room_shell("Chapel", CHAPEL, 10.0, 16.0, _mat(Color(0.26, 0.24, 0.22), true), _mat(Color(0.30, 0.27, 0.26), true))
	var wood := _mat(Color(0.20, 0.12, 0.08))
	var velvet := _mat(Color(0.40, 0.05, 0.08))
	var gold := _mat(Color(0.85, 0.66, 0.24))
	# Pews either side of the aisle; the first two rows are padded velvet
	for i in 6:
		var z := -2.5 + i * 1.6
		var m: Material = velvet if i < 2 else wood
		for x in [-2.6, 2.6]:
			_box(room, Vector3(3.2, 0.5, 0.5), Vector3(x, 0.25, z), m)
			_box(room, Vector3(3.2, 0.6, 0.1), Vector3(x, 0.8, z + 0.25), m, false)
	_box(room, Vector3(8.0, 0.06, 0.06), Vector3(0, 0.9, -0.6), gold, false)  # the rope
	# Altar and the sigil
	_box(room, Vector3(3.0, 1.0, 1.0), Vector3(0, 0.5, -6.3), _mat(Color(0.75, 0.73, 0.68), true))
	var sigil := MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 1.0
	ring.outer_radius = 1.25
	ring.rings = 16
	ring.ring_segments = 6
	sigil.mesh = ring
	sigil.material_override = _mat(Color(0.55, 0.05, 0.04))
	room.add_child(sigil)
	sigil.position = Vector3(0, 2.7, -7.85)
	sigil.rotation.x = PI / 2
	# Speakers high on the walls: the founder's voice during the Quiet Hour
	for z in [-5.0, 0.0, 5.0]:
		for x in [-4.8, 4.8]:
			_box(room, Vector3(0.3, 0.45, 0.35), Vector3(x, 3.3, z), _mat(Color(0.08, 0.08, 0.08)), false)
	# Candles on the altar
	for x in [-1.1, -0.4, 0.4, 1.1]:
		_box(room, Vector3(0.07, 0.3, 0.07), Vector3(x, 1.15, -6.4), _mat(Color(0.95, 0.92, 0.85)), false)
	_light(room, Vector3(0, 1.7, -6.0), Color(1.0, 0.6, 0.3), 1.6, 7.0, true)
	_light(room, Vector3(0, 3.6, 3.0), Color(0.75, 0.35, 0.35), 0.8, 9.0)

	var cam_a := _camera(room, Vector3(4.4, 3.7, 7.6), Vector3(-1.0, 0.4, -2.0), 52.0)
	var cam_b := _camera(room, Vector3(-4.4, 3.6, -7.6), Vector3(1.0, 0.6, 3.0), 55.0)
	_zone(room, "Chapel", Vector3(-5, -1, -1), Vector3(5, 4, 8), cam_a)
	_zone(room, "Chapel", Vector3(-5, -1, -8), Vector3(5, 4, -1), cam_b)
	_bounds["Chapel"] = AABB(CHAPEL + Vector3(-5, -1, -8), Vector3(10, 5, 16))

	_door(room, Vector3(0, 0, 7.94), WELCOME + Vector3(0, 0.05, -5.0), PI, "Welcome Hall")
	_door(room, Vector3(4.94, 0, -4.0), INFIRMARY + Vector3(-3.2, 0.05, 0.0), -PI / 2, "Infirmary", INFIRMARY_LOCK)


## Where the tonic is made and given.
func _build_infirmary() -> void:
	var room := _room_shell("Infirmary", INFIRMARY, 8.0, 8.0, _mat(Color(0.58, 0.60, 0.58), true), _mat(Color(0.52, 0.58, 0.54), true))
	var steel := _mat(Color(0.55, 0.56, 0.58))
	var sheet := _mat(Color(0.82, 0.84, 0.82))
	# Beds along the north wall
	for x in [-2.6, -0.4, 1.8]:
		_bed(room, Vector3(x, 0, -2.8), steel, sheet)
		_box(room, Vector3(0.05, 1.8, 0.05), Vector3(x + 0.7, 0.9, -2.0), steel, false)  # drip stand
	# The bottling table: rows of green tonic
	_table(room, Vector3(0, 0, 0.6), Vector3(2.6, 0.9, 1.0), steel)
	var tonic := _mat(Color(0.25, 0.75, 0.35))
	tonic.emission_enabled = true
	tonic.emission = Color(0.08, 0.35, 0.12)
	for i in 10:
		_box(room, Vector3(0.08, 0.2, 0.08), Vector3(-1.1 + i * 0.24, 1.0, 0.45 + (i % 2) * 0.25), tonic, false)
	# Crates stacked by the dormitory door
	for c in [Vector3(2.8, 0.3, 3.0), Vector3(2.0, 0.3, 3.2), Vector3(2.5, 0.9, 3.1)]:
		_box(room, Vector3(0.7, 0.6, 0.6), c, _mat(Color(0.42, 0.32, 0.20)))
	_light(room, Vector3(0, 3.3, 0), Color(0.8, 1.0, 0.85), 1.2, 8.0, true)
	_light(room, Vector3(0, 1.4, 0.6), Color(0.35, 1.0, 0.45), 0.6, 3.0)

	var cam_a := _camera(room, Vector3(3.6, 3.4, 3.6), Vector3(-1.2, 0.5, -1.2), 62.0)
	var cam_b := _camera(room, Vector3(-3.6, 3.4, -3.6), Vector3(1.2, 0.5, 1.4), 62.0)
	_zone(room, "Infirmary", Vector3(-4, -1, 0), Vector3(4, 4, 4), cam_b)
	_zone(room, "Infirmary", Vector3(-4, -1, -4), Vector3(4, 4, 0), cam_a)
	_bounds["Infirmary"] = AABB(INFIRMARY + Vector3(-4, -1, -4), Vector3(8, 5, 8))

	_door(room, Vector3(-3.94, 0, 0), CHAPEL + Vector3(4.2, 0.05, -4.0), PI / 2, "Chapel", INFIRMARY_LOCK)
	_door(room, Vector3(3.94, 0, 1.6), DORM + Vector3(-5.0, 0.05, -2.0), -PI / 2, "Dormitory", INFIRMARY_LOCK)


## The members' bunks. Most of them are asleep. Most of them.
func _build_dormitory() -> void:
	var room := _room_shell("Dormitory", DORM, 12.0, 8.0, _mat(Color(0.24, 0.20, 0.16), true), _mat(Color(0.32, 0.30, 0.27), true))
	var frame := _mat(Color(0.30, 0.30, 0.32))
	var blanket := _mat(Color(0.36, 0.34, 0.28))
	for x in [-4.0, -1.8, 0.4, 2.6]:
		for z in [-2.6, 0.6]:
			_bed(room, Vector3(x, 0, z), frame, blanket, true)
	# Lockers along the south wall
	for i in 6:
		_box(room, Vector3(0.6, 1.9, 0.5), Vector3(-5.0 + i * 0.65, 0.95, 3.7), _mat(Color(0.28, 0.33, 0.30)))
	_light(room, Vector3(0, 3.0, -1.0), Color(1.0, 0.85, 0.6), 0.9, 7.0, true)

	var cam_a := _camera(room, Vector3(5.6, 3.4, 3.6), Vector3(-2.0, 0.4, -1.0), 60.0)
	var cam_b := _camera(room, Vector3(-5.6, 3.4, -3.6), Vector3(2.0, 0.4, 1.0), 60.0)
	_zone(room, "Dormitory", Vector3(-1, -1, -4), Vector3(6, 4, 4), cam_b)
	_zone(room, "Dormitory", Vector3(-6, -1, -4), Vector3(-1, 4, 4), cam_a)
	_bounds["Dormitory"] = AABB(DORM + Vector3(-6, -1, -4), Vector3(12, 5, 8))

	_door(room, Vector3(3.0, 0, 3.94), HALL + Vector3(-1.2, 0.05, 5.2), -PI / 2, "East Hallway")
	_door(room, Vector3(-5.94, 0, -2.0), INFIRMARY + Vector3(3.2, 0.05, 1.6), PI / 2, "Infirmary", INFIRMARY_LOCK)


## Off the Records Room: stairs down to a chained gate. Someone is singing below.
func _build_stairs() -> void:
	var room := Node3D.new()
	room.name = "BasementStairs"
	room.position = STAIRS
	add_child(room)
	var stone := _mat(Color(0.30, 0.29, 0.27), true)
	var dark := _mat(Color(0.18, 0.17, 0.16), true)
	# Landing at the top, a ramp down (with step shapes on it), and the bottom landing
	_box(room, Vector3(4.0, 0.2, 4.0), Vector3(0, -0.1, 2.0), stone)
	var ramp := _box(room, Vector3(4.0, 0.2, 4.6), Vector3(0, -1.25, -1.9), stone)
	ramp.rotation.x = -atan2(2.4, 4.0)
	for i in 8:
		_box(room, Vector3(3.9, 0.3, 0.5), Vector3(0, -0.15 - i * 0.3, -0.25 - i * 0.5), dark, false)
	_box(room, Vector3(4.0, 0.2, 2.6), Vector3(0, -2.5, -5.3), stone)
	# Walls and ceiling
	for x in [-2.15, 2.15]:
		_box(room, Vector3(0.3, 7.0, 13.0), Vector3(x, 0.8, -2.0), stone)
	_box(room, Vector3(4.6, 7.0, 0.3), Vector3(0, 0.8, 4.15), stone)
	_box(room, Vector3(4.6, 7.0, 0.3), Vector3(0, 0.8, -6.75), stone)
	_box(room, Vector3(4.6, 0.2, 13.0), Vector3(0, 4.1, -2.0), stone, false)
	# The gate: bars and a new chain
	for i in 9:
		_box(room, Vector3(0.06, 2.6, 0.06), Vector3(-1.6 + i * 0.4, -1.1, -6.0), _mat(Color(0.20, 0.20, 0.22)))
	_box(room, Vector3(0.5, 0.5, 0.1), Vector3(0, -1.2, -5.94), _mat(Color(0.65, 0.65, 0.68)), false)
	_light(room, Vector3(0, 3.0, 2.5), Color(1.0, 0.8, 0.55), 1.3, 7.0, true)
	_light(room, Vector3(0, 0.6, -2.0), Color(1.0, 0.75, 0.5), 0.7, 5.0)
	_light(room, Vector3(0, -1.0, -6.5), Color(0.9, 0.3, 0.2), 0.5, 4.0)

	# From beside the gate, looking up the stairs at whoever comes down
	var cam := _camera(room, Vector3(1.6, -0.6, -6.3), Vector3(-0.3, 0.4, 2.5), 62.0)
	_zone(room, "Basement Stairs", Vector3(-2, -3.5, -6.6), Vector3(2, 4, 4), cam)
	_bounds["Basement Stairs"] = AABB(STAIRS + Vector3(-2, -3.5, -6.6), Vector3(4, 7.5, 10.6))

	_door(room, Vector3(0, 0, 3.94), RECORDS + Vector3(-2.2, 0.05, 1.0), -PI / 2, "Records Room")
	_add_interactable(
		func() -> Vector3: return STAIRS + Vector3(0, -2.4, -5.5),
		1.6,
		func() -> String: return "Examine gate",
		func() -> void: hud.show_message("A chain as thick as your wrist, and new. Somewhere below, a choir is singing. One voice is much older than the others.", 5.0))


## Marked spots, Rogue Legacy style: rooms are hand-built and always the same; what sits on
## these spots changes every night. `needs` lists the locked doors between the front door and
## the spot, so keys can always be placed where they can be reached: every night is finishable.
const LOCK_RECORDS := "door_records_open"
const LOCK_INFIRMARY := "door_infirmary_open"
const MARKERS := [
	{"id": "foyer_desk", "pos": FOYER + Vector3(-4.2, 1.05, 3.0), "needs": []},
	{"id": "foyer_table", "pos": FOYER + Vector3(0.8, 0.93, -2.6), "needs": []},
	{"id": "foyer_floor", "pos": FOYER + Vector3(4.6, 0.06, 1.5), "needs": []},
	{"id": "hall_bench_n", "pos": HALL + Vector3(1.55, 0.53, -3.5), "needs": []},
	{"id": "hall_bench_s", "pos": HALL + Vector3(-1.55, 0.53, 2.6), "needs": []},
	{"id": "welcome_lectern", "pos": WELCOME + Vector3(3.0, 1.13, 3.5), "needs": []},
	{"id": "welcome_table", "pos": WELCOME + Vector3(-3.0, 0.43, -0.5), "needs": []},
	{"id": "welcome_floor", "pos": WELCOME + Vector3(3.8, 0.06, -4.6), "needs": []},
	{"id": "chapel_altar", "pos": CHAPEL + Vector3(0.9, 1.03, -6.2), "needs": []},
	{"id": "chapel_pew", "pos": CHAPEL + Vector3(-3.2, 0.53, 2.3), "needs": []},
	{"id": "dorm_locker", "pos": DORM + Vector3(-1.2, 0.06, 3.1), "needs": []},
	{"id": "dorm_bunk", "pos": DORM + Vector3(2.6, 1.56, -2.6), "needs": []},
	{"id": "records_desk", "pos": RECORDS + Vector3(-1.0, 0.83, -2.1), "needs": [LOCK_RECORDS]},
	{"id": "records_cot", "pos": RECORDS + Vector3(2.4, 0.43, 1.4), "needs": [LOCK_RECORDS]},
	{"id": "stairs_landing", "pos": STAIRS + Vector3(1.2, -2.34, -5.0), "needs": [LOCK_RECORDS]},
	{"id": "infirmary_table", "pos": INFIRMARY + Vector3(0.9, 0.93, 0.6), "needs": [LOCK_INFIRMARY]},
	{"id": "infirmary_bed", "pos": INFIRMARY + Vector3(-2.6, 0.63, -2.8), "needs": [LOCK_INFIRMARY]},
	{"id": "infirmary_crates", "pos": INFIRMARY + Vector3(2.5, 1.23, 3.1), "needs": [LOCK_INFIRMARY]},
]


func _spawn_pickups() -> void:
	var free := MARKERS.duplicate()
	var r := GameState.rng("items")
	# Everything is always drawn in the same order, including chances and things that won't
	# appear, so a resumed night rebuilds exactly as it was.
	var place := func(id: String, ok: Callable, show: bool) -> void:
		var pool := free.filter(ok)
		var m = GameState.pick("items", pool)
		if m == null:
			return
		free.erase(m)
		if show:
			_pickup(id, m.pos)
			Recorder.placed[id] = m.id
	var anywhere := func(_m) -> bool: return true
	var no_locks := func(m) -> bool: return m.needs.is_empty()
	var not_behind := func(lock: String) -> Callable:
		return func(m) -> bool: return not m.needs.has(lock)
	var only_behind := func(lock: String) -> Callable:
		return func(m) -> bool: return m.needs.has(lock)
	var chance := func(p: float) -> bool: return r.randf() < p

	# Keys first: the Records key outside every lock; the infirmary key outside the infirmary.
	# Once a door is open for good, its key isn't needed (or placed).
	place.call("key_east", no_locks, not GameState.world(LOCK_RECORDS))
	place.call("key_infirmary", not_behind.call(LOCK_INFIRMARY), not GameState.world(LOCK_INFIRMARY))
	# The most constrained things go next, while their spots are still free.
	place.call("lead_batch", only_behind.call(LOCK_INFIRMARY), not GameState.is_sent("lead_batch") or GameState.flags.get("picked_lead_batch", false))
	# Something to fight with is always within reach; the rest is luck.
	place.call("pipe", no_locks, true)
	var axe: bool = chance.call(0.5)
	var gun: bool = chance.call(0.35)
	var rounds: int = (1 + int(chance.call(0.5))) if gun else int(chance.call(0.25))
	var extra_oil: bool = chance.call(0.35)
	place.call("fire_axe", anywhere, axe)
	place.call("revolver", anywhere, gun)
	for i in 2:
		place.call("rounds#%d" % i, anywhere, i < rounds)
	place.call("lamp_oil", anywhere, true)
	place.call("lamp_oil#2", anywhere, extra_oil)
	place.call("bandages", anywhere, true)
	# Evidence the office doesn't have yet. Sent leads don't come back.
	var leads := [
		["lead_code", anywhere],
		["lead_ledger", anywhere],
		["lead_benefactors", anywhere],
		["lead_reel", anywhere],
	]
	for l in leads:
		var id: String = l[0]
		place.call(id, l[1], not GameState.is_sent(id) or GameState.flags.get("picked_" + id, false))


## Who is where tonight. Each room has a few spots and a chance; the hallway always has someone.
const CAST := [
	{"id": "hall", "kind": "member", "room": "East Hallway", "chance": 1.0, "threshold": 1, "turn": "He stops smiling.", "spots": [
		[HALL + Vector3(0.6, 0.05, -5.8), 0.0], [HALL + Vector3(-1.3, 0.05, -1.0), PI / 2], [HALL + Vector3(1.2, 0.05, -1.8), -PI / 2]]},
	{"id": "benefactor", "kind": "benefactor", "room": "Welcome Hall", "chance": 0.6, "threshold": 99, "turn": "", "spots": [
		[WELCOME + Vector3(0.0, 0.05, -3.4), PI], [WELCOME + Vector3(-3.6, 0.05, -2.8), PI / 2]]},
	{"id": "chapel", "kind": "worshipper", "room": "Chapel", "chance": 0.7, "threshold": 2, "turn": "She stops counting.", "spots": [
		[CHAPEL + Vector3(0.0, 0.05, -5.0), 0.0], [CHAPEL + Vector3(-0.6, 0.05, -1.4), 0.0]]},
	{"id": "nurse", "kind": "nurse", "room": "Infirmary", "chance": 0.7, "threshold": 2, "turn": "\"It's time for your dose.\"", "spots": [
		[INFIRMARY + Vector3(0.0, 0.05, -0.4), 0.0], [INFIRMARY + Vector3(-1.5, 0.05, -1.6), PI]]},
	{"id": "sleeper_a", "kind": "sleeper", "room": "Dormitory", "chance": 1.0, "threshold": 1, "turn": "He swings his legs off the bunk.", "spots": [
		[DORM + Vector3(-1.8, 0.05, -2.6), 0.0], [DORM + Vector3(0.4, 0.05, 0.6), 0.0]]},
	{"id": "sleeper_b", "kind": "sleeper", "room": "Dormitory", "chance": 0.5, "threshold": 1, "turn": "Someone in the bunks sits up.", "spots": [
		[DORM + Vector3(-4.0, 0.05, 0.6), 0.0], [DORM + Vector3(2.6, 0.05, 0.6), 0.0]]},
]

const TALK := {
	"member": {
		"notice": ["\"Visiting hours ended at eleven. Everyone's downstairs for the meeting.\"", "He keeps smiling. He hasn't blinked once."],
		"talk": ["\"Excuse me. I'm with the Courier. I'm looking for whoever's in charge.\"", "He turns around slowly. \"Everyone is in charge. Everyone is downstairs.\"", "\"You should be downstairs too. Don't go into the Records Room.\" He hasn't blinked once."],
	},
	"benefactor": {
		"notice": [],
		"talk": ["\"You're not a member. You're certainly not one of us.\" He straightens a gold pin.", "\"We don't take the general tonic, you understand. Ours is drawn by hand.\"", "\"The Founder dines with us on Sundays. He's looking wonderfully well.\""],
	},
	"worshipper": {
		"notice": ["She's kneeling toward the altar, whispering a count. She doesn't stop.", "\"It's nearly the Quiet Hour. You should kneel.\""],
		"talk": ["\"Excuse me. Who's in charge here?\"", "\"He is.\" She points at the speakers without looking up. \"He'll speak soon.\"", "\"You should kneel.\" She's standing now."],
	},
	"nurse": {
		"notice": ["\"Visiting hours are over. Are you here for your dose?\"", "She's already filling a syringe. It's green."],
		"talk": ["\"I'm not a patient. I'm a reporter.\"", "\"Everyone's a patient.\" She taps the syringe. \"Sleeve up.\""],
	},
	"sleeper": {"notice": [], "talk": []},
}


func _spawn_residents() -> void:
	var r := GameState.rng("residents")
	for c in CAST:
		var here: bool = r.randf() < float(c.chance)
		var spot: Array = GameState.pick("residents", c.spots)
		if not here:
			continue
		_spawn_resident(c, spot[0], spot[1])


func _spawn_resident(c: Dictionary, pos: Vector3, yaw: float) -> void:
	var r := CharacterBody3D.new()
	r.set_script(RESIDENT_SCRIPT)
	r.name = "Resident_" + c.id
	r.kind = c.kind
	r.resident_id = c.id
	r.threshold = int(c.threshold)
	r.turn_line = c.turn
	r.lines = PackedStringArray(TALK[c.kind].notice)
	r.talk_lines = PackedStringArray(TALK[c.kind].talk)
	add_child(r)
	_blob(r, 0.5)
	r.add_to_group("residents")
	residents.append(r)
	r.global_position = pos
	r.rotation.y = yaw
	Recorder.placed["resident_" + c.id] = "%s (%.1f, %.1f)" % [c.room, pos.x, pos.z]
	r.target = player
	r.bounds = _bounds[c.room]
	r.spoke.connect(hud.show_message)
	r.hit_player.connect(func() -> void: player.take_hit(r.global_position))
	r.turned_hostile.connect(func() -> void: _on_resident_hostile(r))
	r.went_down.connect(func() -> void: _on_resident_down(r))
	r.rose.connect(func() -> void:
		GameState.log_event("resident_rose", {"who": r.resident_id})
		if _room == c.room:
			hud.show_message("He's getting up.", 2.0))
	var dead: String = str(GameState.flags.get("dead_" + c.id, ""))
	if dead != "":
		r.start_dead(dead)
	elif GameState.flags.get("met_" + c.id, false):
		r.start_hostile()
	elif c.kind == "sleeper":
		r.start_asleep()

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
	for lamp in _locked_lamps:
		var open := GameState.world(lamp.flag)
		var c := Color(1.0, 0.8, 0.55) if open else Color(1.0, 0.25, 0.18)
		(lamp.light as OmniLight3D).light_color = c
		(lamp.bulb as StandardMaterial3D).emission = c * 0.8
		(lamp.bulb as StandardMaterial3D).albedo_color = c
	if not _started:
		return

	if not _dead:
		GameState.night_time += delta
	_update_camera()
	_tutorial_tick(delta)

	if _busy or _dead:
		hud.set_prompt("")
		hud.set_weapon("")
		return
	if Input.is_action_just_pressed("debug_menu") and OS.is_debug_build() and _ui_cd <= 0.0 and not player.aiming:
		_debug_menu()
		return
	if Input.is_action_just_pressed("inventory") and _ui_cd <= 0.0 and player.can_act() and not player.aiming:
		hud.set_prompt("")
		GameState.log_event("inventory", {})
		inventory_ui.open()
		return

	if player.aiming:
		hud.set_weapon(GameState.weapon_label())
		hud.set_prompt(_attack_prompt())
		if Input.is_action_just_pressed("interact") and player.attack_cd <= 0.0 and _ui_cd <= 0.0:
			_attack()
		return
	hud.set_weapon("")

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
		GameState.log_event("interact", {"prompt": best_prompt})
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


## Story beats that rouse the compound. Each raises the alert once per night.
const BEATS := {
	1: "Somewhere below, a bell rings once. All over the building, doors close.",
	2: "The speakers crackle. An old man's voice, very calm: \"We have a guest. Please make our guest welcome.\"",
}


func _rouse(level: int, why: String) -> void:
	if level <= GameState.alert():
		return
	GameState.flags["alert"] = level
	GameState.log_event("alert", {"level": level, "why": why})
	await get_tree().create_timer(1.2, false).timeout
	hud.show_message(BEATS[level], 5.0)
	# The lights dip as the compound wakes
	for f in _flicker_lights:
		if is_instance_valid(f.light):
			var l: OmniLight3D = f.light
			var t := create_tween()
			t.tween_property(l, "light_energy", 0.1, 0.15)
			t.tween_property(l, "light_energy", f.base, 0.6)


func _on_room_entered(room: String) -> void:
	GameState.log_event("room", {"room": room})
	_set_music(room)
	match room:
		"Records Room":
			_rouse(1, "entered the Records Room")
		"Infirmary":
			_rouse(2, "entered the Infirmary")
		"Basement Stairs":
			_rouse(2, "entered the Basement Stairs")
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
			_rouse(2 if d.flag == LOCK_INFIRMARY else 1, "unlocked " + d.label)
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


func _take(slot: String, node: Node3D, entry: Dictionary) -> void:
	var id := slot.get_slice("#", 0)
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
	GameState.flags["picked_" + slot] = true
	GameState.log_event("pickup", {"id": id})
	interactables.erase(entry)
	node.queue_free()
	hud.show_message("Picked up the %s." % GameState.item_name(id), 2.5)
	var kind: String = GameState.ITEMS[id].kind
	if kind in ["melee", "gun"] and not GameState.meta.get("hint_aim", false):
		GameState.meta["hint_aim"] = true
		GameState.save_meta()
		hud.flash_hint("Hold [{aim}] to raise the %s. [{interact}] while raised to %s." % [GameState.item_name(id), "fire" if kind == "gun" else "swing"], 8.0)
		return
	if not GameState.flags.get("hint_inventory", false):
		GameState.flags["hint_inventory"] = true
		hud.flash_hint("[{inventory}] Open your items", 5.0)


func _resident_prompt(r: Node3D) -> String:
	var d := r.global_position.distance_to(player.global_position)
	if r.is_dead() or r.state in [r.State.ASLEEP, r.State.STIRRING, r.State.RISING]:
		return ""
	if r.is_down():
		if d > 1.7:
			return ""
		if GameState.has_item("lamp_oil"):
			return "Burn the body"
		if GameState.has_item("fire_axe"):
			return "Finish with the axe"
		return "Examine"
	if r.can_talk() and r.talk_lines.size() > 0:
		return "Talk"
	if r.is_hostile() and d <= SHOVE_RANGE and player.shove_cd <= 0.0 and r.state != r.State.STUNNED:
		return "Shove"
	return ""


func _resident_action(r: Node3D) -> void:
	if r.is_down():
		_finish_body(r)
	elif r.can_talk():
		player.face_point(r.global_position)
		GameState.log_event("talk", {"who": r.resident_id})
		r.engage(true)
	elif r.is_hostile():
		GameState.log_event("shove", {"who": r.resident_id})
		player.shove(r.global_position)
		r.stagger(player.global_position)
		hud.show_message("You shove him back. Go.", 1.6)


## Ends a downed resident for the night, so he doesn't get back up.
func _finish_body(r: Node3D) -> void:
	player.face_point(r.global_position)
	if GameState.has_item("lamp_oil"):
		GameState.remove_item("lamp_oil")
		r.finish("burned")
		GameState.flags["dead_" + r.resident_id] = "burned"
		GameState.log_event("finished", {"who": r.resident_id, "how": "burned"})
		hud.show_message("You pour the oil and strike a match. He doesn't make a sound. That's the worst part.", 4.0)
	elif GameState.has_item("fire_axe"):
		r.finish("axe")
		GameState.flags["dead_" + r.resident_id] = "axe"
		GameState.log_event("finished", {"who": r.resident_id, "how": "axe"})
		_wear("fire_axe")
		hud.show_message("One blow. You don't look at what you did.", 3.5)
	else:
		hud.show_message("He isn't breathing. He wasn't breathing before, either. He won't stay down.", 4.0)


func _on_resident_hostile(r: Node3D) -> void:
	GameState.flags["met_" + r.resident_id] = true
	GameState.log_event("resident_hostile", {"who": r.resident_id})
	if not GameState.flags.get("hint_shove", false):
		GameState.flags["hint_shove"] = true
		var how := "[{interact}] Shove to break free"
		if GameState.equipped != "":
			how = "Hold [{aim}] and [{interact}] to fight, or [{interact}] Shove to break free"
		hud.flash_hint(how + ", then get to a door.", 7.0)


func _on_resident_down(r: Node3D) -> void:
	GameState.log_event("resident_down", {"who": r.resident_id})
	if not GameState.meta.get("hint_finish", false):
		GameState.meta["hint_finish"] = true
		GameState.save_meta()
		hud.flash_hint("He'll get back up. Burn the body with lamp oil, or finish it with an axe.", 8.0)
	else:
		hud.show_message("He goes down.", 1.5)


# ---------------------------------------------------------------- fighting

## The resident in front of you, if any: closest one inside `reach`, within the cone `min_dot`.
func _aim_target(reach: float, min_dot: float) -> Node3D:
	var fwd := -player.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var best: Node3D = null
	var best_d := INF
	for r in residents:
		if not is_instance_valid(r) or not r.is_target():
			continue
		var to: Vector3 = r.global_position - player.global_position
		to.y = 0.0
		var d := to.length()
		if d > reach or d < 0.01:
			continue
		if fwd.dot(to / d) < min_dot:
			continue
		if d < best_d:
			best = r
			best_d = d
	return best


func _attack_prompt() -> String:
	var w := GameState.equipped
	if w == "":
		return ""
	if GameState.ITEMS[w].kind == "gun":
		return "[{interact}] Fire" if GameState.can_fire() else "No rounds"
	return "[{interact}] Swing"


func _attack() -> void:
	var w := GameState.equipped
	var item: Dictionary = GameState.ITEMS[w]
	if item.kind == "gun":
		if not GameState.can_fire():
			hud.show_message("Click. Empty.", 1.5)
			GameState.log_event("dry_fire", {})
			player.attack_cd = 0.5
			return
		if not GameState.debug.infinite_ammo:
			GameState.ammo -= 1
		player.attack_motion(true)
		_gunshot()
		for r in residents:
			if is_instance_valid(r):
				r.hear(player.global_position)
		var t := _aim_target(11.0, 0.93)
		GameState.log_event("shot", {"hit": t.resident_id if t else "", "rounds_left": GameState.ammo})
		if t:
			var down: bool = t.damage(int(item.damage), player.global_position)
			_hit_flash(t)
			if not down:
				hud.show_message("He jerks back. He keeps coming.", 1.5)
		if GameState.ammo == 0 and not GameState.debug.infinite_ammo:
			hud.flash_hint("That was the last round.", 3.0)
		return

	player.attack_motion(false)
	var t := _aim_target(float(item.reach), 0.5)
	GameState.log_event("swing", {"weapon": w, "hit": t.resident_id if t else ""})
	if t == null:
		return
	var stunned: bool = t.state == t.State.STUNNED
	t.damage(int(item.damage), player.global_position)
	_hit_flash(t)
	if stunned and w == "fire_axe" and t.is_down():
		hud.show_message("While he reels, you bring the axe down.", 2.0)
	_wear(w)


## Debug switches for playtesting (F4, debug builds only).
func _debug_menu() -> void:
	_busy = true
	get_tree().paused = true
	while true:
		var on: bool = GameState.debug.infinite_ammo
		var opts := ["Revolver, unlimited ammo: " + ("ON" if on else "OFF"), "Close"]
		var i: int = await hud.choose("Debug", opts, true,
			"For playtesting. Every run report records which switches were on.")
		if i == 0:
			GameState.debug.infinite_ammo = not on
			GameState.log_event("debug", {"infinite_ammo": GameState.debug.infinite_ammo})
			if GameState.debug.infinite_ammo:
				_debug_give_gun()
		else:
			break
	get_tree().paused = false
	_busy = false
	_ui_cd = 0.3


## Hands the reporter the revolver (even with full pockets) and readies it.
func _debug_give_gun() -> void:
	if not GameState.has_item("revolver"):
		GameState.inventory.append("revolver")
	GameState.equipped = "revolver"


## One use off a melee weapon. When it's worn out, it breaks.
func _wear(w: String) -> void:
	if not GameState.wear.has(w):
		return
	GameState.wear[w] = int(GameState.wear[w]) - 1
	if GameState.wear[w] <= 0:
		GameState.remove_item(w)
		GameState.log_event("broke", {"weapon": w})
		hud.show_message("The %s gives out. Useless now." % GameState.item_name(w).to_lower(), 2.5)


func _hit_flash(r: Node3D) -> void:
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.3, 0.2)
	l.light_energy = 1.5
	l.omni_range = 1.5
	l.position = Vector3(0, 1.3, 0)
	r.add_child(l)
	create_tween().tween_property(l, "light_energy", 0.0, 0.25).finished.connect(l.queue_free)


var _shot_sound: AudioStreamPlayer

func _gunshot() -> void:
	if _shot_sound == null:
		_shot_sound = AudioStreamPlayer.new()
		var rate := 16000
		var n := rate / 3
		var data := PackedByteArray()
		data.resize(n * 2)
		var rng := RandomNumberGenerator.new()
		rng.seed = 11
		for i in n:
			var env := exp(-float(i) / (rate * 0.05))
			var v := (rng.randf() * 2.0 - 1.0) * env + sin(TAU * 70.0 * i / rate) * env * 0.6
			data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0 * 0.8))
		var wav := AudioStreamWAV.new()
		wav.format = AudioStreamWAV.FORMAT_16_BITS
		wav.mix_rate = rate
		wav.data = data
		_shot_sound.stream = wav
		_shot_sound.volume_db = -4.0
		add_child(_shot_sound)
	_shot_sound.play()
	var flash := OmniLight3D.new()
	flash.light_color = Color(1.0, 0.85, 0.5)
	flash.light_energy = 4.0
	flash.omni_range = 6.0
	add_child(flash)
	flash.global_position = player.global_position + Vector3(0, 1.3, 0) - player.global_transform.basis.z * 0.6
	create_tween().tween_property(flash, "light_energy", 0.0, 0.08).finished.connect(flash.queue_free)


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
	var sub := "Nothing to send yet. Evidence you find goes in your notebook until you send it." if can_send.is_empty() \
		else "Ready to send: %s.\nOnce sent, it's safe even if you don't make it out. The night goes on." % ", ".join(can_send.map(func(id) -> String: return GameState.item_name(id)))
	var i: int = await hud.choose("The typewriter", opts, true, sub)
	var pick: String = opts[i] if i >= 0 else "Leave it"
	if pick.begins_with("Send"):
		var lines: Array = GameState.send_leads()
		await hud.choose("Dispatch sent", ["Keep going"], false,
			lines[0] + "\n\n" + "\n".join(lines.slice(1)) + "\n\nSafe now, even if you don't come back.")
	elif pick == "Pause the night":
		var c: int = await hud.choose("Pause here and return to the title?", ["Pause", "Keep going"], true,
			"You can pick up from this spot later. It won't save you if you die.")
		if c == 0:
			GameState.log_event("paused", {})
			GameState.save_game(player.global_position, player.rotation.y, player.health)
			Recorder.finish("paused")
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
	Recorder.finish("missing", summary)
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
