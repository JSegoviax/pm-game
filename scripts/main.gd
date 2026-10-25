extends Node3D
## Milestone 1: two rooms of the compound, fixed camera angles, and a door between them.
## Rooms are built in code from simple boxes so we can iterate fast before real assets.

const PLAYER_SCRIPT := preload("res://scripts/player.gd")
const RESIDENT_SCRIPT := preload("res://scripts/resident.gd")
const WALL_H := 4.0
const WALL_T := 0.3
const DOOR_REACH := 1.5

var player: CharacterBody3D
var zones: Array = []   # { "box": AABB, "camera": Camera3D }
var doors: Array = []   # { "pos": Vector3, "label": String, "locked": bool, "to": Vector3, "yaw": float, "room": String }
var _current_zone := -1
var _busy := false
var _flicker_lights: Array = []

var _fade: ColorRect
var _message: Label
var _prompt: Label
var _message_timer := 0.0
var _condition: Label
var _condition_timer := 0.0
var _hurt_flash: ColorRect
var _hallway_bounds: AABB
var _dead := false


func _ready() -> void:
	_build_environment()
	_build_foyer()
	_build_hallway()
	_build_hud()

	player = CharacterBody3D.new()
	player.set_script(PLAYER_SCRIPT)
	player.name = "Reporter"
	add_child(player)
	player.global_position = Vector3(0, 0.05, 3.5)
	player.face(0.0)  # facing north, into the room

	player.hurt.connect(_on_player_hurt)
	player.died.connect(_on_player_died)
	_spawn_resident()

	_update_camera(true)
	_fade.color.a = 1.0
	_show_message("Compound of the Quiet Hour\n11:52 P.M.", 3.5)
	create_tween().tween_property(_fade, "color:a", 0.0, 2.0)


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


func _room(name_: String, center: Vector3, size_x: float, size_z: float, floor_mat: Material, wall_mat: Material) -> Node3D:
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


func _zone(room: Node3D, from: Vector3, to: Vector3, cam: Camera3D) -> void:
	var a := room.global_position + from
	var b := room.global_position + to
	var box := AABB(a, Vector3.ZERO).expand(b)
	zones.append({"box": box, "camera": cam})


func _door(room: Node3D, local_pos: Vector3, label: String, locked: bool, to := Vector3.ZERO, yaw := 0.0, to_room := "") -> void:
	var p := room.global_position + local_pos
	# Door slab, inset into the wall
	var slab := _box(self, Vector3(1.3, 2.4, 0.12), p + Vector3(0, 1.2, 0), _mat(Color(0.22, 0.12, 0.08)), false)
	var facing_wall := absf(local_pos.x) > absf(local_pos.z)
	if facing_wall:
		slab.rotation.y = PI / 2
	_box(self, Vector3(0.08, 0.08, 0.08), p + Vector3(0.45 if not facing_wall else 0.0, 1.1, 0.0 if not facing_wall else 0.45), _mat(Color(0.75, 0.62, 0.30)), false)
	doors.append({"pos": p, "label": label, "locked": locked, "to": to, "yaw": yaw, "room": to_room})


# ---------------------------------------------------------------- rooms

func _build_foyer() -> void:
	var foyer := _room("Foyer", Vector3.ZERO, 12.0, 10.0, _mat(Color(0.30, 0.26, 0.22), true), _mat(Color(0.42, 0.40, 0.36), true))
	var wood := _mat(Color(0.26, 0.16, 0.10))
	var stone := _mat(Color(0.50, 0.48, 0.44), true)
	# Pillars
	for x in [-3.0, 3.0]:
		_box(foyer, Vector3(0.6, WALL_H, 0.6), Vector3(x, WALL_H / 2, -1.0), stone)
	# Meeting table with chairs pushed back in a hurry
	_box(foyer, Vector3(3.2, 0.9, 1.1), Vector3(0, 0.45, -2.6), wood)
	_box(foyer, Vector3(0.5, 0.9, 0.5), Vector3(-1.2, 0.45, -1.6), wood).rotation.y = 0.5
	_box(foyer, Vector3(0.5, 0.9, 0.5), Vector3(1.4, 0.45, -3.7), wood).rotation.y = -0.3
	_box(foyer, Vector3(0.5, 0.45, 0.5), Vector3(2.2, 0.22, -1.2), wood).rotation.z = 1.4  # knocked over
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
	_zone(foyer, Vector3(-6, -1, 0.5), Vector3(6, 4, 5), cam_south)
	_zone(foyer, Vector3(-6, -1, -5), Vector3(6, 4, 0.5), cam_north)

	# North door leads to the east hallway
	_door(foyer, Vector3(3.5, 0, -4.94), "East Hallway", false, Vector3(40, 0.05, 6.5), 0.0, "East Hallway")


