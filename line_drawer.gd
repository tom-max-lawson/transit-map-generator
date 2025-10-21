# LineDrawer.gd (Godot 4)
extends Node2D

@export var station_scene: PackedScene
@export var snap_distance: float = 20.0

# Map line id -> color, e.g. {"L1": Color(1,0,0), "L2": Color(0,0,1)}
@export var line_colors: Dictionary = {
	"L1": Color(0.729, 0.475, 0.165, 1.0),
	"L2": Color(1.0, 0.027, 0.027, 1.0),
	"L3": Color(1.0, 1.0, 0.008, 1.0),
	"L4": Color(0.282, 0.733, 0.255, 1.0),
	"L5": Color(0.996, 0.835, 0.067, 1.0),
	"L6": Color(0.922, 0.639, 0.933, 1.0),
	"L7": Color(0.761, 0.737, 0.765, 1.0),
	"L8": Color(0.686, 0.055, 0.471, 1.0),
	"L9": Color(0.047, 0.047, 0.047, 1.0),
	"L10": Color(0.376, 0.396, 0.839, 1.0),
	"L11": Color(0.275, 0.706, 0.929, 1.0),
	"L12": Color(0.353, 0.812, 0.784, 1.0),
	"L13": Color(0.216, 0.545, 0.576, 1.0)
}

# Graphs
var real_graph := MetroGraph.new()  # the real ground truth graph
var transition_graph := MetroGraph.new()  # the intermediate transition graph used for animations
var schematic_graph := MetroGraph.new()  # the schematic 'metro map' graph

# Animation
var src_graph := MetroGraph.new()  # Where we're coming from
var dst_graph := MetroGraph.new()  # Where we're going to
var animation_elapsed: float = 0.0
@export var animation_duration: float = 1.2

# Possible states of the interface
enum State {
	Editing,
	Switching,
	Schematic
}

# For notifying UI
signal disable_switching
signal enable_switching

var _last_state: State
var _state: State = State.Editing
var state:
	get:
		return _state
	set(value):
		if(value == State.Switching):
			# Reset animation 
			animation_elapsed = 0.0
			emit_signal("disable_switching")  # Don't allow switching if a switch is already in progress
 			
			if(_state == State.Editing):
				src_graph = real_graph
				dst_graph = schematic_graph
				transition_graph = real_graph.duplicate(true)  # Deep copy
			elif(_state == State.Schematic):
				src_graph = schematic_graph
				dst_graph = real_graph
				transition_graph = schematic_graph.duplicate(true)  # Deep copy
		else:
			emit_signal("enable_switching")
			
		_last_state = _state
		_state = value
		queue_redraw()
				
			
		

# Thread management
var _thread: Thread
var _thread_running := false

var current_line_idx: int = 1
var current_line_id: String = "L1"
var adding_station: bool = false

# Keep references to spawned station visuals (optional)
var _station_nodes := []  # [Node2D]


func _ready():
	set_process_unhandled_input(true)
	# configure graph
	#real_graph.from_json("res://metro_graph_default.json")
	real_graph.snap_distance = snap_distance
	real_graph.line_colors = line_colors

func _process(dt: float):
	if state == State.Switching:		
		# Propagate the transition graph
		animation_elapsed += dt
		
		var t = animation_elapsed
		var T = animation_duration
		var progress = t / T

		var x_truth: float
		if progress <= 0.5:
			x_truth = 2.0 * pow(progress, 2.0)
		else:
			x_truth = 1.0 - 2.0 * pow(1.0 - progress, 2.0)
		
		# Propagate transition graph
		var src_nodes = src_graph.get_nodes()
		var dst_nodes = dst_graph.get_nodes()
		var transition_nodes = transition_graph.get_nodes()
		assert(src_nodes.size() == dst_nodes.size(), "Implementation error, src and dst graphs do not have same number of nodes")
			
		for i in range(src_nodes.size()):
			# start and end points
			var start = src_nodes[i].pos
			var end = dst_nodes[i].pos
			
			# where we should be
			var target = start + (end-start) * x_truth
			
			# position error
			var actual = transition_nodes[i].pos
			var error = target - actual
			
			# correct error
			transition_nodes[i].pos += error
			
		queue_redraw()

		if progress >= 1.0:
			if(_last_state == State.Editing):
				state = State.Schematic
			elif(_last_state == State.Schematic):
				state = State.Editing

# -------------------------------------------------
# INPUT
# -------------------------------------------------
func _unhandled_input(event):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var world_pos := get_global_mouse_position()

		# 1) Add to topology (snapping & intersections happen inside MetroGraph)
		var nid := real_graph.add_node(world_pos.x, world_pos.y, current_line_id)

		# 2) If tool is "Add Station", spawn a visible station scene at the *snapped* position
		if adding_station and station_scene:
			var snapped_pos := real_graph.get_node_pos(nid)  # requires MetroGraph.get_node_pos
			var st := station_scene.instantiate()
			add_child(st)
			st.position = snapped_pos
			_set_station_color(st, current_line_id)
			_station_nodes.append(st)

		queue_redraw()


# -------------------------------------------------
# UI CALLBACKS (connect your buttons to these)
# -------------------------------------------------
func toggle_add_station():
	adding_station = !adding_station
	print("Add Station mode:", adding_station)

