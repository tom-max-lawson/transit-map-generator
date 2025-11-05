# MetroGraph.gd (Godot 4)
class_name MetroGraph
extends Resource

# Public config
@export_storage var snap_distance: float = 20.0
@export_storage var line_colors := {}  # optional: {"L1": Color.RED, "L2": Color.BLUE}

# Internal storage
# nodes: [{id: "1", pos: Vector2, label: String}]
# edges: [{a: "1", b: "2", lines: PackedStringArray}]  // undirected edge, a<b
@export_storage var _nodes: Array = []
@export_storage var _edges: Array = []
@export_storage var _line_last_node := {}  # { "L1": "node_id" }
@export_storage var _next_id: int = 1

# -------------- Public API --------------

func get_node_pos(id: String) -> Vector2: return _get_node_pos(id)
func get_nodes() -> Array: return _nodes
func get_edges() -> Array: return _edges

func add_node(x: float, y: float, line_id: String) -> String:
	# 1) snap or create station node
	var pos := Vector2(x, y)
	var nid := _find_or_create_node(pos)

	# 2) if line already has a previous node, add a segment and handle intersections
	if _line_last_node.has(line_id):
		var prev_id: String = _line_last_node[line_id]
		if prev_id != nid:
			_add_segment(prev_id, nid, line_id)

	# 3) set last node for this line
	_line_last_node[line_id] = nid
	return nid

func reset_line(line_id: String) -> void:
	_line_last_node.erase(line_id)

func to_json() -> String:
	var data := {
		"nodes": [],
		"edges": [],
		"lines": []
	}

	# nodes
	for n in _nodes:
		data["nodes"].append({
			"id": n.id,
			"label": n.label if n.has("label") else ("Station " + n.id),
			"metadata": {"x": n.pos.x, "y": n.pos.y}
		})

	# edges
	for e in _edges:
		data["edges"].append({
			"source": e.a,
			"target": e.b,
			"metadata": {"lines": e.lines}
		})

	# lines metadata (optional colors)
	var seen := {}
	for e in _edges:
		for lid in e.lines:
			if seen.has(lid): continue
			seen[lid] = true
			var col: String = ("#" + line_colors[lid].to_html(false)) if line_colors.has(lid) else "#888888"
			data["lines"].append({"id": lid, "group": lid, "color": col})

	return JSON.stringify(data, "\t")

func from_json(path: String) -> void:
	# Clear existing data
	_nodes.clear()
	_edges.clear()
	_line_last_node.clear()
	_next_id = 1
	line_colors.clear()

	# Read file
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		push_error("Cannot open JSON file: " + path)
		return

	var content := f.get_as_text()
	f.close()

	var parsed: Dictionary = JSON.parse_string(content)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Invalid JSON format in " + path)
		return

	# --- Load nodes ---
	if parsed.has("nodes"):
		for n in parsed["nodes"]:
			var pos := Vector2(n["metadata"]["x"], n["metadata"]["y"])
			var id := str(n["id"])
			_nodes.append({ "id": id, "pos": pos, "label": n.get("label", "Station " + id) })
			var numeric_id := int(id)
			if numeric_id >= _next_id:
				_next_id = numeric_id + 1

	# --- Load edges ---
	if parsed.has("edges"):
		for e in parsed["edges"]:
			var a := str(e["source"])
			var b := str(e["target"])
			var lines: Variant = e.get("metadata", {}).get("lines", [])
			if typeof(lines) == TYPE_ARRAY:
				lines = PackedStringArray(lines)
			_edges.append({ "a": a, "b": b, "lines": lines })

	# --- Load lines metadata (colors, groups) ---
	if parsed.has("lines"):
		for l in parsed["lines"]:
			var lid := str(l["id"])
			var color_hex: String = l.get("color", "#888888")
			line_colors[lid] = Color(color_hex)

	print("Loaded graph from", path, "with", _nodes.size(), "nodes and", _edges.size(), "edges.")

func get_extent() -> Rect2:
	var bottom_right := Vector2(-INF, -INF)
	var top_left = Vector2(INF, INF)
	
	for n in _nodes:
		if n.pos.x < top_left.x:
			top_left.x = n.pos.x
		elif n.pos.x > bottom_right.x:
			bottom_right.x = n.pos.x
		if n.pos.y < top_left.y:
			top_left.y = n.pos.y
		elif n.pos.y > bottom_right.y:
			bottom_right.y = n.pos.y
			
	return Rect2(top_left, bottom_right - top_left)

# Move each node by a distance
func translate_nodes_individual(translations: Array[Vector2]) -> void:
	assert(translations.size() == _nodes.size(), "Implementation error, provided translations doesnt match number of nodes")
	for i in range(_nodes.size()):
		_nodes[i].pos += translations[i]
	

func apply_affine(scaler: float, translation: Vector2) -> void:
	var extent := get_extent()
	
	# Translate such that world origin is at center of image, for scaling purposes
	_translate_nodes(Vector2.ZERO - extent.position - extent.size / 2)
	
	# Scale
	for n in _nodes:
		n.pos *= scaler
		
	# Translate to proper bounding box location
	_translate_nodes(extent.position + extent.size/2 + translation)
	
	
