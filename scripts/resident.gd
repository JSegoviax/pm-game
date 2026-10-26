extends CharacterBody3D
## A resident who is no longer themselves.
## Idle until you talk to them or get too close. Says something almost normal, then follows you.
## Slow on purpose: you can always walk away. Get too close and it lunges. A shove stuns it.

signal spoke(text: String, seconds: float)
signal hit_player
signal turned_hostile
signal went_down
signal rose

enum State { IDLE, TALKING, STALKING, WINDUP, LUNGE, RECOVER, STUNNED, ASLEEP, STIRRING, DOWN, RISING, DEAD }

## What kind of resident this is. "member": talks, then follows you. "sleeper": asleep in the
## dormitory until you get close or make noise. "benefactor": one of the wealthy members, kept
## lucid; talks but only turns on you if you attack him. "worshipper" and "nurse": like members.
@export var kind := "member"
@export var resident_id := "hall"
## How roused the compound must be before this resident turns on you: 1 Uneasy, 2 Roused,
## 99 never (only if attacked). Below it, they talk, watch you, and let you pass.
@export var threshold := 1
## Said when the compound's alert reaches this resident's threshold and they turn.
@export var turn_line := "He stops smiling."

const MAX_HP := 6
const RISE_HP := 4          # they come back weaker, but they come back
const DOWN_TIME := 40.0     # seconds on the floor before getting back up
const RISE_WARNING := 8.0   # twitching starts this long before rising
const RISE_TIME := 1.6
const WAKE_WALK := 1.3      # sleepers stir if you walk this close
const WAKE_RUN := 2.6       # or run this close
const STIR_TIME := 1.5      # back away while he stirs and he settles again
const WAKE_RISE := 2.2      # a woken sleeper takes this long to get up

const NOTICE_RANGE := 2.4   # walks up on you without talking first
const TALK_RANGE := 3.2     # how far away you can start a conversation
const STALK_SPEED := 1.05
const LUNGE_TRIGGER := 1.8
const LUNGE_SPEED := 5.0
const LUNGE_TIME := 0.32
const WINDUP_TIME := 0.7
const RECOVER_TIME := 1.3
const STUN_TIME := 2.6
const HIT_RANGE := 0.95
const TURN_RATE := 4.0
const GRAVITY := 9.8
const LINE_TIME := 3.0

## Said when he notices you first.
@export var lines: PackedStringArray = [
	"\"Visiting hours ended at eleven. Everyone's downstairs for the meeting.\"",
	"He keeps smiling. He hasn't blinked once.",
]
## Said when you start the conversation.
@export var talk_lines: PackedStringArray = [
	"\"Excuse me. I'm with the Courier. I'm looking for whoever's in charge.\"",
	"He turns around slowly. \"Everyone is in charge. Everyone is downstairs.\"",
	"\"You should be downstairs too.\" He hasn't blinked once.",
]

var target: Node3D
var bounds: AABB  # the room it can't leave
var state := State.IDLE
var hp := MAX_HP
var finished_by := ""   # "burned" or "axe" once the body is finished
var down_time := DOWN_TIME
var _warned := false
var provoked := false     # attacked or shot at: hostile whatever the alert
var _talked := false      # said his piece; won't start talking on his own again
var _rise_from := RISE_TIME
var _timer := 0.0
var _hit_this_lunge := false
var _knock := Vector3.ZERO
var _body: Node3D
var _bob := 0.0


func _ready() -> void:
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.8
	cs.shape = cap
	cs.position.y = 0.9
	add_child(cs)

	_body = Node3D.new()
	add_child(_body)
	var robe := Color(0.72, 0.70, 0.64)
	match kind:
		"benefactor": robe = Color(0.12, 0.11, 0.14)   # a good dark suit
		"nurse": robe = Color(0.80, 0.82, 0.84)
		"worshipper": robe = Color(0.55, 0.12, 0.10)   # vestments for the Quiet Hour
	_body.add_child(_part(_capsule(0.32, 1.5), Vector3(0, 0.75, 0), robe))
	if kind == "benefactor":
		# A gold pin: the inner circle
		var pin := BoxMesh.new()
		pin.size = Vector3(0.07, 0.07, 0.03)
		var gold := _part(pin, Vector3(0.14, 1.25, -0.3), Color(0.95, 0.75, 0.25))
		(gold.material_override as StandardMaterial3D).emission_enabled = true
		(gold.material_override as StandardMaterial3D).emission = Color(0.5, 0.35, 0.1)
		_body.add_child(gold)
	# Head
	var head := SphereMesh.new()
	head.radius = 0.17
	head.height = 0.34
	head.radial_segments = 8
	head.rings = 4
	_body.add_child(_part(head, Vector3(0, 1.62, 0), Color(0.80, 0.70, 0.62)))
	# The smile and the eyes, so you can see when it's looking at you
	var eye := BoxMesh.new()
	eye.size = Vector3(0.05, 0.03, 0.02)
	for x in [-0.06, 0.06]:
		_body.add_child(_part(eye, Vector3(x, 1.67, -0.16), Color(0.02, 0.02, 0.02)))
	var smile := BoxMesh.new()
	smile.size = Vector3(0.16, 0.025, 0.02)
	_body.add_child(_part(smile, Vector3(0, 1.55, -0.16), Color(0.35, 0.05, 0.05)))


