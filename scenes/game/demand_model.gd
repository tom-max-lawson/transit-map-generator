extends Node
class_name DemandModel

# -------------------------------
#	CONFIG
# -------------------------------

# Category attraction weights (utility multiplier)
var CATEGORY_WEIGHTS := {
	"work": 5.0,
	"shopping": 2.0,
	"education": 1.5,
	"healthcare": 0.6,
	"leisure": 3.0,
	"transit": 0.5
}

# Distance decay (per meter) — tune per your taste
var BETA_VALUES := {
	"work": 0.0007,
	"shopping": 0.0012,
	"education": 0.0008,
	"healthcare": 0.0015,
	"leisure": 0.0010,
	"transit": 0.0002
}

# Target K per category (how many finalists each category should contribute)
# i.e. there is no need to consider retain too many POIs from each category as
# their probability in the final distribution will be negligible. We should tune
# these to be somewhat high (to capture variability in people's travel) while still maintaing good performance.
var K_PER_CATEGORY := {
	"work": 50,
	"shopping": 30,
	"education": 20,
	"healthcare": 20,
	"leisure": 30,
	"transit": 10
}

# Diminishing returns for multiplicity (i.e a hub represented by 20x merged POIs should dominate compared to single POIs, but maybe not by 20x). 
# This should be <= 1
var alpha_multiplicity := 1.0

# Lookup of POIs by location (RTree for each category of POI)
var spatial_indices: Dictionary = {}


# -------------------------------
#	Grid / Data loaded from JSON
# -------------------------------

var grid_cell_size: float
var grid_min_x: float
var grid_min_y: float
var grid_num_x: int
var grid_num_y: int
var utm_center_x: float
var utm_center_y: float

# Original cells dictionary from JSON ("cell_id" -> {ix,iy,pois})
var cells: Dictionary = {}

# Category spatial index:
# cat_grid[category] : Dictionary keyed by Vector2i(ix,iy) -> Array of POIs (as dictionaries from JSON)
var cat_grid: Dictionary = {}


func load_poi_data(json_path: String, center_x: float, center_y: float) -> void:
	utm_center_x = center_x
	utm_center_y = center_y

	var file := FileAccess.open(json_path, FileAccess.READ)
	if file == null:
		push_error("Failed to open POI JSON at: " + json_path)
		return

	var data = JSON.parse_string(file.get_as_text())
	file.close()

	if typeof(data) != TYPE_DICTIONARY:
		push_error("Invalid JSON structure")
		return

	var grid = data["grid"]
	grid_cell_size = float(grid["cell_size_m"])
	grid_min_x = float(grid["min_x"])
	grid_min_y = float(grid["min_y"])
	grid_num_x = int(grid["num_x"])
	grid_num_y = int(grid["num_y"])

	cells = data["cells"]

	# FIXME: old method!
	#_build_category_spatial_index()

	_validate_known_categories()
	
	_build_spatial_indices()


func _build_spatial_indices() -> void:
	spatial_indices.clear()

	var categories_seen := {}
	for cell in cells.values():
		for poi in cell["pois"]:
			var cat = poi["category"]
			if not spatial_indices.has(cat):
				spatial_indices[cat] = RTree.new()
				categories_seen[cat] = []
			var wp := utm_to_world(Vector2(poi["pos_utm"][0], poi["pos_utm"][1]), 0.0)
			categories_seen[cat].append({"pos": wp, "data": poi})

	# build one tree per category
	for cat in categories_seen.keys():
		var tree = spatial_indices[cat]
		tree.build(categories_seen[cat])
		print("🌳 Built RTree for %s: %d POIs" % [cat, categories_seen[cat].size()])


	print("DemandModel loaded. Cells with POIs: ", cells.size(), " | Categories indexed: ", cat_grid.keys())

