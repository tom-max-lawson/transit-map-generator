extends Node3D

# --- External references ---
@export var pathfinder_node: NodePath
@export var stop_color: Color = Color(0.1, 0.8, 0.2)
@export var line_color: Color = Color(1.0, 0.1, 0.1)
@export var stop_radius: float = 1.0
@export var line_height: float = 0.2

# --- Bus settings ---
@export var bus_scene: PackedScene
@export var bus_speed_mps: float = 20.0

# --- Mode management ---
enum ToolMode { NONE, PLACE_STOP, PLACE_LINE }
var current_mode: ToolMode = ToolMode.NONE

# --- References ---
var config: MapConfig
var graph_data: GraphData

# --- Transit data ---
var stops := {}                  # stop_id -> {node_id, pos, mesh}
var lines := []                  # array of {stops:[], mesh:MeshInstance3D}
var active_line := []            # stop IDs clicked in the current chain
var active_line_mesh: MeshInstance3D
var active_segments: Array = []  # each item: PackedVector3Array of world points for one segment

# --- Internal IDs ---
var stop_counter := 0

# --- Active buses ---
var buses := {}  # line_index -> {instance: Node3D, path: PackedVector3Array, progress: float}


# ------------------------------------------------------------
# INITIALIZATION
# ------------------------------------------------------------
func _ready() -> void:
	config = get_tree().get_root().get_node("Main/config")
	graph_data = config.graph_data
	print("Transit tool ready. Found %d nodes from graph." % graph_data.nodes.size())


# ------------------------------------------------------------
# PUBLIC INTERFACE
# ------------------------------------------------------------
func enable_place_stop_mode():
	current_mode = ToolMode.PLACE_STOP
	print("🟢 Place Stop mode enabled")

func enable_place_line_mode():
	current_mode = ToolMode.PLACE_LINE
	print("🔴 Place Line mode enabled")

func disable_tools():
	current_mode = ToolMode.NONE
	print("⚪ Tools disabled")


# ------------------------------------------------------------
# INPUT HANDLER
# ------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		match current_mode:
			ToolMode.PLACE_STOP:
				_handle_place_stop_click(event)
			ToolMode.PLACE_LINE:
				_handle_place_line_click(event)


# ------------------------------------------------------------
# STOP PLACEMENT
# ------------------------------------------------------------
func _handle_place_stop_click(event: InputEventMouseButton):
	var camera := get_viewport().get_camera_3d()
	var from = camera.project_ray_origin(event.position)
	var to = from + camera.project_ray_normal(event.position) * 1_000_000.0

	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var result = space_state.intersect_ray(query)
	if not result.has("position"):
		return

	var hit: Vector3 = result["position"]

	# Convert world → graph (UTM)
	var wx = hit.x
	var wz = hit.z
	var utm_x = wx / config.scale_factor + graph_data.info.center_x
	var utm_y = -wz / config.scale_factor + graph_data.info.center_y

	var nearest_id = str(graph_data.find_nearest_node(Vector2(utm_x, utm_y)))
	if nearest_id == "":
		return

	var stop_id = "stop_%d" % stop_counter
	stop_counter += 1

	var pos2 = graph_data.nodes[nearest_id]
	var world_pos = Vector3(
		(pos2.x - graph_data.info.center_x) * config.scale_factor,
		0.05,
		-(pos2.y - graph_data.info.center_y) * config.scale_factor
	)

	# Create visual marker
	var sphere := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = stop_radius
	mesh.height = stop_radius * 2.0
	sphere.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = stop_color
	sphere.set_surface_override_material(0, mat)
	add_child(sphere)
	sphere.global_position = world_pos

	stops[stop_id] = {"node_id": nearest_id, "pos": world_pos, "mesh": sphere}
	print("🚏 Added stop:", stop_id, "at node", nearest_id)


# ------------------------------------------------------------
# TRANSIT LINE CREATION
# ------------------------------------------------------------
func _handle_place_line_click(event: InputEventMouseButton):
	var camera := get_viewport().get_camera_3d()
	var from = camera.project_ray_origin(event.position)
	var to = from + camera.project_ray_normal(event.position) * 1_000_000.0

	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var result = space_state.intersect_ray(query)
	if not result.has("position"):
		return

	var hit: Vector3 = result["position"]
	var clicked_stop_id = _find_nearest_stop(hit, 50.0)
	if clicked_stop_id == "":
		return

	print("Clicked stop:", clicked_stop_id)

	if active_line.is_empty():
		active_line = [clicked_stop_id]
		_start_new_line_mesh()
		return

	var last_stop_id = active_line[-1]
	var start_node = stops[last_stop_id]["node_id"]
	var goal_node = stops[clicked_stop_id]["node_id"]
	var path = _find_path_a_star(str(start_node), str(goal_node))

	# Close loop
	if clicked_stop_id == active_line[0] and active_line.size() > 1:
		_draw_path_segment(path)
		print("✅ Line closed")
		var new_line = {"stops": active_line.duplicate(), "mesh": active_line_mesh}
		lines.append(new_line)
		_spawn_bus_for_line(lines.size() - 1)
		active_line = []
		active_line_mesh = null
		return

	_draw_path_segment(path)
	active_line.append(clicked_stop_id)