func start_new_line():
	current_line_idx += 1
	current_line_id = "L" + str(current_line_idx)
	# if color not defined yet, assign a default grey so draw/export still works
	if not line_colors.has(current_line_id):
		line_colors[current_line_id] = Color(0.55, 0.55, 0.55)
	print("New line started:", current_line_id)
	real_graph.reset_line(current_line_id)

func save_to_file(path):
	var json_text := real_graph.to_json()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(json_text)
		f.close()
		print("Saved JSON to:", path)
	else:
		push_error("Failed to open " + path + " for write.")


# -------------------------------------------------
# RENDERING
# -------------------------------------------------
func _draw():
	# What to draw
	var graph: MetroGraph
	if state == State.Editing:
		graph = real_graph
	elif state == State.Switching: 
		graph = transition_graph
	elif state == State.Schematic:
		graph = schematic_graph
	
	# Draw edges from the graph
	var edges: Array = graph.get_edges()  # [{a, b, lines}]
	for e in edges:
		var a_pos: Vector2 = graph.get_node_pos(e.a)
		var b_pos: Vector2 = graph.get_node_pos(e.b)
		var col := _edge_color(e)
		draw_line(a_pos, b_pos, col, 4.0)

	# Draw nodes from the graph (small dots)
	var nodes: Array = graph.get_nodes()  # [{id, pos, label}]
	for n in nodes:
		draw_circle(n.pos, 8.0, Color(0.0, 0.0, 0.0, 1.0))  # thin outline
		draw_circle(n.pos, 6.0, Color(1.0, 1.0, 1.0, 1.0))


# -------------------------------------------------
# HELPERS
# -------------------------------------------------
func _edge_color(e: Dictionary) -> Color:
	# If an edge has multiple line ids, pick the first known color
	if e.lines.size() > 0:
		for lid in e.lines:
			if line_colors.has(lid):
				return Color(line_colors[lid])
	# fallback
	return Color(0.55, 0.55, 0.55)

func _set_station_color(station_node: Node, line_id: String) -> void:
	# assumes your Station scene root has 'outer_color' export (from your earlier Circle.gd)
	if not line_colors.has(line_id):
		station_node.outer_color = Color(0.55, 0.55, 0.55)
	else:
		station_node.outer_color = Color(line_colors[line_id])

func _transform_schematic() -> void:
	# The viewport is what is used as constraints in the schematic generation algorithm to fit the map to. So we translate/scale based on this
	var real_extent = real_graph.get_extent()
	var schematic_extent = schematic_graph.get_extent()
	
	# Doing it based on the center of the extent has a clearer look and transition imo
	var real_center = real_extent.position + real_extent.size / 2
	var schematic_center = schematic_extent.position + schematic_extent.size / 2
	
	# Perform transformation
	var translation: Vector2 = real_center - schematic_center
	var scale_x: float = real_extent.size.x / schematic_extent.size.x
	var scale_y: float = real_extent.size.y / schematic_extent.size.y
	var scaler: float = min(scale_x, scale_y)
	schematic_graph.apply_affine(scaler, translation)


func _on_add_station_pressed() -> void:
	toggle_add_station()


func _on_new_line_pressed() -> void:
	print("button pressed — calling set_input_as_handled")
	start_new_line()


func _on_generate_pressed() -> void:
	var optim_in  := ProjectSettings.globalize_path("res://metro_graph_realistic.json") 
	var optim_out := ProjectSettings.globalize_path("res://metro_graph_schematic.json")
	
	save_to_file(optim_in) # Save current graph to file
	_thread = Thread.new()
	_thread_running = true
	_thread.start(Callable(self, "_run_optimizer_thread").bind(optim_in, optim_out))

func _run_optimizer_thread(optim_in: String, optim_out: String):
	# Double-escaped backslashes for PowerShell + extra to survive godot parsing
	# Note: by default the 3rd party tool is writing UTF-16, godot only accepts UTF-8 so need to re-encode
	var ps_script := (
		"$env:PATH = \\\"$PWD\\\\transit-map-with-cdc;$env:PATH\\\"; " +
		"Get-Content \\\"" + optim_in + "\\\" | " +
		"node.exe .\\transit-map-with-cdc\\cli.js --graph | " +   # <-- pipe into Out-File
		"Out-File -Encoding utf8 \\\"" + optim_out + "\\\""
	)
	var args := PackedStringArray([
		"-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps_script
	])

	var output: Array = []
	var exit_code: int = OS.execute(
		"powershell.exe",
		args,
		output,          # Array to collect stdout
		true,            # also read stderr
		false            # don't open a console window
	)

	var text := "\n".join(output)
	call_deferred("_on_optimizer_done", exit_code, text, optim_out)

func _on_optimizer_done(exit_code: int, output_text: String, optim_out: String):
	if _thread != null:
		_thread.wait_to_finish()  # Wait to join and clear the thread, otherwise output can be corrupted
		_thread = null
		_thread_running = false
	
	print("✅ Optimizer finished with exit code:", exit_code)
	print("Output:\n", output_text)
	
	# Load the schematic
	schematic_graph.from_json(optim_out)
	_transform_schematic() # Apply affine transform to schematic so that it occupies same space as original
	state = State.Switching # switch to intermediate 'switching' mode (animation mode)	

func _on_switch_pressed() -> void:
	state = State.Switching