# -------------- Core: nodes -------------

func _translate_nodes(vec: Vector2) -> void:
	if vec == Vector2.ZERO:
		return  # Nothing to do
	
	for n in _nodes:
		n.pos += vec

func _find_or_create_node(pos: Vector2) -> String:
	var snapped := _find_node_near(pos)
	if snapped != "":
		return snapped
	var id := str(_next_id)
	_next_id += 1
	_nodes.append({ "id": id, "pos": pos, "label": "Station " + id })
	return id

func _find_node_near(pos: Vector2) -> String:
	for n in _nodes:
		if n.pos.distance_to(pos) <= snap_distance:
			return n.id
	return ""

func _get_node_pos(id: String) -> Vector2:
	for n in _nodes:
		if n.id == id:
			return n.pos
	return Vector2.ZERO

# -------------- Core: segments & intersections --------------

func _add_segment(a: String, b: String, line_id: String) -> void:
	var a_pos := _get_node_pos(a)
	var b_pos := _get_node_pos(b)
	if a_pos == b_pos:
		return

	# 1) collect all intersections of segment (a-b) with existing edges
	var splits: Array = []  # [{id: "node_id", t: float, pos: Vector2}]
	var to_split_edges: Array = [] # list of edge indices to split later

	for i in range(_edges.size()):
		var e = _edges[i]
		# skip if shares endpoints (no internal intersection)
		if (e.a == a or e.a == b or e.b == a or e.b == b):
			continue
		var p1 := _get_node_pos(e.a)
		var p2 := _get_node_pos(e.b)
		var inter = Geometry2D.segment_intersects_segment(a_pos, b_pos, p1, p2)
		if inter:
			# create/reuse intersection node (snap)
			var inter_id := _find_or_create_node(inter)
			# parameter t along (a->b) to sort
			var t := _segment_param(inter, a_pos, b_pos)
			splits.append({ "id": inter_id, "t": t, "pos": inter })
			to_split_edges.append(i)

	# 2) split the existing edges at their intersection (may create duplicates, handle later)
	# We gather and then process indices descending to avoid reindexing issues.
	to_split_edges = to_split_edges.duplicate()
	to_split_edges.sort_custom(func(i1, i2): return i1 > i2)

	for idx in to_split_edges:
		var e = _edges[idx]
		var p1 := _get_node_pos(e.a)
		var p2 := _get_node_pos(e.b)
		# find the intersection node we created that lies on this edge
		# (there can be multiple splits on the same edge; collect all, sort along edge)
		var splits_on_edge: Array = []
		for s in splits:
			if _point_on_segment(s.pos, p1, p2):
				var t_edge := _segment_param(s.pos, p1, p2)
				splits_on_edge.append({ "id": s.id, "t": t_edge })

		if splits_on_edge.is_empty():
			continue

		# remove original edge
		_edges.remove_at(idx)
		# sort split points along (p1->p2)
		splits_on_edge.sort_custom(func(a, b): return a.t < b.t)

		# create chain: e.a -> split1 -> split2 -> ... -> e.b (carry original e.lines)
		var chain: Array = [e.a]
		for s in splits_on_edge:
			if chain.back() != s.id:
				chain.append(s.id)
		if chain.back() != e.b:
			chain.append(e.b)

		for j in range(chain.size()-1):
			_add_or_merge_edge(chain[j], chain[j+1], e.lines)

	# 3) now build the new segment itself with its splits
	var chain_new: Array = [a]
	if not splits.is_empty():
		# sort by t along (a->b), then append
		splits.sort_custom(func(s1, s2): return s1.t < s2.t)
		for s in splits:
			if chain_new.back() != s.id:
				chain_new.append(s.id)
	if chain_new.back() != b:
		chain_new.append(b)

	for j in range(chain_new.size()-1):
		_add_or_merge_edge(chain_new[j], chain_new[j+1], [line_id])

# -------------- Edges helpers --------------

func _edge_key(a: String, b: String) -> String:
	return (a + "-" + b) if a < b else (b + "-" + a)

func _find_edge_index(a: String, b: String) -> int:
	var key := _edge_key(a, b)
	for i in range(_edges.size()):
		if _edge_key(_edges[i].a, _edges[i].b) == key:
			return i
	return -1

func _add_or_merge_edge(a: String, b: String, lines: Array) -> void:
	if a == b:
		return
	var idx := _find_edge_index(a, b)
	if idx == -1:
		_edges.append({ "a": (a if a < b else b), "b": (b if a < b else a), "lines": PackedStringArray(lines) })
	else:
		# merge line ids
		for lid in lines:
			if lid not in _edges[idx].lines:
				_edges[idx].lines.append(lid)

# -------------- Geometry utils --------------

func _segment_param(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var denom := ab.length_squared()
	if denom <= 0.000001:
		return 0.0
	return (p - a).dot(ab) / denom

func _point_on_segment(p: Vector2, a: Vector2, b: Vector2, tolerance := 0.1) -> bool:
	var ab := b - a
	var ap := p - a
	var bp := p - b
	if abs(ab.cross(ap)) > tolerance:
		return false
	return ap.dot(bp) <= 0.0
