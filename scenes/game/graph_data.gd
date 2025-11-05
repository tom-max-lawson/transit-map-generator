extends Resource
class_name GraphData

# ------------------------------------------------------------
# Struct-like inner class for map info
# ------------------------------------------------------------
class MapInfo:
	var center_x: float = 0.0
	var center_y: float = 0.0
	var min_x: float = 0.0
	var min_y: float = 0.0
	var max_x: float = 0.0
	var max_y: float = 0.0
	var crs: String = ""


# ------------------------------------------------------------
# Main GraphData fields
# ------------------------------------------------------------
var nodes: Dictionary = {}        # id (String or int) -> Vector2(x, y)
var edges: Dictionary = {}        # id -> [{target, length, geometry}, ...]
var info: MapInfo = MapInfo.new()
var loaded: bool = false

# Spatial index
var _rtree: RTree = null


# ------------------------------------------------------------
# Constructor
# ------------------------------------------------------------
func _init(json_path: String = ""):
	if json_path != "":
		load_graph(json_path)


# ------------------------------------------------------------
# Loads and parses the graph JSON, then computes extents
# ------------------------------------------------------------
func load_graph(json_path: String):
	if not FileAccess.file_exists(json_path):
		push_error("❌ GraphData: File not found: %s" % json_path)
		return

	var file := FileAccess.open(json_path, FileAccess.READ)
	if file == null:
		push_error("❌ GraphData: Failed to open %s" % json_path)
		return

	var parsed = JSON.parse_string(file.get_as_text())
	file.close()

	if parsed == null or not (parsed is Dictionary and parsed.has("nodes") and parsed.has("edges")):
		push_error("❌ GraphData: Invalid graph JSON format")
		return

	# Convert node dicts → Vector2
	nodes.clear()
	for id in parsed["nodes"].keys():
		var n = parsed["nodes"][id]
		var x = float(n["x"])
		var y = float(n["y"])
		nodes[id] = Vector2(x, y)

	edges = parsed["edges"]

	# Compute min/max/center directly from node coordinates
	_compute_extents()

	info.crs = str(parsed.get("crs", ""))

	loaded = true
	print("✅ GraphData loaded (%d nodes, %d edges)" % [nodes.size(), edges.size()])
	print("Extent (UTM):  min(%.2f, %.2f) → max(%.2f, %.2f)" % [
		info.min_x, info.min_y, info.max_x, info.max_y
	])
	print("Center: (%.2f, %.2f)" % [info.center_x, info.center_y])

	# --------------------------------------------------------
	# Build the RTree spatial index
	# --------------------------------------------------------
	_build_rtree()


# ------------------------------------------------------------
# Build RTree for fast nearest-node queries
# ------------------------------------------------------------
func _build_rtree():
	_rtree = RTree.new()
	var points: Array = []

	for id_str in nodes.keys():
		var node_pos: Vector2 = nodes[id_str]
		# Represent node position in world-equivalent coords (x, z)
		var pos3 := Vector3(node_pos.x, 0.0, node_pos.y)
		points.append({"pos": pos3, "data": {"id": id_str}})

	_rtree.build(points)
	print("🌳 Built RTree for road graph: %d nodes" % points.size())


# ------------------------------------------------------------
# Computes min_x, min_y, max_x, max_y, center_x, center_y
# ------------------------------------------------------------
func _compute_extents():
	if nodes.is_empty():
		push_warning("⚠️ GraphData: no nodes to compute extents")
		return

	var min_x := INF
	var min_y := INF
	var max_x := -INF
	var max_y := -INF

	for id in nodes.keys():
		var v: Vector2 = nodes[id]
		if v.x < min_x: min_x = v.x
		if v.y < min_y: min_y = v.y
		if v.x > max_x: max_x = v.x
		if v.y > max_y: max_y = v.y

	info.min_x = min_x
	info.min_y = min_y
	info.max_x = max_x
	info.max_y = max_y
	info.center_x = (min_x + max_x) * 0.5
	info.center_y = (min_y + max_y) * 0.5


