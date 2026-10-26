extends SceneTree
## Headless test: every door can be seen by the camera that's active when you stand at it.
## A door may be marked `hidden` in its lock dictionary when hiding it is deliberate.
## Run: godot --headless --path . -s tests/test_door_cameras.gd
var fails := 0
func check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok: fails += 1

## Is `p` visible from camera `cam`: in frame (with a margin) and not behind a wall?
func sees(main: Node, cam: Camera3D, p: Vector3) -> String:
	if cam.is_position_behind(p):
		return "behind the camera"
	var vp := Vector2(320, 240)
	var sp := cam.unproject_position(p)
	if sp.x < vp.x * 0.04 or sp.x > vp.x * 0.96 or sp.y < vp.y * 0.04 or sp.y > vp.y * 0.96:
		return "out of frame (%d, %d)" % [sp.x, sp.y]
	var space = main.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(cam.global_position, p)
	q.exclude = [main.player.get_rid()]
	var hit: Dictionary = space.intersect_ray(q)
	if not hit.is_empty() and hit.position.distance_to(p) > 0.35:
		return "blocked at %s" % hit.position.snapped(Vector3.ONE * 0.1)
	return ""

func _initialize() -> void:
	var gs = root.get_node("GameState")
	gs.reset_all(); gs.pending = "night"; gs.tutorial_seen = true
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for i in 10: await physics_frame
	await process_frame
	for r in main.residents:
		r.set_physics_process(false)
		r.global_position += Vector3(0, -50, 0)
	for d in main.doors:
		if d.hidden:
			continue
		# Stand where you'd stand to open it: just in front, facing it
		var stand: Vector3 = d.pos + d.inward * 1.1 + Vector3(0, 0.05, 0)
		main.player.global_position = stand
		main._update_camera(true)
		var cam: Camera3D = main._camera_for(stand)
		var where: String = main._room
		var middle: Vector3 = d.pos + Vector3(0, 1.3, 0) + d.inward * 0.12
		var lamp: Vector3 = d.pos + Vector3(0, 2.6, 0) + d.inward * 0.12
		var why := sees(main, cam, middle)
		if why != "":
			why = sees(main, cam, lamp)  # the frame top and lamp showing is enough
		check(why == "", "%s: door to %s %s" % [where, d.to_room, "visible" if why == "" else why])
	gs.reset_all()
	print("FAILS: %d" % fails)
	quit(1 if fails else 0)