func _build_category_spatial_index() -> void:
	cat_grid.clear()
	# Initialize category buckets
	for cat in CATEGORY_WEIGHTS.keys():
		cat_grid[cat] = {}

	# Place each POI into the category grid by its cell ix,iy
	for key in cells.keys():
		var cell = cells[key]
		var ix: int = int(cell["ix"])
		var iy: int = int(cell["iy"])
		var kv := Vector2i(ix, iy)

		var pois: Array = cell["pois"]
		for poi in pois:
			var cat: String = poi["category"]
			if not cat_grid.has(cat):
				# We'll assert on load later; still create a bucket to avoid crashes here
				cat_grid[cat] = {}
			if not cat_grid[cat].has(kv):
				cat_grid[cat][kv] = []
			cat_grid[cat][kv].append(poi)



func _validate_known_categories() -> void:
	# Hard-stop if any POI category is unknown to weights/betas/K
	for cat in cat_grid.keys():
		var ok = CATEGORY_WEIGHTS.has(cat) and BETA_VALUES.has(cat) and K_PER_CATEGORY.has(cat)
		if not ok:
			push_error("DemandModel: Unknown or unconfigured category '" + str(cat) + "'")
			assert(false, "Unknown category encountered in data: " + str(cat))


# -------------------------------
#	Coordinate helpers
# -------------------------------

func world_to_utm(pos: Vector3) -> Vector2:
	var utm_x = pos.x + utm_center_x
	var utm_y = -pos.z + utm_center_y	# flip Z → north-positive UTM.y
	return Vector2(utm_x, utm_y)


func utm_to_world(utm: Vector2, y: float = 0.0) -> Vector3:
	return Vector3(
		utm.x - utm_center_x,
		y,
		-(utm.y - utm_center_y)
	)


func _cell_center_utm(ix: int, iy: int) -> Vector2:
	return Vector2(
		grid_min_x + (ix + 0.5) * grid_cell_size,
		grid_min_y + (iy + 0.5) * grid_cell_size
	)


# -------------------------------
#	Binary-search radius per category
# -------------------------------

func _count_category_within_radius_m(cat: String, origin_utm: Vector2, origin_ix: int, origin_iy: int, radius_m: float) -> int:
	var buckets: Dictionary = cat_grid.get(cat, {})
	if buckets.is_empty():
		return 0

	var r_cells = int(ceil(radius_m / grid_cell_size))
	var r2 = radius_m * radius_m

	var count := 0
	for dx in range(-r_cells, r_cells + 1):
		var ix = origin_ix + dx
		if ix < 0 or ix >= grid_num_x:
			continue
		for dy in range(-r_cells, r_cells + 1):
			var iy = origin_iy + dy
			if iy < 0 or iy >= grid_num_y:
				continue

			var kv := Vector2i(ix, iy)
			if not buckets.has(kv):
				continue

			# Exact circle test per POI for correctness near edges
			var arr: Array = buckets[kv]
			for poi in arr:
				var utm = poi["pos_utm"]
				var dxm = float(utm[0]) - origin_utm.x
				var dym = float(utm[1]) - origin_utm.y
				if dxm * dxm + dym * dym <= r2:
					count += 1
	return count


func _collect_category_within_radius_m(cat: String, origin_utm: Vector2, radius_m: float) -> Array:
	var tree = spatial_indices.get(cat)
	if tree == null:
		return []

	# Convert UTM → world so the query circle matches the RTree coordinate space
	var origin_world := utm_to_world(origin_utm, 0.0)

	var hits = tree.query_circle(origin_world, radius_m)
	var out: Array = []

	# Each RTree item was stored as {"pos": wp, "data": poi}
	for h in hits:
		out.append(h["data"])

	return out



