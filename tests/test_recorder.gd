extends SceneTree
## Headless test: plays a scripted night and checks the run recorder.
## Run: godot --headless --path . -s tests/test_recorder.gd
var fails := 0
func check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok: fails += 1

func frames(n: int) -> void:
	for i in n: await physics_frame

func _initialize() -> void:
	var gs = root.get_node("GameState")
	var rec = root.get_node("Recorder")
	gs.reset_all()
	gs.pending = "night"
	var scene: PackedScene = load("res://scenes/main.tscn")
	var main = scene.instantiate()
	root.add_child(main)
	await frames(60)
	check(rec.run_name.contains("seed%d" % gs.night_seed), "run file named with the seed: " + rec.run_name)
	check(rec.placed.has("key_east") and rec.placed.has("resident_hall"), "placements recorded: %s" % [rec.placed])
	# Walk forward for 2 seconds with the real controls
	Input.action_press("move_forward"); Input.action_press("run")
	await frames(120)
	Input.action_release("move_forward"); Input.action_release("run")
	await frames(10)
	check(rec.trail.size() >= 8, "trail sampled: %d rows" % rec.trail.size())
	check(rec.trail.any(func(r) -> bool: return r[12].contains("F")), "held keys recorded")
	# Flag a moment
	Input.action_press("flag_moment"); await frames(2); Input.action_release("flag_moment")
	await frames(10)
	check(rec.flags == 1, "F9 flagged a moment")
	# Pause the night and resume it
	var name1: String = rec.run_name
	var rows1: int = rec.trail.size()
	gs.log_event("paused", {})
	gs.save_game(main.player.global_position, main.player.rotation.y, main.player.health)
	rec.finish("paused")
	main.queue_free(); await frames(2)
	gs.pending = "continue"
	main = scene.instantiate(); root.add_child(main)
	await frames(30)
	check(rec.run_name == name1, "resumed night keeps the same record")
	check(rec.trail.size() >= rows1, "trail continues after resume (%d -> %d)" % [rows1, rec.trail.size()])
	# Get caught
	for i in 5: main.player.take_hit(main.player.global_position + Vector3(0, 0, -1)); await frames(70)
	await frames(30)
	var path: String = rec.folder.path_join(name1 + ".json")
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	check(data.outcome.status == "missing", "outcome recorded: " + str(data.outcome.get("status")))
	var types := {}
	for e in data.events: types[e.type] = true
	for t in ["night_start", "message", "flag", "paused", "resumed", "hurt", "missing"]:
		check(types.has(t), "event logged: " + t)
	check(FileAccess.file_exists(rec.folder.path_join(name1 + ".txt")), "readable timeline written")
	check(FileAccess.file_exists(rec.folder.path_join(name1 + "_flag1.png")), "flag screenshot saved")
	print("FOLDER ", rec.folder)
	gs.reset_all()
	print("FAILS: %d" % fails)
	quit(1 if fails else 0)
