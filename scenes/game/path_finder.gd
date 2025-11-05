extends Node3D

@export var click_height: float = 2.0
@export var line_color: Color = Color(1.0, 0.0, 0.0)

var config: MapConfig
var graph_data: GraphData

var click_points: Array = []
var start_node: String
var end_node: String
var path_line: MeshInstance3D
var start_marker: MeshInstance3D
var end_marker: MeshInstance3D


# ------------------------------------------------------------
# INITIALIZATION
# ------------------------------------------------------------
func _ready() -> void:
	config = get_tree().get_root().get_node("Main/config")
	graph_data = config.graph_data

	# Create path mesh holder
	path_line = MeshInstance3D.new()
	add_child(path_line)

	# Create start/end markers
	start_marker = _create_marker(Color(0.1, 1.0, 0.1)) # green
	end_marker = _create_marker(Color(1.0, 0.1, 0.1))   # red
	add_child(start_marker)
	add_child(end_marker)
	start_marker.visible = false
	end_marker.visible = false

	print("PathFinder ready with %d nodes, %d edges" % [graph_data.nodes.size(), graph_data.edges.size()])


# ------------------------------------------------------------
# INPUT HANDLER
# ------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
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

		click_points.append(nearest_id)
		print("Clicked node ", nearest_id)

		# Position a marker where the user clicked
		var pos2 = graph_data.nodes[nearest_id]
		var pos3d = Vector3(
			(pos2.x - graph_data.info.center_x) * config.scale_factor,
			hit.y + 0.1,
			-(pos2.y - graph_data.info.center_y) * config.scale_factor
		)

		if click_points.size() == 1:
			start_marker.position = pos3d
			start_marker.visible = true
			end_marker.visible = false
		elif click_points.size() == 2:
			end_marker.position = pos3d
			end_marker.visible = true

			start_node = click_points[0]
			end_node = click_points[1]
			var path = graph_data.find_path_a_star(start_node, end_node)
			_draw_path_geometry(path)
			click_points.clear()


# ------------------------------------------------------------
# DRAWING
# ------------------------------------------------------------
func _draw_path_geometry(path: Array) -> void:
	if path.is_empty():
		print("No path found.")
		return

	var world_points = graph_data.expand_path_to_geometry(path)
	if world_points.is_empty():
		print("No geometry points found for path.")
		return

	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	mesh.surface_set_color(line_color)

	for p in world_points:
		mesh.surface_add_vertex(p + Vector3(0, click_height, 0))

	mesh.surface_end()

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = false
	mat.albedo_color = line_color
	mat.emission_enabled = true
	mat.emission = line_color
	mat.emission_energy_multiplier = 1.3

	path_line.mesh = mesh
	path_line.material_override = mat

	print("Path length (m): ", _path_length(world_points))


# ------------------------------------------------------------
# PATH HELPERS
# ------------------------------------------------------------
func _path_length(path: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(path.size() - 1):
		total += path[i].distance_to(path[i + 1])
	return total


# ------------------------------------------------------------
# UTILITY HELPERS
# ------------------------------------------------------------
func _create_marker(color: Color) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = 50.0
	mesh.height = 50.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mesh.material = mat
	var marker := MeshInstance3D.new()
	marker.mesh = mesh
	return marker
