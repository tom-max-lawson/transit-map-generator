extends RichTextLabel

@export var monitored_nodes: Array[NodePath] = []	# references to nodes whose state we want to print
@export var toggle_key: StringName = "F1"
@export var update_interval: float = 0.25			# seconds between text refresh

var _visible: bool = false
var _time_accum: float = 0.0


func _ready() -> void:
	set_visible(_visible)
	# Fill the screen
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0
	offset_top = 0
	offset_right = 0
	offset_bottom = 0

	set_use_bbcode(true)
	set_scroll_active(false)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# StyleBox background for the label
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.55)	# translucent black
	sb.set_border_width_all(0)
	sb.set_corner_radius_all(0)
	add_theme_stylebox_override("normal", sb)	# key for RichTextLabel

	# Optional: outline/shadow to boost readability
	add_theme_constant_override("outline_size", 4)
	add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	add_theme_constant_override("shadow_size", 2)
	add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	add_theme_constant_override("shadow_offset_x", 2)
	add_theme_constant_override("shadow_offset_y", 2)


func _process(delta: float) -> void:
	# Toggle visibility with keypress
	if Input.is_action_just_pressed("toggle_debug"):
		_visible = !_visible
		visible = _visible
		if _visible:
			_update_text(true)

	if not _visible:
		return

	_time_accum += delta
	if _time_accum >= update_interval:
		_update_text()
		_time_accum = 0.0


func _update_text(force: bool = false) -> void:
	var sb := "[b][color=yellow]=== DEBUG INFO ===[/color][/b]\n\n"

	for np in monitored_nodes:
		var node = get_node_or_null(np)
		if node == null:
			sb += "[color=gray]" + str(np) + " not found[/color]\n"
			continue

		sb += "[b]" + str(np) + "[/b]\n"
		if "get_debug_info" in node:
			var info = node.get_debug_info()
			if typeof(info) == TYPE_DICTIONARY:
				for k in info.keys():
					sb += "  " + str(k) + ": " + str(info[k]) + "\n"
			else:
				sb += "  " + str(info) + "\n"
		else:
			sb += "  (no get_debug_info())\n"
		sb += "\n"

	text = sb
