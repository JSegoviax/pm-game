extends SceneTree
## Headless test: the compound starts calm, and story beats rouse it.
## Run: godot --headless --path . -s tests/test_buildup.gd
var fails := 0
func check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok: fails += 1
func get_paused() -> bool:
	return paused

func frames(n: int) -> void:
	for i in n: await physics_frame

func _initialize() -> void:
	var gs = root.get_node("GameState")
	gs.reset_all()
	gs.pending = "night"
	gs.tutorial_seen = true
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await frames(30)
	var hall = main.get_node("Resident_hall")
	check(gs.alert() == 0, "the night starts calm")

	# Walk up and talk: he says his piece and doesn't attack
	main.player.global_position = hall.global_position + Vector3(0, 0, 1.5)
	main.player.face(0.0)
	await frames(10)
	hall.engage(true)
	await process_frame
	await process_frame
	var first: String = main.hud._message.text
	for k in 120: await process_frame
	check(main.hud.talking and main.hud._message.text == first and get_paused(), "a line of dialogue waits until you press the button, with the game paused")
	# Press through every line (his own greeting may come first), then stop pressing
	for k in 12:
		if not main.hud.talking:
			break
		Input.action_press("interact"); await process_frame; await process_frame
		Input.action_release("interact")
		for j in 10: await process_frame
	await frames(30)
	check(hall.state_name() == "idle", "calm: after talking he stays put (%s)" % hall.state_name())
	check(main.player.health == 5, "calm: standing next to him is safe")
	check(main._resident_prompt(hall) == "Talk", "you can talk to him again")

	# A sleeper woken while calm just sits up
	var sl = main.get_node("Resident_sleeper_a")
	sl.start_asleep()
	sl._wake()
	main.player.global_position = sl.global_position + Vector3(0, 0, 2.5)
	await frames(60 * 3)
	check(sl.state_name() == "idle", "calm: a woken sleeper sits up and watches (%s)" % sl.state_name())

	# Attacking one makes him hostile, whatever the alert
	sl.damage(1, main.player.global_position)
	await frames(5)
	check(sl.is_hostile(), "hit him and he turns")

	# The bell: entering the Records Room
	main._on_room_entered("Records Room")
	check(gs.alert() == 1, "entering the Records Room makes the compound Uneasy")
	# Back in the hall, he turns when he sees you
	main.player.global_position = hall.global_position + Vector3(0, 0, 4.0)
	main._update_camera(true)
	await frames(20)
	check(hall.is_hostile(), "Uneasy: the hallway member turns (%s)" % hall.state_name())

	# The worshipper and nurse wait for Roused; the benefactor never turns
	var others := {}
	for r in main.residents: others[r.kind] = r
	for c in main.CAST:
		if c.kind in ["worshipper", "benefactor"] and not others.has(c.kind):
			main._spawn_resident(c, c.spots[0][0], c.spots[0][1])
	for r in main.residents: others[r.kind] = r
	check(others.has("worshipper") and others.has("benefactor"), "worshipper and benefactor present")
	if others.has("worshipper"):
		check(not others.worshipper.wants_you(), "Uneasy: the worshipper still lets you pass")
	main._on_room_entered("Infirmary")
	check(gs.alert() == 2, "entering the Infirmary rouses the compound")
	if others.has("worshipper"):
		check(others.worshipper.wants_you(), "Roused: the worshipper turns when she sees you")
	if others.has("benefactor"):
		check(not others.benefactor.wants_you(), "Roused: the benefactor still only turns if attacked")

	# The alert is per night: a new reporter starts calm
	gs.end_night("test")
	gs.new_night()
	check(gs.alert() == 0, "the next night starts calm again")
	gs.reset_all()
	print("FAILS: %d" % fails)
	quit(1 if fails else 0)