# ------------------------------------------------------------
# A* PATHFINDING
# ------------------------------------------------------------
func find_path_a_star(start_id: String, goal_id: String) -> Array:
	if not nodes.has(start_id) or not nodes.has(goal_id):
		push_warning("⚠️ A*: Invalid start or goal node: %s → %s" % [start_id, goal_id])
		return []

	var open_set: Array = [start_id]
	var came_from: Dictionary = {}
	var g_score: Dictionary = {start_id: 0.0}
	var f_score: Dictionary = {start_id: _heuristic(start_id, goal_id)}

	while not open_set.is_empty():
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

		for e in edges.get(current, []):
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
	if not nodes.has(a_id) or not nodes.has(b_id):
		return 0.0
	return nodes[a_id].distance_to(nodes[b_id])


func _reconstruct_path(came_from: Dictionary, current: String) -> Array:
	var total: Array = [current]
	while came_from.has(current):
		current = came_from[current]
		total.push_front(current)
	return total


# ------------------------------------------------------------
# FAST NEAREST-NODE QUERY USING RTREE
# ------------------------------------------------------------
func find_nearest_node(pos_utm: Vector2) -> int:
	if nodes.is_empty():
		return -1

	if _rtree == null or _rtree.root == null:
		# Fallback to linear search
		push_warning("⚠️ GraphData: RTree not built, using linear search")
		var nearest_id := -1
		var nearest_dist := INF
		for id_str in nodes.keys():
			var id := int(id_str)
			var node_pos: Vector2 = nodes[id_str]
			var d = pos_utm.distance_squared_to(node_pos)
			if d < nearest_dist:
				nearest_dist = d
				nearest_id = id
		return nearest_id

	# Convert to RTree 3D space (y=0)
	var pos3 := Vector3(pos_utm.x, 0.0, pos_utm.y)
	var radius := 100.0
	var found := []
	while found.is_empty() and radius < 10000.0:
		found = _rtree.query_circle(pos3, radius)
		radius *= 2.0

	if found.is_empty():
		return -1

	var nearest_id := -1
	var nearest_dist := INF
	for item in found:
		var node_pos3: Vector3 = item["pos"]
		var dx = node_pos3.x - pos3.x
		var dz = node_pos3.z - pos3.z
		var d = dx * dx + dz * dz
		if d < nearest_dist:
			nearest_dist = d
			nearest_id = int(item["data"]["id"])

	return nearest_id

func world_to_utm(world: Vector3, scale_factor: float=1.0) -> Vector2:
	# Convert world → graph (UTM)
	var wx = world.x
	var wz = world.z
	var utm_x = wx / scale_factor + info.center_x
	var utm_y = -wz / scale_factor + info.center_y
	
	return Vector2(utm_x, utm_y)

# ------------------------------------------------------------
# EDGE GEOMETRY HELPER
# ------------------------------------------------------------
func expand_path_to_geometry(path: Array, scale_factor=1.0) -> PackedVector3Array:
	var points := PackedVector3Array()
	if path.size() < 2:
		return points

	for i in range(path.size() - 1):
		var start_id = path[i]
		var goal_id = path[i + 1]
		var seg_found = false

		for e in edges.get(start_id, []):
			if e["target"] == goal_id:
				var geom = e.get("geometry", [])
				if geom.size() > 0:
					var geom_start = Vector2(geom[0][0], geom[0][1])
					var start_pos = nodes[start_id]
					var end_pos = nodes[goal_id]
					if geom_start.distance_to(start_pos) > geom_start.distance_to(end_pos):
						geom.reverse()

					for pt in geom:
						var wx = (float(pt[0]) - info.center_x) * scale_factor
						var wz = -(float(pt[1]) - info.center_y) * scale_factor
						points.append(Vector3(wx, 0.05, wz))
				else:
					var n = nodes[start_id]
					points.append(Vector3(
						(n.x - info.center_x) * scale_factor,
						0.05,
						-(n.y - info.center_y) * scale_factor
					))
				seg_found = true
				break

		if not seg_found:
			push_warning("⚠️ Missing geometry for edge %s → %s" % [start_id, goal_id])

	return points
