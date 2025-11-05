extends Camera3D

@export var move_speed: float = 200.0     # pan speed (units/sec)
@export var zoom_speed: float = 40.0     # scroll speed (units/sec)
@export var min_y: float = 50.0           # lowest height
@export var max_y: float = 2000.0         # highest height

func _ready() -> void:
	if visible:
		current = true  # make this the current camera

func _process(delta: float) -> void:
	var move = Vector3.ZERO

	# Move in Z–X plane (your ground)
	if Input.is_action_pressed("ui_left"):
		move.x -= 1
	if Input.is_action_pressed("ui_right"):
		move.x += 1
	if Input.is_action_pressed("ui_up"):
		move.z -= 1
	if Input.is_action_pressed("ui_down"):
		move.z += 1

	# Normalize & apply movement
	if move.length() > 0:
		move = move.normalized() * move_speed * delta
		global_position += move

func _unhandled_input(event: InputEvent) -> void:
	# Mouse wheel controls Y (vertical height)
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			global_position.y -= zoom_speed * get_process_delta_time() * global_position.y
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			global_position.y += zoom_speed * get_process_delta_time() * global_position.y

		# Clamp Y height
		global_position.y = clamp(global_position.y, min_y, max_y)
