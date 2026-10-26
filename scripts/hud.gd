extends CanvasLayer
## On-screen text: messages, prompts, condition, version, performance stats,
## tutorial hints, menus. Shows keyboard or gamepad buttons depending on what you last used.

signal _picked(index: int)

const KEYS := {
	"move": "W/S", "turn": "A/D", "run": "Shift", "interact": "E",
	"inventory": "Tab", "cancel": "Esc", "debug": "F3", "aim": "Q / Right-click",
}
const PAD := {
	"move": "Stick up/down", "turn": "Stick left/right", "run": "B", "interact": "A",
	"inventory": "Y", "cancel": "B", "debug": "Back", "aim": "R1",
}
const TEXT := Color(0.92, 0.90, 0.86)
const GOLD := Color(0.90, 0.76, 0.45)
const DIM := Color(0.62, 0.62, 0.66)

var pad := false

var _flash: ColorRect
var _fade: ColorRect
var _message: Label
var _prompt: Label
var _condition: Label
var _version: Label
var _debug: Label
var _weapon: Label
var _hint: Label
var _menu: ColorRect
var _menu_title: Label
var _menu_sub: Label
var _menu_opts: Label

var _message_t := 0.0
var _cond_t := 0.0
var _hint_persist := ""
var _hint_temp := ""
var _hint_temp_t := 0.0
var _debug_on := true
var _debug_t := 0.0
var _vp_rid: RID

var _choice_active := false
var _options: Array = []
var _sel := 0
var _allow_cancel := true
var _arm := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 10

	_flash = _rect(Color(0.6, 0, 0, 0))
	_fade = _rect(Color(0, 0, 0, 0))

	_message = _label(10, HORIZONTAL_ALIGNMENT_CENTER)
	_message.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_message.offset_left = 16
	_message.offset_right = -16
	_message.offset_bottom = -16

	_prompt = _label(9, HORIZONTAL_ALIGNMENT_RIGHT, GOLD)
	_prompt.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_prompt.offset_left = -200
	_prompt.offset_right = -6
	_prompt.offset_top = -14
	_prompt.offset_bottom = -2

	_weapon = _label(9, HORIZONTAL_ALIGNMENT_LEFT, GOLD)
	_weapon.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_weapon.offset_left = 6
	_weapon.offset_right = 200
	_weapon.offset_top = -14
	_weapon.offset_bottom = -2

	_condition = _label(10, HORIZONTAL_ALIGNMENT_LEFT)
	_condition.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_condition.offset_left = 6
	_condition.offset_top = 4

	_version = _label(7, HORIZONTAL_ALIGNMENT_RIGHT, DIM)
	_version.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_version.offset_left = -120
	_version.offset_right = -4
	_version.offset_top = 2
	_version.text = "P.M. v" + GameState.VERSION

	_debug = _label(7, HORIZONTAL_ALIGNMENT_RIGHT, DIM)
	_debug.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_debug.offset_left = -120
	_debug.offset_right = -4
	_debug.offset_top = 12

	_hint = _label(8, HORIZONTAL_ALIGNMENT_CENTER, GOLD)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_hint.offset_left = -95
	_hint.offset_right = 95
	_hint.offset_top = 22

	_menu = _rect(Color(0, 0, 0, 0.75))
	_menu.visible = false
	_menu_title = _label(12, HORIZONTAL_ALIGNMENT_CENTER, TEXT, _menu)
	_menu_title.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_menu_title.offset_top = 60
	_menu_title.offset_left = 20
	_menu_title.offset_right = -20
	_menu_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_menu_sub = _label(8, HORIZONTAL_ALIGNMENT_CENTER, DIM, _menu)
	_menu_sub.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_menu_sub.offset_top = 112
	_menu_sub.offset_left = 30
	_menu_sub.offset_right = -30
	_menu_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_menu_opts = _label(10, HORIZONTAL_ALIGNMENT_CENTER, TEXT, _menu)
	_menu_opts.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_menu_opts.offset_top = 140

	_vp_rid = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp_rid, true)


func _rect(color: Color) -> ColorRect:
	var r := ColorRect.new()
	r.color = color
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(r)
	return r


func _label(size: int, align: HorizontalAlignment, color := TEXT, parent: Node = null) -> Label:
	var l := Label.new()
	l.horizontal_alignment = align
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color.BLACK)
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	(parent if parent != null else self).add_child(l)
	return l


# ---------------------------------------------------------------- public

## Replaces {interact}, {run} and so on with the right key or button name.
func keys(text: String) -> String:
	var map := PAD if pad else KEYS
	for k in map:
		text = text.replace("{%s}" % k, map[k])
	return text


func show_message(text: String, seconds := 2.5) -> void:
	if text != "":
		GameState.log_event("message", {"text": keys(text)})
	_message.text = keys(text)
	_message_t = seconds


## The weapon readout in the bottom-left corner, shown while aiming.
func set_weapon(text: String) -> void:
	_weapon.text = text


func set_prompt(text: String) -> void:
	_prompt.text = keys(text)