func _min_radius_for_k(category: String, origin_utm: Vector2, k: int, max_radius_m: float) -> float:
	var tree = spatial_indices.get(category)
	if tree == null:
		push_error("DemandModel: No RTree found for category '%s'" % category)
		return 0.0

	# Convert UTM -> world for spatial query
	var origin_world := utm_to_world(origin_utm, 0.0)

	var lo := 0.0
	var hi := max_radius_m
	var best := hi
	var iterations := 0

	while abs(hi - lo) > 1.0 and iterations < 25:
		var mid := (lo + hi) * 0.5
		var results = tree.query_circle(origin_world, mid)

		# Debug: uncomment to see convergence
		# print("→", category, "mid", mid, "found", results.size())

		if results.size() >= k:
			best = mid
			hi = mid
		else:
			lo = mid + 1.0

		iterations += 1

	return best



# -------------------------------
#	Public API: compute demand
# -------------------------------

func compute_demand(world_pos: Vector3) -> Array:
	# Origin in UTM + its grid indices
	var origin_utm := world_to_utm(world_pos)

	# Collect finalists per category using your binary-search strategy
	var finalists: Array = []

	for cat in CATEGORY_WEIGHTS.keys():
		if not (BETA_VALUES.has(cat) and K_PER_CATEGORY.has(cat)):
			push_error("DemandModel: Missing beta/K for category '" + str(cat) + "'")
			assert(false, "Missing category config: " + str(cat))

		var K := int(K_PER_CATEGORY[cat])
		if K <= 0:
			continue

		var t_cat_start := Time.get_ticks_usec()

		# --- radius search ---
		var t0 := Time.get_ticks_usec()
		
		# Compute maximum possible search radius given our data
		var width := (grid_num_x * grid_cell_size)
		var height := (grid_num_y * grid_cell_size)
		var MAX_RADIUS_M: float = sqrt(width * width + height * height)
		
		var radius_m := _min_radius_for_k(cat, origin_utm, K, MAX_RADIUS_M)
		var t_min_radius := Time.get_ticks_usec() - t0

		# --- collecting ---
		t0 = Time.get_ticks_usec()
		var candidates: Array = _collect_category_within_radius_m(cat, origin_utm, radius_m)
		var t_collect := Time.get_ticks_usec() - t0

		#if candidates.size() < K and radius_m < MAX_RADIUS_M:
			#t0 = Time.get_ticks_usec()
			#candidates = _collect_category_within_radius_m(cat, origin_utm, origin_ix, origin_iy, MAX_RADIUS_M)
			#t_collect += Time.get_ticks_usec() - t0

		var w = CATEGORY_WEIGHTS[cat]
		var beta = BETA_VALUES[cat]

		var scored_cat: Array = []
		for poi in candidates:
			var utm = poi["pos_utm"]
			var dx = float(utm[0]) - origin_utm.x
			var dy = float(utm[1]) - origin_utm.y
			var d = sqrt(dx * dx + dy * dy)
			var score = w * exp(-beta * d) * pow(poi["multiplicity"], alpha_multiplicity)
			if score > 0.0:
				scored_cat.append({
					"poi": poi,
					"score": score,
					"world_pos": utm_to_world(Vector2(utm[0], utm[1]), world_pos.y),
					"category": cat
				})

		if scored_cat.size() > 0:
			scored_cat.sort_custom(func(a, b): return a["score"] > b["score"])
			if scored_cat.size() > K:
				scored_cat = scored_cat.slice(0, K)
			for s in scored_cat:
				finalists.append(s)

		var t_cat_total := Time.get_ticks_usec() - t_cat_start
		# FIXME: debugging
		#print("--- [", cat, "] --- radius: ", str(radius_m), " m | total: ", str(t_cat_total / 1000.0), " ms | min_radius: ", str(t_min_radius / 1000.0), " ms | collect: ", str(t_collect / 1000.0), " ms")

	# Global top_n across all categories
	if finalists.is_empty():
		return []

	finalists.sort_custom(func(a, b): return a["score"] > b["score"])

	# Normalize to probabilities
	var total := 0.0
	for r in finalists:
		total += r["score"]

	if total > 0.0:
		for r in finalists:
			r["prob"] = r["score"] / total
	else:
		for r in finalists:
			r["prob"] = 0.0

	return finalists