func _capsule(r: float, h: float) -> CapsuleMesh:
	var c := CapsuleMesh.new()
	c.radius = r
	c.height = h
	c.radial_segments = 8
	c.rings = 2
	return c


func _part(mesh: Mesh, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 1.0
	mi.material_override = m
	return mi


# ---------------------------------------------------------------- public

## Pronouns for messages about this resident: {he}/{him}/{He}/{his} become she/her for women.
func words(text: String) -> String:
	var f := kind in ["worshipper", "nurse"]
	return text.replace("{He}", "She" if f else "He").replace("{he}", "she" if f else "he") \
		.replace("{him}", "her" if f else "him").replace("{his}", "her" if f else "his")


func can_talk() -> bool:
	return state == State.IDLE


## Whether this resident is willing to attack you right now.
func wants_you() -> bool:
	return provoked or GameState.alert() >= threshold


func _turn() -> void:
	state = State.STALKING
	turned_hostile.emit()


func is_hostile() -> bool:
	return state in [State.STALKING, State.WINDUP, State.LUNGE, State.RECOVER, State.STUNNED]


## Can be hit: awake, standing, and not already on the floor.
func is_target() -> bool:
	return state not in [State.DOWN, State.RISING, State.DEAD]


func is_down() -> bool:
	return state == State.DOWN or state == State.RISING


func is_dead() -> bool:
	return state == State.DEAD


func state_name() -> String:
	return (State.keys()[state] as String).to_lower()


## Takes damage. `heavy` hits on a stunned resident count double. Returns true if it went down.
func damage(amount: int, from: Vector3) -> bool:
	if not is_target():
		return false
	if state == State.STUNNED:
		amount *= 2
	hp -= amount
	provoked = true
	if hp <= 0:
		_go_down()
		return true
	# Any hit wakes a sleeper (he still has to get up) or ends the small talk
	if state in [State.ASLEEP, State.STIRRING]:
		_wake()
		return false
	if not is_hostile():
		_turn()
	stagger(from, 0.9)
	return false


## A gunshot nearby. Sleepers in the same room wake up.
func hear(from: Vector3) -> void:
	if state in [State.ASLEEP, State.STIRRING] and bounds.has_point(from + Vector3(0, 0.5, 0)):
		provoked = true
		_wake()


## Ends it for the night. `how`: "burned" or "axe".
func finish(how: String) -> void:
	if not is_down():
		return
	finished_by = how
	state = State.DEAD
	_body.rotation.x = -PI / 2
	_body.position.y = 0.32
	if how == "burned":
		for mi in _body.get_children():
			if mi is MeshInstance3D:
				(mi.material_override as StandardMaterial3D).albedo_color = Color(0.08, 0.07, 0.06)
		var fire := OmniLight3D.new()
		fire.light_color = Color(1.0, 0.5, 0.15)
		fire.light_energy = 2.0
		fire.omni_range = 4.0
		fire.position.y = 0.5
		add_child(fire)
		create_tween().tween_property(fire, "light_energy", 0.0, 8.0)


## Puts the resident straight onto the floor as an already-finished body (resuming a paused night).
func start_dead(how: String) -> void:
	_go_down()
	finish(how)


func start_asleep() -> void:
	state = State.ASLEEP
	_body.rotation.x = -PI / 2
	_body.position = Vector3(0, 0.85, 0)


func _wake() -> void:
	state = State.RISING
	_timer = WAKE_RISE
	_rise_from = WAKE_RISE


func _go_down() -> void:
	state = State.DOWN
	_timer = down_time
	_warned = false
	_knock = Vector3.ZERO
	_body.rotation = Vector3(-PI / 2, 0, 0)
	_body.position = Vector3(0, 0.32, 0)
	collision_layer = 0
	went_down.emit()


func engage(by_player: bool) -> void:
	if state != State.IDLE:
		return
	state = State.TALKING
	_talk(talk_lines if by_player else lines)


## Used when loading a save after he has already turned.
func start_hostile() -> void:
	provoked = true
	state = State.STALKING


func stagger(from: Vector3, seconds := STUN_TIME) -> void:
	if not is_hostile():
		return
	state = State.STUNNED
	_timer = seconds
	var away := global_position - from
	away.y = 0.0
	_knock = away.normalized() * 4.0 if away.length() > 0.01 else Vector3.ZERO
	_body.position.y = 0.0


# ---------------------------------------------------------------- behavior

func _physics_process(delta: float) -> void:
	velocity.y = 0.0 if is_on_floor() else velocity.y - GRAVITY * delta
	velocity.x = 0.0
	velocity.z = 0.0
	if target == null:
		move_and_slide()
		return

	var to_target := target.global_position - global_position
	to_target.y = 0.0
	var dist := to_target.length()
	var target_here := bounds.has_point(target.global_position + Vector3(0, 0.5, 0))
	_timer -= delta

	match state:
		State.DEAD:
			pass
		State.ASLEEP:
			var running: bool = target.get("running") == true
			if target_here and dist < (WAKE_RUN if running else WAKE_WALK):
				state = State.STIRRING
				_timer = STIR_TIME
				spoke.emit("In the bunk beside you, someone stirs.", 2.0)
		State.STIRRING:
			_body.rotation.z = sin(_timer * 18.0) * 0.08  # turning over
			var running: bool = target.get("running") == true
			var too_close := target_here and dist < (WAKE_RUN if running else WAKE_WALK) + 0.4
			if not too_close:
				state = State.ASLEEP  # you backed off; he settles
				_body.rotation.z = 0.0
			elif _timer <= 0.0:
				_wake()
		State.DOWN:
			if _timer <= RISE_WARNING and not _warned:
				_warned = true
				if target_here:
					spoke.emit("On the floor, a hand closes. Then opens.", 3.0)
			if _timer <= RISE_WARNING:
				_body.rotation.z = sin(_timer * 30.0) * 0.05  # twitching
			if _timer <= 0.0:
				state = State.RISING
				_timer = RISE_TIME
				_rise_from = RISE_TIME
		State.RISING:
			var k := clampf(_timer / _rise_from, 0.0, 1.0)
			_body.rotation = Vector3(-PI / 2 * k, 0, 0)
			_body.position = Vector3(0, 0.32 * k, 0)
			if _timer <= 0.0:
				_body.rotation = Vector3.ZERO
				_body.position = Vector3.ZERO
				collision_layer = 1
				var was_down := hp <= 0
				hp = RISE_HP if was_down else hp
				rose.emit()
				if was_down or wants_you():
					_turn()
				else:
					# Woken, but the compound is calm: he stands and stares.
					state = State.IDLE
					_talked = true
					spoke.emit("He sits up and watches you. He doesn't lie back down.", 3.0)
		State.IDLE:
			# Once he's spoken (or if he never does), he watches you go by.
			if (_talked or lines.is_empty()) and target_here and dist < TALK_RANGE * 1.5:
				_face(to_target, delta * 0.3)
			if target_here and dist < NOTICE_RANGE and not _talked and not lines.is_empty():
				engage(false)
			elif target_here and dist < TALK_RANGE * 2.0 and wants_you():
				spoke.emit(turn_line, 2.5)
				_turn()
		State.TALKING:
			_face(to_target, delta * 0.6)
		State.STALKING:
			if target_here:
				_face(to_target, delta)
				var step := to_target.normalized() * STALK_SPEED
				velocity.x = step.x
				velocity.z = step.z
				_bob += delta * 5.0
				if dist < LUNGE_TRIGGER:
					state = State.WINDUP
					_timer = WINDUP_TIME
		State.WINDUP:
			_face(to_target, delta * 2.0)
			_body.position.y = -0.08  # crouch before it springs
			if _timer <= 0.0:
				state = State.LUNGE
				_timer = LUNGE_TIME
				_hit_this_lunge = false
				_body.position.y = 0.0
		State.LUNGE:
			var fwd := -global_transform.basis.z * LUNGE_SPEED
			velocity.x = fwd.x
			velocity.z = fwd.z
			if not _hit_this_lunge and dist < HIT_RANGE:
				_hit_this_lunge = true
				hit_player.emit()
			if _timer <= 0.0:
				state = State.RECOVER
				_timer = RECOVER_TIME
		State.RECOVER:
			if _timer <= 0.0:
				state = State.STALKING
		State.STUNNED:
			_knock = _knock.move_toward(Vector3.ZERO, delta * 6.0)
			velocity.x = _knock.x
			velocity.z = _knock.z
			_body.rotation.x = 0.35 * clampf(_timer / STUN_TIME, 0.0, 1.0)  # reeling back
			if _timer <= 0.0:
				_body.rotation.x = 0.0
				state = State.STALKING

	if state == State.STALKING:
		_body.rotation.z = sin(_bob) * 0.06  # an uneven, wrong walk
	elif state not in [State.DOWN, State.DEAD, State.ASLEEP, State.STIRRING, State.RISING]:
		_body.rotation.z = 0.0
	move_and_slide()


func _face(dir: Vector3, weight: float) -> void:
	if dir.length() < 0.01:
		return
	var want := atan2(-dir.x, -dir.z)
	rotation.y = lerp_angle(rotation.y, want, clampf(weight * TURN_RATE, 0.0, 1.0))


## Set by the level: shows a line and waits for the player to press the action button.
var say_line: Callable

func _talk(say: PackedStringArray) -> void:
	for line in say:
		if say_line.is_valid():
			await say_line.call(line)
		else:
			spoke.emit(line, LINE_TIME)
			await get_tree().create_timer(LINE_TIME, false).timeout
		if not is_inside_tree():
			return
	if state != State.TALKING:
		return
	_talked = true
	if wants_you():
		_turn()
	else:
		state = State.IDLE  # he has said his piece; he'll watch you, and say it again if asked
