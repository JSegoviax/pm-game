extends CharacterBody3D
## The reporter. Classic tank controls: turn in place, walk where you face.

signal hurt(health: int)
signal healed(health: int)
signal died

const WALK_SPEED := 1.6
const RUN_SPEED := 3.2
const BACK_SPEED := 1.0
const TURN_SPEED := 2.6  # radians per second
const GRAVITY := 9.8
const QUICK_TURN_TIME := 0.35
const MAX_HEALTH := 5
const SHOVE_COOLDOWN := 4.0

const AIM_TURN_SPEED := 1.9
const SWING_TIME := 0.45

var frozen := false
var aiming := false     # holding Aim with a weapon ready: feet planted, turning only
var attack_cd := 0.0
var health := MAX_HEALTH
var running := false
var shove_cd := 0.0
var _stagger := 0.0
var _knock := Vector3.ZERO
var _quick_turning := false
var _bob := 0.0
var _body: Node3D


func _ready() -> void:
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.28
	capsule.height = 1.7
	shape.shape = capsule
	shape.position.y = 0.85
	add_child(shape)

	_body = Node3D.new()
	add_child(_body)
	# Coat
	_body.add_child(_part(CapsuleMesh.new(), Vector3(0, 0.75, 0), Color(0.36, 0.30, 0.22), Vector3(0.55, 1.0, 0.45)))
	# Head
	var head := SphereMesh.new()
	head.radius = 0.16
	head.height = 0.32
	head.radial_segments = 8
	head.rings = 4
	_body.add_child(_part(head, Vector3(0, 1.55, 0), Color(0.78, 0.62, 0.50)))
	# Notebook held in front, so you can always tell which way she faces
	var book := BoxMesh.new()
	book.size = Vector3(0.18, 0.24, 0.05)
	_body.add_child(_part(book, Vector3(0.12, 1.0, -0.28), Color(0.85, 0.82, 0.70)))


func _part(mesh: Mesh, pos: Vector3, color: Color, scale_by := Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.scale = scale_by
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 1.0
	mi.material_override = mat
	return mi


func _physics_process(delta: float) -> void:
	shove_cd = maxf(0.0, shove_cd - delta)
	attack_cd = maxf(0.0, attack_cd - delta)
	running = false
	var want_aim := Input.is_action_pressed("aim") and GameState.equipped != "" and not frozen and _stagger <= 0.0 and health > 0
	if want_aim != aiming:
		aiming = want_aim
		_body.rotation.x = -0.12 if aiming else 0.0  # brace
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= GRAVITY * delta

	if _stagger > 0.0:
		_stagger -= delta
		_knock = _knock.move_toward(Vector3.ZERO, delta * 8.0)
		velocity.x = _knock.x
		velocity.z = _knock.z
		move_and_slide()
		return

	if frozen or _quick_turning:
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return

	if aiming:
		rotation.y += Input.get_axis("turn_right", "turn_left") * AIM_TURN_SPEED * delta
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return

	# Quick turn: hold back and tap run, like the originals' 180.
	if Input.is_action_pressed("move_back") and Input.is_action_just_pressed("run"):
		_quick_turn()
		return

	var turn := Input.get_axis("turn_right", "turn_left")
	rotation.y += turn * TURN_SPEED * delta

	var forward := Input.get_axis("move_back", "move_forward")
	var speed := BACK_SPEED
	if forward > 0.0:
		speed = RUN_SPEED if Input.is_action_pressed("run") else WALK_SPEED
		running = speed == RUN_SPEED
	var dir := -global_transform.basis.z * forward * speed
	velocity.x = dir.x
	velocity.z = dir.z
	move_and_slide()

	# A little walk bob
	var moving := absf(forward) > 0.05
	_bob = _bob + delta * (12.0 if running else 7.0) if moving else 0.0
	_body.position.y = absf(sin(_bob)) * 0.04 if moving else 0.0


func _quick_turn() -> void:
	_quick_turning = true
	var tween := create_tween()
	tween.tween_property(self, "rotation:y", rotation.y + PI, QUICK_TURN_TIME)
	tween.finished.connect(func() -> void: _quick_turning = false)


func face(yaw: float) -> void:
	rotation.y = yaw


func face_point(p: Vector3) -> void:
	var d := p - global_position
	if Vector2(d.x, d.z).length() > 0.01:
		rotation.y = atan2(-d.x, -d.z)


func can_act() -> bool:
	return not frozen and _stagger <= 0.0 and not _quick_turning and health > 0


func shove(at: Vector3) -> void:
	shove_cd = SHOVE_COOLDOWN
	face_point(at)
	var t := create_tween()
	t.tween_property(_body, "position:z", -0.25, 0.08)
	t.tween_property(_body, "position:z", 0.0, 0.2)


## The swing or shot animation. Damage is decided by the level, which knows who's in front.
func attack_motion(gun: bool) -> void:
	attack_cd = 0.7 if gun else SWING_TIME + 0.15
	var t := create_tween()
	if gun:
		t.tween_property(_body, "position:z", 0.08, 0.04)
		t.tween_property(_body, "position:z", 0.0, 0.2)
	else:
		t.tween_property(_body, "rotation:y", 0.5, 0.12)
		t.tween_property(_body, "rotation:y", -0.6, 0.1)
		t.tween_property(_body, "rotation:y", 0.0, 0.2)


func heal(amount: int) -> void:
	health = mini(MAX_HEALTH, health + amount)
	GameState.health = health
	healed.emit(health)


func take_hit(from: Vector3) -> void:
	if health <= 0 or _stagger > 0.0:
		return
	health -= 1
	GameState.health = health
	var away := global_position - from
	away.y = 0.0
	_knock = away.normalized() * 3.0 if away.length() > 0.01 else Vector3.ZERO
	_stagger = 0.6
	hurt.emit(health)
	if health <= 0:
		frozen = true
		died.emit()


func condition() -> String:
	if health >= 4:
		return "Fine"
	if health >= 2:
		return "Caution"
	return "Danger"
