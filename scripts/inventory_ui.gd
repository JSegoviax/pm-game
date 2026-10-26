extends Control
## The inventory screen. Pauses the game while open.
## Six slots, like the originals: what you carry is a decision.

signal closed

const COLS := 3
const SLOT_W := 70.0
const SLOT_H := 34.0

var player: Node  # set by main
var hud: Node     # set by main

var _sel := 0
var _slots: Array = []
var _header: Label
var _cond: Label
var _desc: Label
var _footer: Label
var _evidence: Label
var _style := StyleBoxFlat.new()
var _style_sel := StyleBoxFlat.new()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.02, 0.03, 0.97)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_header = _text(12, Vector2(16, 12), Vector2(150, 16))
	_header.text = "ITEMS"
	_cond = _text(10, Vector2(150, 14), Vector2(154, 16))
	_cond.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	for s in [_style, _style_sel]:
		s.bg_color = Color(0.10, 0.10, 0.12)
		s.set_border_width_all(1)
		s.border_color = Color(0.30, 0.30, 0.34)
	_style_sel.border_color = Color(0.90, 0.76, 0.45)
	_style_sel.set_border_width_all(2)

	var left := (320.0 - COLS * SLOT_W - (COLS - 1) * 6.0) / 2.0
	for i in GameState.MAX_SLOTS:
		var p := Panel.new()
		p.position = Vector2(left + (i % COLS) * (SLOT_W + 6.0), 44 + (i / COLS) * (SLOT_H + 6.0))
		p.size = Vector2(SLOT_W, SLOT_H)
		add_child(p)
		var l := Label.new()
		l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_font_size_override("font_size", 8)
		p.add_child(l)
		_slots.append({"panel": p, "label": l})

	_desc = _text(9, Vector2(20, 132), Vector2(280, 60))
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_evidence = _text(8, Vector2(20, 186), Vector2(280, 26))
	_evidence.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_evidence.add_theme_color_override("font_color", Color(0.90, 0.76, 0.45))
	_footer = _text(8, Vector2(16, 216), Vector2(288, 14))
	_footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_footer.add_theme_color_override("font_color", Color(0.62, 0.62, 0.66))


func _text(size: int, pos: Vector2, box: Vector2) -> Label:
	var l := Label.new()
	l.position = pos
	l.size = box
	l.add_theme_font_size_override("font_size", size)
	add_child(l)
	return l


func open() -> void:
	visible = true
	get_tree().paused = true
	_sel = clampi(_sel, 0, GameState.MAX_SLOTS - 1)
	_refresh("")


func close() -> void:
	visible = false
	get_tree().paused = false
	closed.emit()


func _process(_delta: float) -> void:
	if not visible:
		return
	var moved := true
	if Input.is_action_just_pressed("turn_left"):
		_sel = (_sel - 1 + GameState.MAX_SLOTS) % GameState.MAX_SLOTS
	elif Input.is_action_just_pressed("turn_right"):
		_sel = (_sel + 1) % GameState.MAX_SLOTS
	elif Input.is_action_just_pressed("move_forward"):
		_sel = (_sel - COLS + GameState.MAX_SLOTS) % GameState.MAX_SLOTS
	elif Input.is_action_just_pressed("move_back"):
		_sel = (_sel + COLS) % GameState.MAX_SLOTS
	else:
		moved = false
	if moved:
		_refresh("")
	elif Input.is_action_just_pressed("interact"):
		_use()
	elif Input.is_action_just_pressed("cancel") or Input.is_action_just_pressed("inventory"):
		close()


func _selected_id() -> String:
	return GameState.inventory[_sel] if _sel < GameState.inventory.size() else ""


func _use() -> void:
	var id := _selected_id()
	if id == "":
		return
	var item: Dictionary = GameState.ITEMS[id]
	GameState.log_event("use", {"id": id, "health": player.health})
	match item.kind:
		"heal":
			if player.health >= player.MAX_HEALTH:
				_refresh("You don't need this yet.")
				return
			player.heal(item.amount)
			GameState.remove_item(id)
			_refresh("You wrap the worst of it. Better.")
		"key":
			_refresh("It goes in a lock somewhere. Use doors and it will be used automatically.")
		"melee", "gun":
			GameState.equipped = "" if GameState.equipped == id else id
			_refresh(("Ready: " + GameState.weapon_label() + ". Hold [{aim}] to raise it.") if GameState.equipped != "" else "You put it away.")
		"finisher":
			_refresh("Use it on a body on the floor, before it gets back up.")


func _refresh(note: String) -> void:
	for i in _slots.size():
		var id: String = GameState.inventory[i] if i < GameState.inventory.size() else ""
		var label := GameState.item_name(id) if id != "" else "-"
		if id != "" and GameState.ITEMS[id].kind in ["melee", "gun"]:
			label = GameState.weapon_label() if id == GameState.equipped else label
			if id == GameState.equipped:
				label = "> " + label
		_slots[i].label.text = label
		_slots[i].panel.add_theme_stylebox_override("panel", _style_sel if i == _sel else _style)
	var c: String = player.condition()
	_cond.text = "Condition: " + c
	var colors := {"Fine": Color(0.55, 0.85, 0.5), "Caution": Color(0.95, 0.75, 0.3), "Danger": Color(0.95, 0.3, 0.25)}
	_cond.add_theme_color_override("font_color", colors[c])
	var id := _selected_id()
	if note != "":
		_desc.text = hud.keys(note)
	else:
		_desc.text = hud.keys(GameState.ITEMS[id].desc) if id != "" else "Empty."
	_footer.text = hud.keys("[{interact}] Use / ready    [{inventory}] Close")
	if GameState.leads.is_empty():
		_evidence.text = ""
	else:
		var names := GameState.leads.map(func(l) -> String: return GameState.item_name(l))
		_evidence.text = "Notebook, not yet sent: " + ", ".join(names)