# ------------------------------------------------------------
# GEOMETRY HELPERS
# ------------------------------------------------------------
func _start_new_line_mesh():
	active_segments.clear()
	active_line_mesh = MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = false
	mat.albedo_color = line_color
	active_line_mesh.material_override = mat
	add_child(active_line_mesh)
	print("Started new line chain")


func _draw_path_segment(path: Array):
	if path.is_empty():
		return

	var seg := graph_data.expand_path_to_geometry(path)
	active_segments.append(seg)

	var am := ArrayMesh.new()
	for s in active_segments:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = s
		am.add_surface_from_arrays(Mesh.PRIMITIVE_LINE_STRIP, arrays)
	active_line_mesh.mesh = am

# ------------------------------------------------------------
# BUS SIMULATION
# ------------------------------------------------------------
func _process(delta: float) -> void:
	for line_index in buses.keys():
		var bus = buses[line_index]
		var path: PackedVector3Array = bus["path"]
		if path.size() < 2:
			continue

		bus["progress"] += bus_speed_mps * delta
		var total_len = _path_length(path)
		bus["progress"] = fmod(bus["progress"], total_len)

		var new_pos = _interpolate_path(path, bus["progress"])
		bus["instance"].global_position = new_pos

		var next_pos = _interpolate_path(path, bus["progress"] + 2.0)
		var dir = (next_pos - new_pos).normalized()

		var basis_x = dir
		var basis_y = Vector3.UP
		var basis_z = dir.cross(Vector3.UP).normalized()
		var xf = Transform3D()
		xf.basis = Basis(basis_x, basis_y, basis_z).orthonormalized()
		xf.origin = new_pos
		bus["instance"].global_transform = xf


func _spawn_bus_for_line(line_index: int):
	if bus_scene == null:
		print("⚠️ No bus_scene assigned")
		return

	var line = lines[line_index]
	var stop_ids = line["stops"]
	if stop_ids.size() < 2:
		return

	var full_path: PackedVector3Array = []
	for i in range(stop_ids.size()):
		var next_i = (i + 1) % stop_ids.size()
		var start_id = stops[stop_ids[i]]["node_id"]
		var goal_id = stops[stop_ids[next_i]]["node_id"]
		var path_ids = _find_path_a_star(start_id, goal_id)
		var geom_path = graph_data.expand_path_to_geometry(path_ids)
		for p in geom_path:
			full_path.append(p)

	var bus_instance = bus_scene.instantiate()
	add_child(bus_instance)
	bus_instance.global_position = full_path[0]
	print("🚌 Spawned looping bus for line", line_index, "with", full_path.size(), "points")

	buses[line_index] = {
		"instance": bus_instance,
		"path": full_path,
		"progress": 0.0
	}


# ------------------------------------------------------------
# PATH HELPERS
# ------------------------------------------------------------
func _path_length(path: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(path.size() - 1):
		total += path[i].distance_to(path[i + 1])
	return total


func _interpolate_path(path: PackedVector3Array, dist: float) -> Vector3:
	var accumulated := 0.0
	for i in range(path.size() - 1):
		var seg_len = path[i].distance_to(path[i + 1])
		if accumulated + seg_len >= dist:
			var t = (dist - accumulated) / seg_len
			return path[i].lerp(path[i + 1], t)
		accumulated += seg_len
	return path[-1]


# ------------------------------------------------------------
# UTILITY HELPERS
# ------------------------------------------------------------
func _find_nearest_stop(hit_pos: Vector3, radius: float) -> String:
	var nearest_id := ""
	var nearest_dist := radius * radius
	for id in stops.keys():
		var d = hit_pos.distance_squared_to(stops[id]["pos"])
		if d < nearest_dist:
			nearest_id = id
			nearest_dist = d
	return nearest_id


func _find_path_a_star(start_id: String, goal_id: String) -> Array:
	var open_set: Array = [start_id]
	var came_from = {}
	var g_score = {start_id: 0.0}
	var f_score = {start_id: _heuristic(start_id, goal_id)}

	while open_set.size() > 0:
		var current = open_set[0]
		var best_f = f_score.get(current, INF)
		for n in open_set:
			var f = f_score.get(n, INF)
			if f < best_f:
				current = n
				best_f = f

		if current == goal_id:
			return _reconstruct_path(came_from, current)

		open_set.erase(current)
		for e in graph_data.edges.get(current, []):
			var neighbor = e["target"]
			var tentative_g = g_score.get(current, INF) + float(e["length"])
			if tentative_g < g_score.get(neighbor, INF):
				came_from[neighbor] = current
				g_score[neighbor] = tentative_g
				f_score[neighbor] = tentative_g + _heuristic(neighbor, goal_id)
				if neighbor not in open_set:
					open_set.append(neighbor)
	return []


func _heuristic(a_id: String, b_id: String) -> float:
	return graph_data.nodes[a_id].distance_to(graph_data.nodes[b_id])


func _reconstruct_path(came_from: Dictionary, current: String) -> Array:
	var total: Array = [current]
	while came_from.has(current):
		current = came_from[current]
		total.push_front(current)
	return total
