# CameraPanZoom.gd (Godot 4)
extends Camera2D

@export var pan_speed: float = 800.0          # pixels/sec at zoom = 1
@export var zoom_step: float = 0.1            # wheel step
@export var min_zoom: float = 0.2
@export var max_zoom: float = 3.0
@export var enable_drag_pan: bool = true      # hold MMB to drag

var _dragging := false

func _ready() -> void:
	pass
	
func _process(delta: float) -> void:
	# Use default UI actions: ui_left/right/up/down (arrows) + WASD if you map them
	var x := Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left")
	var y := Input.get_action_strength("ui_down") - Input.get_action_strength("ui_up")
	var dir := Vector2(x, y)
	if dir != Vector2.ZERO:
		# Move speed should scale with zoom so panning "feels" similar when zoomed in/out
		position += dir.normalized() * pan_speed * delta * (1.0 / zoom.x)

func _unhandled_input(event: InputEvent) -> void:
	# Mouse wheel zoom
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at_mouse(-zoom_step)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at_mouse(+zoom_step)
		elif enable_drag_pan and event.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = true

	# Drag to pan (MMB)
	if enable_drag_pan and event is InputEventMouseMotion and _dragging:
		# Motion is in screen pixels; convert by zoom to world units
		position -= event.relative * (1.0 / zoom.x)

	# Stop dragging on MMB release
	if enable_drag_pan and event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_MIDDLE:
		_dragging = false

func _zoom_at_mouse(step: float) -> void:
	var old_mouse_world := get_global_mouse_position()
	var new_zoom: float = clamp(zoom.x + step, min_zoom, max_zoom)
	zoom = Vector2(new_zoom, new_zoom)
	# Keep the point under the cursor stable:
	var new_mouse_world := get_global_mouse_position()
	position += (old_mouse_world - new_mouse_world)
