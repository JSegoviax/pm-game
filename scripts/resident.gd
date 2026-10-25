extends CharacterBody3D
## A resident who is no longer themselves.
## Idle until you talk to them or get too close. Says something almost normal, then follows you.
## Slow on purpose: you can always walk away. Get too close and it lunges. A shove stuns it.

signal spoke(text: String, seconds: float)
signal hit_player
signal turned_hostile

enum State { IDLE, TALKING, STALKING, WINDUP, LUNGE, RECOVER, STUNNED }

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
	# Pale robe
	_body.add_child(_part(_capsule(0.32, 1.5), Vector3(0, 0.75, 0), Color(0.72, 0.70, 0.64)))
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

func can_talk() -> bool:
	return state == State.IDLE


func is_hostile() -> bool:
	return state in [State.STALKING, State.WINDUP, State.LUNGE, State.RECOVER, State.STUNNED]


func engage(by_player: bool) -> void:
	if state != State.IDLE:
		return
	state = State.TALKING
	_talk(talk_lines if by_player else lines)


## Used when loading a save after he has already turned.
func start_hostile() -> void:
	state = State.STALKING


func stagger(from: Vector3) -> void:
	if not is_hostile():
		return
	state = State.STUNNED
	_timer = STUN_TIME
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
		State.IDLE:
			if target_here and dist < NOTICE_RANGE:
				engage(false)
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

	_body.rotation.z = sin(_bob) * 0.06 if state == State.STALKING else 0.0  # an uneven, wrong walk
	move_and_slide()


func _face(dir: Vector3, weight: float) -> void:
	if dir.length() < 0.01:
		return
	var want := atan2(-dir.x, -dir.z)
	rotation.y = lerp_angle(rotation.y, want, clampf(weight * TURN_RATE, 0.0, 1.0))


func _talk(say: PackedStringArray) -> void:
	for line in say:
		spoke.emit(line, LINE_TIME)
		await get_tree().create_timer(LINE_TIME, false).timeout
		if not is_inside_tree():
			return
	state = State.STALKING
	turned_hostile.emit()