func show_condition(c: String, seconds := 2.5) -> void:
	var colors := {"Fine": Color(0.55, 0.85, 0.5), "Caution": Color(0.95, 0.75, 0.3), "Danger": Color(0.95, 0.3, 0.25)}
	_condition.text = "Condition: " + c
	_condition.add_theme_color_override("font_color", colors.get(c, TEXT))
	_cond_t = seconds


func flash() -> void:
	_flash.color.a = 0.55
	create_tween().tween_property(_flash, "color:a", 0.0, 0.6)


func fade(to_alpha: float, seconds: float) -> Tween:
	var t := create_tween()
	t.tween_property(_fade, "color:a", to_alpha, seconds)
	return t


func set_black(on: bool) -> void:
	_fade.color.a = 1.0 if on else 0.0


## A hint that stays until replaced (tutorial steps).
func set_hint(text: String) -> void:
	_hint_persist = text


## A hint that shows for a few seconds, then gives the slot back.
func flash_hint(text: String, seconds := 5.0) -> void:
	GameState.log_event("hint", {"text": keys(text)})
	_hint_temp = text
	_hint_temp_t = seconds


## Shows a menu and waits for a pick. Returns the option index, or -1 if cancelled.
func choose(title: String, options: Array, allow_cancel := true, subtitle := "", big := false) -> int:
	_options = options
	_sel = 0
	_allow_cancel = allow_cancel
	_arm = 2
	_menu.color = Color(0, 0, 0, 1.0 if big else 0.75)
	_menu_title.add_theme_font_size_override("font_size", 40 if big else 11)
	# Long bodies (evidence, dispatches, the post-mortem) move everything up to make room.
	var long := not big and subtitle.length() > 70
	_menu_title.offset_top = 40 if big else (24 if long else 70)
	_menu_sub.offset_top = 48 if long else 112
	_menu_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if subtitle.count("\n") > 2 else HORIZONTAL_ALIGNMENT_CENTER
	_menu_sub.add_theme_color_override("font_color", TEXT if long else DIM)
	_menu_opts.offset_top = 156 if big else (182 if long else 140)
	_menu_title.text = title
	_menu_sub.text = subtitle
	_menu.visible = true
	_choice_active = true
	_refresh_menu()
	GameState.log_event("menu", {"title": title, "options": options, "body": subtitle})
	var picked: int = await _picked
	GameState.log_event("picked", {"option": options[picked] if picked >= 0 and picked < options.size() else "cancelled"})
	_choice_active = false
	_menu.visible = false
	return picked


# ---------------------------------------------------------------- loop

func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf(event.axis_value) > 0.5):
		pad = true
	elif event is InputEventKey or event is InputEventMouseButton:
		pad = false


func _process(delta: float) -> void:
	if _message_t > 0.0:
		_message_t -= delta
		if _message_t <= 0.0:
			_message.text = ""
	if _cond_t > 0.0:
		_cond_t -= delta
		if _cond_t <= 0.0:
			_condition.text = ""

	if _hint_temp_t > 0.0:
		_hint_temp_t -= delta
	_hint.text = keys(_hint_temp if _hint_temp_t > 0.0 else _hint_persist)
	_hint.visible = not _choice_active
	_message.visible = not _choice_active
	_weapon.visible = not _choice_active

	if Input.is_action_just_pressed("debug_toggle"):
		_debug_on = not _debug_on
	_debug.visible = _debug_on and not _choice_active
	_debug_t -= delta
	if _debug_on and _debug_t <= 0.0:
		_debug_t = 0.25
		_update_debug()

	if _choice_active:
		_menu_input()


func _update_debug() -> void:
	var fps := Engine.get_frames_per_second()
	var cpu := (Performance.get_monitor(Performance.TIME_PROCESS) + Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
	cpu += RenderingServer.viewport_get_measured_render_time_cpu(_vp_rid) + RenderingServer.get_frame_setup_time_cpu()
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(_vp_rid)
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var mem := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	var text := "%d FPS\nCPU %.1f ms\nGPU %s\n%d draws  %d MB" % [
		fps, cpu, ("%.1f ms" % gpu) if gpu > 0.0 else "n/a", draws, int(mem)]
	# Which night this is, so a strange or broken night can be reported and replayed.
	if GameState.night_seed != 0:
		text += "\nReporter #%d\nSeed %d" % [int(GameState.meta.reporter), GameState.night_seed]
	_debug.text = text


func _menu_input() -> void:
	if _arm > 0:
		_arm -= 1
		return
	var n := _options.size()
	if Input.is_action_just_pressed("move_forward"):
		_sel = (_sel - 1 + n) % n
		_refresh_menu()
	elif Input.is_action_just_pressed("move_back"):
		_sel = (_sel + 1) % n
		_refresh_menu()
	elif Input.is_action_just_pressed("interact"):
		_picked.emit(_sel)
	elif _allow_cancel and Input.is_action_just_pressed("cancel"):
		_picked.emit(-1)


func _refresh_menu() -> void:
	var lines := []
	for i in _options.size():
		lines.append(("> %s <" if i == _sel else "%s") % _options[i])
	lines.append("")
	lines.append(keys("[{interact}] Select" + ("    [{cancel}] Back" if _allow_cancel else "")))
	_menu_opts.text = "\n".join(lines)
