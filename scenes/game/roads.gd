extends Node3D

@export var height_offset: float = 0.05
@export var line_color: Color = Color(0.15, 0.15, 0.15)
@export var edges_per_batch: int = 1000

var config: MapConfig
var graph_data: GraphData

func _ready() -> void:
	config = get_tree().get_root().get_node("Main/config")
	graph_data = config.graph_data

	if graph_data == null:
		push_error("❌ Roads: GraphData not loaded in config.")
		return

	print("🛣 Roads: Rendering %d edges in batches of %d"
		% [graph_data.edges.size(), edges_per_batch])

	_draw_batched_roads()

func _draw_batched_roads() -> void:
	var info = graph_data.info
	var cx = info.center_x
	var cy = info.center_y
	var world_scale = config.scale_factor  # ← use a non-reserved name

	var batch_mesh := ImmediateMesh.new()
	var edge_counter := 0
	var mesh_counter := 0

	batch_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	batch_mesh.surface_set_color(line_color)

	for u in graph_data.edges.keys():
		for e in graph_data.edges[u]:
			if not e.has("geometry") or e["geometry"].size() < 2:
				continue

			var geom: Array = e["geometry"]
			for i in range(geom.size() - 1):
				var c1 = geom[i]
				var c2 = geom[i + 1]
				var x1 = (float(c1[0]) - cx) * world_scale
				var z1 = -(float(c1[1]) - cy) * world_scale
				var x2 = (float(c2[0]) - cx) * world_scale
				var z2 = -(float(c2[1]) - cy) * world_scale
				batch_mesh.surface_add_vertex(Vector3(x1, height_offset, z1))
				batch_mesh.surface_add_vertex(Vector3(x2, height_offset, z2))

			edge_counter += 1
			if edge_counter >= edges_per_batch:
				batch_mesh.surface_end()
				_commit_batch(batch_mesh, mesh_counter)
				mesh_counter += 1
				edge_counter = 0
				batch_mesh = ImmediateMesh.new()
				batch_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
				batch_mesh.surface_set_color(line_color)

	batch_mesh.surface_end()
	if edge_counter > 0:
		_commit_batch(batch_mesh, mesh_counter)

	print("✅ Roads rendered in %d mesh batches." % mesh_counter)

func _commit_batch(mesh: ImmediateMesh, index: int) -> void:
	if mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.name = "RoadBatch_%d" % index
	add_child(mi)
