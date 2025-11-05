extends Resource
class_name RTree

# =============================================================
# Lightweight R-tree for 2D POIs (using Godot AABB for storage)
# Each item: {"pos": Vector3, "data": Dictionary}
# Query: spatial_indices[cat].query_circle(center, radius)
# =============================================================

const MAX_CHILDREN := 10

class RNode:
	var aabb: AABB
	var children: Array = []
	var items: Array = []
	var is_leaf: bool = true


# -------------------------------------------------------------
# BUILD
# -------------------------------------------------------------
var root: RNode = null

func build(points: Array) -> void:
	if points.is_empty():
		root = null
		return
	root = _build_level(points, 0)


func _build_level(points: Array, depth: int) -> RNode:
	var node := RNode.new()

	# Bounding box of all points in this subset
	node.aabb = _calc_aabb_points(points)

	if points.size() <= MAX_CHILDREN:
		node.is_leaf = true
		node.items = points
	else:
		node.is_leaf = false
		# Split points along the longest axis of AABB
		var size = node.aabb.size
		var axis = 0
		if size.z > size.x:
			axis = 2

		points.sort_custom(func(a, b):
			if axis == 0:
				return a["pos"].x < b["pos"].x
			else:
				return a["pos"].z < b["pos"].z
		)

		var mid := points.size() / 2
		var left_points := points.slice(0, mid)
		var right_points := points.slice(mid, points.size())
		node.children = [
			_build_level(left_points, depth + 1),
			_build_level(right_points, depth + 1)
		]

	return node


func _calc_aabb_points(points: Array) -> AABB:
	if points.is_empty():
		return AABB(Vector3.ZERO, Vector3.ZERO)

	var min_x = points[0]["pos"].x
	var min_z = points[0]["pos"].z
	var max_x = min_x
	var max_z = min_z

	for p in points:
		var pos = p["pos"]
		min_x = min(min_x, pos.x)
		min_z = min(min_z, pos.z)
		max_x = max(max_x, pos.x)
		max_z = max(max_z, pos.z)

	var min_corner = Vector3(min_x, 0.0, min_z)
	var size = Vector3(max_x - min_x, 0.0, max_z - min_z)
	return AABB(min_corner, size)


# -------------------------------------------------------------
# QUERY
# -------------------------------------------------------------
func query_circle(center: Vector3, radius: float) -> Array:
	if root == null:
		return []
	var out: Array = []
	_query_circle_recursive(root, center, radius, out)
	return out


func _query_circle_recursive(node: RNode, center: Vector3, radius: float, out: Array) -> void:
	if not _aabb_intersects_circle(node.aabb, center, radius):
		return

	if node.is_leaf:
		var r2 = radius * radius
		for p in node.items:
			var pos = p["pos"]
			var dx = pos.x - center.x
			var dz = pos.z - center.z
			if dx * dx + dz * dz <= r2:
				out.append(p)
	else:
		for c in node.children:
			_query_circle_recursive(c, center, radius, out)


# -------------------------------------------------------------
# HELPERS
# -------------------------------------------------------------
func _aabb_intersects_circle(aabb: AABB, center: Vector3, radius: float) -> bool:
	# Clamp point to AABB and compute squared distance to circle center
	var closest_x = clamp(center.x, aabb.position.x, aabb.position.x + aabb.size.x)
	var closest_z = clamp(center.z, aabb.position.z, aabb.position.z + aabb.size.z)

	var dx = closest_x - center.x
	var dz = closest_z - center.z
	return (dx * dx + dz * dz) <= (radius * radius)


# -------------------------------------------------------------
# DEBUG UTILITIES
# -------------------------------------------------------------
func debug_print_summary(cat: String = "") -> void:
	if root == null:
		print("RTree empty")
		return

	print("--- Category:", cat, "---")
	print("Root AABB:", root.aabb)
	var leafs := _count_leafs(root)
	print("Leaf count:", leafs)
	var sample := _collect_some_points(root, 5)
	print("Sample POIs:")
	for s in sample:
		print(" ", s["pos"])


func _count_leafs(node: RNode) -> int:
	if node.is_leaf:
		return 1
	var n = 0
	for c in node.children:
		n += _count_leafs(c)
	return n


func _collect_some_points(node: RNode, limit: int) -> Array:
	var out: Array = []
	if node.is_leaf:
		for p in node.items:
			out.append(p)
			if out.size() >= limit:
				return out
	else:
		for c in node.children:
			out += _collect_some_points(c, limit)
			if out.size() >= limit:
				break
	return out
