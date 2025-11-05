extends Node3D

@export var debug_draw_grid: bool = false
@export var debug_draw_pois: bool = false

var demand: DemandModel
var _debug_visuals: Array = []
var _grid_visual: MultiMeshInstance3D
var _poi_visual: MultiMeshInstance3D

var config: MapConfig

func _ready():
	config = get_tree().get_root().get_node("Main/config")
	demand = config.demand_model
	
	# Debug visualisation
	_update_debug_grid()
	_update_debug_pois()

# CLICK HANDLING
func _unhandled_input(event):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var cam := get_viewport().get_camera_3d()
		if cam == null:
			return

		var hit_pos = _ray_hit(event.position, cam)
		if hit_pos == null:
			return

		var results = demand.compute_demand(hit_pos)
		_show_debug_visuals(hit_pos, results)


func _ray_hit(screen_pos: Vector2, cam: Camera3D) -> Variant:
	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos) * 5000.0

	var query := PhysicsRayQueryParameters3D.new()
	query.from = from
	query.to = to
	query.collide_with_bodies = true
	query.collide_with_areas = true

	var result = get_world_3d().direct_space_state.intersect_ray(query)
	return result.get("position", null)


# DEBUG VISUALS
func _clear_debug_visuals() -> void:
	for v in _debug_visuals:
		if is_instance_valid(v):
			v.queue_free()
	_debug_visuals.clear()


func _show_debug_visuals(origin: Vector3, results: Array) -> void:
	_clear_debug_visuals()

	if results.is_empty():
		print("No demand here")
		return

	for r in results:
		var p: Vector3 = r["world_pos"]
		var prob: float = r["prob"]

		var marker := MeshInstance3D.new()
		marker.mesh = SphereMesh.new()
		marker.mesh.radius = 2.0
		marker.position = p

		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.2, 0.2)
		marker.material_override = mat
		add_child(marker)
		_debug_visuals.append(marker)

		var arc := _draw_arc(origin, p, prob)
		_debug_visuals.append(arc)

# Thick, 3D “tube” arc built from cylinder segments
func _draw_arc(a: Vector3, b: Vector3, prob: float) -> Node3D:
	var container := Node3D.new()
	add_child(container)

	# Height and thickness scale with probability
	var arc_height := 80.0 + prob * 300.0
	var radius = 2*lerp(0.4, 2.5, prob)  # thickness
	var steps := 20

	var prev := a
	prev.y += arc_height * 4.0 * 0.0 * (1.0 - 0.0)

	for i in range(1, steps + 1):
		var t := float(i) / float(steps)
		var pos := a.lerp(b, t)
		pos.y += arc_height * 4.0 * t * (1.0 - t)

		var seg := _make_cylinder_between(prev, pos, radius, Color(prob, 0.1, 1.0 - prob, 1.0))
		if seg:
			container.add_child(seg)

		prev = pos

	return container


# Helper: cylinder oriented from p0 → p1 (CylinderMesh is Y-up)
func _make_cylinder_between(p0: Vector3, p1: Vector3, r: float, col: Color) -> MeshInstance3D:
	var dir := p1 - p0
	var len := dir.length()
	if len < 0.05:
		return null

	var cyl := MeshInstance3D.new()

	var mesh := CylinderMesh.new()
	mesh.top_radius = r
	mesh.bottom_radius = r
	mesh.height = len
	mesh.radial_segments = 12
	mesh.rings = 1
	cyl.mesh = mesh

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = col
	cyl.material_override = mat

	# Align cylinder's +Y axis with segment direction
	var n := dir / len
	var dot = clamp(Vector3.UP.dot(n), -1.0, 1.0)
	var axis := Vector3.UP.cross(n)

	var basis: Basis
	if axis.length() < 1e-6:
		# p0→p1 is parallel/antiparallel to up; rotate 180° if downward
		if dot > 0.0:
			basis = Basis()  # identity
		else:
			basis = Basis(Vector3(1, 0, 0), PI)
	else:
		basis = Basis(axis.normalized(), acos(dot))

	cyl.transform = Transform3D(basis, (p0 + p1) * 0.5)
	return cyl



# GRID DEBUG
func _update_debug_grid() -> void:
	if _grid_visual and is_instance_valid(_grid_visual):
		_grid_visual.queue_free()

	if !debug_draw_grid:
		return

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = demand.cells.size()

	_grid_visual = MultiMeshInstance3D.new()
	_grid_visual.multimesh = mm

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	_grid_visual.material_override = mat
	add_child(_grid_visual)

	var mesh := _create_cell_mesh()
	var i := 0
	for key in demand.cells.keys():
		var c = demand.cells[key]
		var ix = c["ix"]
		var iy = c["iy"]

		var center_x = demand.grid_min_x + (ix + 0.5) * demand.grid_cell_size
		var center_y = demand.grid_min_y + (iy + 0.5) * demand.grid_cell_size
		var world := demand.utm_to_world(Vector2(center_x, center_y), 0.2)

		var t := Transform3D()
		t.origin = world
		mm.set_instance_transform(i, t)
		mm.set_instance_color(i, Color(1,0,0))
		i += 1

	_grid_visual.multimesh.mesh = mesh

func _update_debug_pois() -> void:
	if _poi_visual and is_instance_valid(_poi_visual):
		_poi_visual.queue_free()

	if !debug_draw_pois:
		return

	# Flatten all POIs across all cells
	var all_pois: Array = []
	for key in demand.cells.keys():
		var cell = demand.cells[key]
		if cell.has("pois"):
			for poi in cell["pois"]:
				all_pois.append(poi)

	if all_pois.is_empty():
		print("No POIs found for debug draw.")
		return

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = all_pois.size()

	_poi_visual = MultiMeshInstance3D.new()
	_poi_visual.multimesh = mm

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	_poi_visual.material_override = mat
	add_child(_poi_visual)

	# Small red spheres
	var sphere := SphereMesh.new()
	sphere.radius = 2.0
	sphere.height = 2.0
	_poi_visual.multimesh.mesh = sphere

	var i := 0
	for poi in all_pois:
		var utm = poi["pos_utm"]
		var world := demand.utm_to_world(Vector2(utm[0], utm[1]), 0.5)
		var t := Transform3D()
		t.origin = world
		mm.set_instance_transform(i, t)
		mm.set_instance_color(i, Color(1, 0, 0))
		i += 1

	print("Drawn ", str(all_pois.size()), " POI debug markers.")


func _create_cell_mesh() -> Mesh:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)

	var hs := demand.grid_cell_size * 0.5
	var red := Color(1,0,0)

	mesh.surface_set_color(red)
	mesh.surface_add_vertex(Vector3(-hs, 0, -hs))
	mesh.surface_add_vertex(Vector3(hs, 0, -hs))
	mesh.surface_add_vertex(Vector3(hs, 0, hs))
	mesh.surface_add_vertex(Vector3(-hs, 0, hs))
	mesh.surface_add_vertex(Vector3(-hs, 0, -hs))

	mesh.surface_end()
	return mesh
