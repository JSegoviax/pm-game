extends SceneTree
## Headless test: wherever you stand, the active camera keeps the reporter on screen.
## Run: godot --headless --path . -s tests/test_room_coverage.gd
var fails := 0
func check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok: fails += 1

func _initialize() -> void:
	var gs = root.get_node("GameState")
	gs.reset_all(); gs.pending = "night"; gs.tutorial_seen = true
	var t0 := Time.get_ticks_msec()
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for i in 10: await physics_frame
	await process_frame
	for r in main.residents:
		r.set_physics_process(false)
		r.global_position += Vector3(0, -50, 0)
	var lost_total := []
	for room in main._bounds:
		var pts: Array = main._floor_points(room)
		var seen := 0
		var lost := []
		for p in pts:
			var cam: Camera3D = main._camera_for(p)
			if cam != null and main._cam_sees(cam, p + Vector3(0, 1.0, 0)):
				seen += 1
			else:
				lost.append(p.snapped(Vector3.ONE * 0.1))
		var share := float(seen) / maxf(1, pts.size())
		check(share >= 0.95, "%s: reporter on screen at %d of %d spots (%d%%)%s" % [room, seen, pts.size(), int(share * 100), "" if lost.is_empty() else "  lost at " + str(lost.slice(0, 4))])
	print("cameras: %d zones" % main.zones.size())
	# The next night reuses the plan: same zones, same angles
	var before: Array = main.zones.map(func(z): return [z.box, (z.camera as Camera3D).global_transform])
	main.queue_free(); await process_frame
	gs.pending = "night"
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	var after: Array = main.zones.map(func(z): return [z.box, (z.camera as Camera3D).global_transform])
	check(before.size() == after.size() and str(before) == str(after), "the next night reuses the same camera plan (%d zones)" % after.size())
	gs.reset_all()
	print("FAILS: %d" % fails)
	quit(1 if fails else 0)
