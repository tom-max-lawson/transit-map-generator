extends Camera3D

@export var move_speed: float = 30.0
@export var boost_multiplier: float = 3.0
@export var look_sensitivity: float = 0.2

var _yaw := 0.0
var _pitch := 0.0
var _rotating := false


func _ready():
	if visible:
		current = true  # make this the current camera
	print("🎥 Free-fly camera active — hold Right Mouse to look around.")


func _unhandled_input(event):
	# Enable/disable look mode
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_rotating = event.pressed
		Input.set_mouse_mode(
			Input.MOUSE_MODE_CAPTURED if _rotating else Input.MOUSE_MODE_VISIBLE
		)

	# Mouse look while rotating
	if _rotating and event is InputEventMouseMotion:
		_yaw -= event.relative.x * look_sensitivity
		_pitch -= event.relative.y * look_sensitivity
		_pitch = clamp(_pitch, -89.9, 89.9)
		rotation_degrees = Vector3(_pitch, _yaw, 0)


func _process(delta):
	var dir := Vector3.ZERO

	# Movement — WASD or arrow keys
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir -= transform.basis.z
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir += transform.basis.z
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir -= transform.basis.x
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir += transform.basis.x

	if dir != Vector3.ZERO:
		dir = dir.normalized()

	var speed := move_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= boost_multiplier

	global_position += dir * speed * delta
