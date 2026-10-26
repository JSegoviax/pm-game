extends SceneTree
## Headless test: the unlimited-ammo debug switch.
## Run: godot --headless --path . -s tests/test_debug.gd
var fails := 0
func check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok: fails += 1
func frames(n: int) -> void:
	for i in n: await physics_frame
func tap(a: String) -> void:
	Input.action_press(a); await frames(2); Input.action_release(a); await frames(2)

func _initialize() -> void:
	var gs = root.get_node("GameState")
	var rec = root.get_node("Recorder")
	gs.reset_all(); gs.pending = "night"; gs.tutorial_seen = true
	gs.debug.infinite_ammo = false
	var scene: PackedScene = load("res://scenes/main.tscn")
	var main = scene.instantiate(); root.add_child(main)
	await frames(30)
	await tap("debug_menu")
	await frames(5)
	check(main._busy and main.hud._choice_active, "the debug key opens the debug menu")
	main.hud._picked.emit(0)
	await frames(5)
	check(gs.debug.infinite_ammo, "switch turns on")
	check(gs.has_item("revolver") and gs.equipped == "revolver", "you're handed the revolver, ready")
	main.hud._picked.emit(1)
	await frames(5)
	check(not main._busy, "Close returns to the game")
	await frames(30)  # the game ignores input for a moment after a menu closes
	main.player.global_position = main.FOYER + Vector3(0, 0.05, 2)
	Input.action_press("aim"); await frames(3)
	for k in 10:
		await tap("interact")
		await frames(45)
	Input.action_release("aim")
	var shots: int = gs.events.filter(func(e) -> bool: return e.type == "shot").size()
	check(shots == 10 and gs.ammo == 0, "10 shots fired, no rounds needed (%d shots)" % shots)
	check(gs.weapon_label().contains("unlimited"), "weapon readout says unlimited")
	rec.flush()
	var data = JSON.parse_string(FileAccess.get_file_as_string(rec.folder.path_join(rec.run_name + ".json")))
	check(data.debug.infinite_ammo == true, "the run report records the switch")
	# Next night: still on, gun handed over again
	gs.end_night("test"); main.queue_free(); await frames(3)
	gs.pending = "night"
	main = scene.instantiate(); root.add_child(main)
	await frames(30)
	check(gs.has_item("revolver") and gs.equipped == "revolver", "next reporter starts with the revolver while the switch is on")
	gs.debug.infinite_ammo = false
	gs.reset_all()
	print("FAILS: %d" % fails)
	quit(1 if fails else 0)