func _build_hallway() -> void:
	var hall := _room("EastHallway", Vector3(40, 0, 0), 4.0, 16.0, _mat(Color(0.22, 0.24, 0.22), true), _mat(Color(0.34, 0.33, 0.30), true))
	var wood := _mat(Color(0.24, 0.15, 0.10))
	# Benches and a coat rack with coats still on it
	_box(hall, Vector3(0.6, 0.5, 2.4), Vector3(-1.6, 0.25, 2.0), wood)
	_box(hall, Vector3(0.6, 0.5, 2.4), Vector3(1.6, 0.25, -3.5), wood)
	for i in 3:
		_box(hall, Vector3(0.35, 1.3, 0.12), Vector3(1.75, 1.35, 3.0 + i * 0.5), _mat(Color(0.12, 0.12, 0.14)), false)
	# Photographs on the wall, all the same smiling group
	for z in [-6.0, -4.5, -1.0, 1.5]:
		_box(hall, Vector3(0.05, 0.5, 0.4), Vector3(-1.95, 2.0, z), _mat(Color(0.65, 0.60, 0.50)), false)

	_light(hall, Vector3(0, 3.3, 4.0), Color(1.0, 0.8, 0.55), 1.0, 6.0)
	_light(hall, Vector3(0, 3.3, -4.5), Color(0.9, 0.95, 1.0), 0.9, 6.0, true)

	var cam_south := _camera(hall, Vector3(1.6, 3.4, -7.6), Vector3(-0.2, 0.6, 3.5), 50.0)
	var cam_north := _camera(hall, Vector3(-1.6, 3.2, 7.6), Vector3(0.2, 0.8, -4.0), 50.0)
	_zone(hall, Vector3(-2, -1, 0), Vector3(2, 4, 8), cam_south)
	_zone(hall, Vector3(-2, -1, -8), Vector3(2, 4, 0), cam_north)

	_hallway_bounds = AABB(hall.global_position + Vector3(-2, -1, -8), Vector3(4, 5, 16))

	_door(hall, Vector3(0, 0, 7.94), "Foyer", false, Vector3(3.5, 0.05, -3.9), PI, "Foyer")
	_door(hall, Vector3(0, 0, -7.94), "Locked", true)


# ---------------------------------------------------------------- HUD

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	_message = Label.new()
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_message.offset_left = 16
	_message.offset_right = -16
	_message.offset_bottom = -18
	_message.add_theme_font_size_override("font_size", 10)
	_message.add_theme_color_override("font_shadow_color", Color.BLACK)
	_message.add_theme_constant_override("shadow_offset_x", 1)
	_message.add_theme_constant_override("shadow_offset_y", 1)
	layer.add_child(_message)

	_prompt = Label.new()
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_prompt.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_prompt.offset_left = -150
	_prompt.offset_right = -8
	_prompt.offset_top = 6
	_prompt.add_theme_font_size_override("font_size", 9)
	_prompt.add_theme_color_override("font_color", Color(0.85, 0.75, 0.5))
	layer.add_child(_prompt)

	_condition = Label.new()
	_condition.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_condition.offset_left = 8
	_condition.offset_top = 6
	_condition.add_theme_font_size_override("font_size", 10)
	layer.add_child(_condition)

	_hurt_flash = ColorRect.new()
	_hurt_flash.color = Color(0.6, 0.0, 0.0, 0.0)
	_hurt_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hurt_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_hurt_flash)

	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 0)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_fade)


