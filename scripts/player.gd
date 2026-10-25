extends CharacterBody3D
## The reporter. Classic tank controls: turn in place, walk where you face.

const WALK_SPEED := 1.6
const RUN_SPEED := 3.2
const BACK_SPEED := 1.0
const TURN_SPEED := 2.6  # radians per second
const GRAVITY := 9.8
const QUICK_TURN_TIME := 0.35

var frozen := false
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
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= GRAVITY * delta

	if frozen or _quick_turning:
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
	var dir := -global_transform.basis.z * forward * speed
	velocity.x = dir.x
	velocity.z = dir.z
	move_and_slide()

	# A little walk bob
	var moving := absf(forward) > 0.05
	_bob = _bob + delta * (12.0 if speed == RUN_SPEED else 7.0) if moving else 0.0
	_body.position.y = absf(sin(_bob)) * 0.04 if moving else 0.0


func _quick_turn() -> void:
	_quick_turning = true
	var tween := create_tween()
	tween.tween_property(self, "rotation:y", rotation.y + PI, QUICK_TURN_TIME)
	tween.finished.connect(func() -> void: _quick_turning = false)


func face(yaw: float) -> void:
	rotation.y = yaw
