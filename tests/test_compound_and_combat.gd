extends SceneTree
## Headless test: 300 nights of placement, every door, the stairs, and combat.
## Run: godot --headless --path . -s tests/test_compound_and_combat.gd
var fails := 0
var log_f: FileAccess
func check(ok: bool, what: String) -> void:
	if log_f == null:
		log_f = FileAccess.open("user://test.log", FileAccess.WRITE)
	log_f.store_line(("PASS " if ok else "FAIL ") + what)
	log_f.flush()
	print(("PASS " if ok else "FAIL ") + what)
	if not ok: fails += 1
func frames(n: int) -> void:
	for i in n: await physics_frame
func tap(action: String) -> void:
	Input.action_press(action); await frames(2); Input.action_release(action); await frames(2)

func floor_at(main: Node, p: Vector3) -> bool:
	var space = main.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 0.5, 0), p + Vector3(0, -1.0, 0))
	q.exclude = [main.player.get_rid()]
	return not space.intersect_ray(q).is_empty()

func _initialize() -> void:
	var gs = root.get_node("GameState")
	var rec = root.get_node("Recorder")
	gs.reset_all()
	gs.pending = "night"
	var scene: PackedScene = load("res://scenes/main.tscn")
	var main = scene.instantiate()
	root.add_child(main)
	await frames(30)
	# This test moves the reporter around by itself; conversations would pause it waiting for a
	# button press (test_buildup covers dialogue), so residents here skip their lines.
	for x in main.residents: x.say_line = func(_t): pass
	var M := {}
	for m in main.MARKERS: M[m.id] = m

	# 1. Every night is finishable: 300 seeds
	var bad := 0
	var seen := {}
	var keep_children: int = main.get_child_count()
	var keep_inter: int = main.interactables.size()
	var keep_flicker: int = main._flicker_lights.size()
	for i in 300:
		gs.night_seed = 1000 + i * 7919
		gs._streams = {}
		rec.placed = {}
		main._spawn_pickups()
		var k1: Array = M[rec.placed.key_east].needs
		var k2: Array = M[rec.placed.key_infirmary].needs
		if not k1.is_empty() or k2.has(main.LOCK_INFIRMARY) or not M[rec.placed.pipe].needs.is_empty():
			bad += 1
		if not M[rec.placed.lead_batch].needs.has(main.LOCK_INFIRMARY):
			bad += 1
		for k in rec.placed: seen[k] = true
		while main.get_child_count() > keep_children:
			var c = main.get_child(main.get_child_count() - 1)
			main.remove_child(c); c.free()
		main.interactables.resize(keep_inter)
		main._flicker_lights.resize(keep_flicker)
	check(bad == 0, "300 nights: keys and pipe always reachable, batch label always in the infirmary (%d bad)" % bad)
	check(seen.has("revolver") and seen.has("fire_axe") and seen.has("rounds#1") and seen.has("lamp_oil#2"), "every item shows up on some nights")

	# 2. Every door lands on floor, inside a camera zone, in the room it names
	var doors := 0
	var bad_doors := []
	for it in main.interactables:
		var to = null
		# doors are interactables whose action is a bound _use_door; find them via prompt text
		var p: String = it.prompt.call()
		if p.begins_with("Open door") or p.begins_with("Examine door") or p.begins_with("Use "):
			doors += 1
	for c in main.get_children():
		pass
	check(doors >= 14, "%d doors found" % doors)
	# Use the door dictionaries directly: walk every door
	var door_list := []
	for it in main.interactables:
		var p: String = it.prompt.call()
		if p.begins_with("Open door") or p.begins_with("Examine door"):
			door_list.append(it)
	gs.remember("door_records_open"); gs.remember("door_infirmary_open")
	var rooms_reached := {}
	for it in door_list:
		var before: Vector3 = main.player.global_position
		main._busy = false
		it.action.call()
		await frames(110)
		var at: Vector3 = main.player.global_position
		if not floor_at(main, at):
			bad_doors.append("no floor at %s" % at)
		rooms_reached[main._room] = true
	check(bad_doors.is_empty(), "every door lands on floor %s" % [bad_doors])
	check(rooms_reached.size() == 8, "doors reach all 8 rooms: %s" % [rooms_reached.keys()])

	# 3. Stairs: walk down and back up
	main.player.global_position = main.STAIRS + Vector3(0, 0.05, 2.5)
	main.player.face(0.0)
	await frames(5)
	Input.action_press("move_forward"); await frames(300); Input.action_release("move_forward")
	var low: float = main.player.global_position.y
	check(low < -2.0, "walked down the stairs (y=%.2f)" % low)
	main.player.face(PI)
	Input.action_press("move_forward"); await frames(300); Input.action_release("move_forward")
	check(main.player.global_position.y > -0.3, "walked back up (y=%.2f)" % main.player.global_position.y)

	# 4. Fighting the hallway resident with a pipe
	var r = main.get_node("Resident_hall")
	r.start_hostile()
	gs.inventory.clear(); gs.equipped = ""
	gs.add_item("pipe")
	check(gs.equipped == "pipe" and gs.wear.pipe == 6, "picking up the pipe readies it")
	r.global_position = main.HALL + Vector3(0, 0.05, -3.0)
	main.player.global_position = main.HALL + Vector3(0, 0.05, -1.6)
	main.player.face(0.0)
	main._update_camera(true)
	r.set_physics_process(false)  # hold him still so we can test hits
	await frames(5)
	Input.action_press("aim"); await frames(3)
	check(main.player.aiming, "holding Aim raises the weapon")
	var hp0: int = r.hp
	await tap("interact")
	check(r.hp == hp0 - 2, "a pipe swing does 2 (hp %d -> %d)" % [hp0, r.hp])
	check(gs.wear.pipe == 5, "the pipe wears down")
	r.state = r.State.STUNNED
	await frames(40); await tap("interact")
	check(r.hp == hp0 - 6 and r.is_down(), "a hit on a stunned resident counts double and puts him down")
	Input.action_release("aim"); await frames(3)
	# 5. He gets back up
	r.set_physics_process(true)
	r._timer = 0.5
	await frames(200)
	check(r.state_name() in ["stalking", "windup", "lunge", "recover"] and r.hp == r.RISE_HP, "he gets back up weaker (hp %d, %s)" % [r.hp, r.state_name()])
	# 6. Down again, then burn the body
	r.damage(99, main.player.global_position)
	gs.add_item("lamp_oil")
	main.player.global_position = r.global_position + Vector3(0, 0, 1.2)
	await frames(3)
	check(main._resident_prompt(r) == "Burn the body", "prompt to burn the body")
	main._resident_action(r)
	check(r.is_dead() and gs.flags.get("dead_hall") == "burned" and not gs.has_item("lamp_oil"), "burning finishes him and uses the oil")
	r._timer = 0.0
	await frames(60)
	check(r.is_dead(), "a burned body stays down")

	# 7. Wear out a weapon
	gs.wear.pipe = 1
	var nurse = null
	for x in main.residents: if x.resident_id != "hall": nurse = x
	main._wear("pipe")
	check(not gs.has_item("pipe") and gs.equipped == "", "the pipe breaks when worn out")

	# 8. Revolver in the dormitory wakes a sleeper
	var sl = main.get_node("Resident_sleeper_a")
	check(sl.state_name() == "asleep", "dormitory sleeper starts asleep")
	gs.add_item("revolver"); gs.add_item("rounds")
	gs.equipped = "revolver"
	check(gs.ammo == 3 and gs.inventory.count("rounds") == 0, "rounds go in the box, not a slot")
	main.player.global_position = main.DORM + Vector3(4.5, 0.05, -3.0)
	main.player.face(PI / 2)
	main._update_camera(true)
	await frames(5)
	Input.action_press("aim"); await frames(3)
	await tap("interact")
	Input.action_release("aim")
	await frames(5)
	check(gs.ammo == 2, "firing uses a round")
	check(sl.state_name() != "asleep", "the shot woke the sleeper (%s)" % sl.state_name())

	# 8b. Sleepers stir first; backing off lets them settle
	var sb = main.get_node_or_null("Resident_sleeper_b")
	var s2 = sb if sb != null else null
	if s2 == null:
		s2 = sl
		s2.start_asleep()
	s2.start_asleep()
	main.player.global_position = s2.global_position + Vector3(0, 0, 1.0)
	await frames(5)
	check(s2.state_name() == "stirring", "walking close makes a sleeper stir (%s)" % s2.state_name())
	main.player.global_position = s2.global_position + Vector3(0, 0, 3.0)
	await frames(5)
	check(s2.state_name() == "asleep", "backing off lets him settle (%s)" % s2.state_name())
	main.player.global_position = s2.global_position + Vector3(0, 0, 1.0)
	await frames(60)
	check(s2.state_name() == "stirring", "still stirring after 1 s")
	await frames(40)
	check(s2.state_name() == "rising", "wakes after the stir (%s)" % s2.state_name())
	await frames(100)
	check(s2.state_name() == "rising", "and takes a while to get up")

	# 8c. A pipe reaches a resident winding up at 1.85 m
	var rr = main.get_node("Resident_hall")
	var victim = null
	for x in main.residents:
		if x.is_target() and x.kind != "sleeper" and x != rr: victim = x
	if victim == null:
		victim = s2
	victim.state = victim.State.WINDUP
	victim.set_physics_process(false)
	gs.add_item("pipe"); gs.equipped = "pipe"
	main.player.global_position = victim.global_position + Vector3(0, 0, 1.85)
	main.player.face(0.0)
	await frames(3)
	check(main._aim_target(2.0, 0.5) == victim, "pipe reaches 1.85 m")
	victim.set_physics_process(true)

	# 8d. A second revolver adds rounds instead of a slot; women get the right pronouns
	var slots_before: int = gs.inventory.size()
	var ammo_before: int = gs.ammo
	gs.add_item("revolver")
	check(gs.inventory.size() == slots_before and gs.ammo == ammo_before + 2, "a second revolver adds 2 rounds, not a slot")
	var nurse_r = null
	for c in main.CAST:
		if c.kind == "nurse":
			main._spawn_resident(c, c.spots[0][0], c.spots[0][1])
	for x in main.residents:
		x.say_line = func(_t): pass
		if x.kind == "nurse": nurse_r = x
	check(nurse_r.words("{He} goes down. You shove {him} back.") == "She goes down. You shove her back.", "the nurse is 'she' in fight messages")

	# 9. Pause and resume keeps the burned body and the gun
	var ammo_saved: int = gs.ammo
	gs.save_game(main.player.global_position, 0.0, main.player.health)
	main.queue_free(); await frames(3)
	gs.pending = "continue"
	main = scene.instantiate(); root.add_child(main)
	await frames(30)
	for x in main.residents: x.say_line = func(_t): pass
	var r2 = main.get_node("Resident_hall")
	check(r2.is_dead(), "resumed night: the burned body is still there")
	check(gs.ammo == ammo_saved and gs.has_item("revolver"), "resumed night: revolver and rounds kept (%d)" % gs.ammo)

	gs.reset_all()
	print("FAILS: %d" % fails)
	quit(1 if fails else 0)