func _show_message(text: String, seconds := 2.5) -> void:
	_message.text = text
	_message_timer = seconds


# ---------------------------------------------------------------- loop

func _physics_process(delta: float) -> void:
	_update_camera()

	if _message_timer > 0.0:
		_message_timer -= delta
		if _message_timer <= 0.0:
			_message.text = ""

	if _condition_timer > 0.0:
		_condition_timer -= delta
		if _condition_timer <= 0.0:
			_condition.text = ""

	for f in _flicker_lights:
		f.t += delta
		var l: OmniLight3D = f.light
		var dip := 0.15 if fmod(f.t, 3.7) < 0.12 or fmod(f.t, 5.3) < 0.06 else 1.0
		l.light_energy = f.base * dip * (0.92 + 0.08 * sin(f.t * 23.0))

	var door = _nearest_door()
	_prompt.text = "" if door == null or _busy else ("[E] Open door" if not door.locked else "[E] Examine door")
	if door != null and not _busy and not _dead and Input.is_action_just_pressed("interact"):
		_use_door(door)


func _nearest_door():
	if player == null:
		return null
	for d in doors:
		var flat := Vector2(player.global_position.x - d.pos.x, player.global_position.z - d.pos.z)
		if flat.length() < DOOR_REACH:
			return d
	return null


func _update_camera(force := false) -> void:
	if player == null:
		return
	var p := player.global_position + Vector3(0, 0.5, 0)
	for i in zones.size():
		if zones[i].box.has_point(p):
			if i != _current_zone or force:
				_current_zone = i
				(zones[i].camera as Camera3D).make_current()
			return


func _use_door(d: Dictionary) -> void:
	if d.locked:
		_show_message("Locked from the other side. Someone has scratched two letters into the wood: P.M.", 4.0)
		return
	_busy = true
	player.frozen = true
	var t := create_tween()
	t.tween_property(_fade, "color:a", 1.0, 0.45)
	await t.finished
	await get_tree().create_timer(0.9).timeout  # the long door beat
	player.global_position = d.to
	player.face(d.yaw)
	player.velocity = Vector3.ZERO
	_update_camera(true)
	var t2 := create_tween()
	t2.tween_property(_fade, "color:a", 0.0, 0.45)
	await t2.finished
	_show_message(d.room, 2.0)
	player.frozen = false
	_busy = false


# ---------------------------------------------------------------- threat

func _spawn_resident() -> void:
	var r := CharacterBody3D.new()
	r.set_script(RESIDENT_SCRIPT)
	r.name = "Resident"
	add_child(r)
	r.global_position = Vector3(40.6, 0.05, -5.8)
	r.rotation.y = 0.0  # facing the wall of photographs at the far end
	r.target = player
	r.bounds = _hallway_bounds
	r.spoke.connect(_show_message)
	r.hit_player.connect(func() -> void: player.take_hit(r.global_position))


func _on_player_hurt(health: int) -> void:
	_hurt_flash.color.a = 0.55
	create_tween().tween_property(_hurt_flash, "color:a", 0.0, 0.6)
	var c: String = player.condition()
	_condition.text = "Condition: " + c
	var colors := {"Fine": Color(0.55, 0.85, 0.5), "Caution": Color(0.95, 0.75, 0.3), "Danger": Color(0.95, 0.3, 0.25)}
	_condition.add_theme_color_override("font_color", colors[c])
	_condition_timer = 2.5


func _on_player_died() -> void:
	_dead = true
	_busy = true
	_prompt.text = ""
	await get_tree().create_timer(0.8).timeout
	var t := create_tween()
	t.tween_property(_fade, "color:a", 1.0, 1.6)
	await t.finished
	_show_message("The meeting will begin without you.", 4.0)
	await get_tree().create_timer(3.5).timeout
	get_tree().reload_current_scene()
