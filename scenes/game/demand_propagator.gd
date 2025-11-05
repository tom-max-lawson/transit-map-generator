extends Node
class_name TripManager

@export var rate: float = 0.5                 # Mean spawn interval (seconds)
@export var bubble_color: Color = Color.RED
@export var bubble_radius: float = 8.0
@export var bubble_speed_mps: float = 150.0

# Resource references
var config: MapConfig
var demand_model: DemandModel
var graph_data: GraphData

# Internal state
var active_trips: Array = []  # {bubble, path, dist, progress}
var pending_task_ids := {}  # Contains the current jobs (the key values are not used)
var results_mutex := Mutex.new()  # Mutex for writing to pending_results
var pending_results: Array = []  # 
var rng := RandomNumberGenerator.new()
var time_accum := 0.0

var shutting_down := false  # If the user has requested to quit; allows for safely stopping all threads

# Debug camera cycling
var current_bubble_index := 0

# For profiling
var timing_stats := {
	"choose_origin_ms": {"sum": 0.0, "count": 0, "min": INF, "max": 0.0},
	"compute_demand_ms": {"sum": 0.0, "count": 0, "min": INF, "max": 0.0},
	"sample_dest_ms": {"sum": 0.0, "count": 0, "min": INF, "max": 0.0},
	"find_nearest_ms": {"sum": 0.0, "count": 0, "min": INF, "max": 0.0},
	"astar_ms": {"sum": 0.0, "count": 0, "min": INF, "max": 0.0},
	"expand_geom_ms": {"sum": 0.0, "count": 0, "min": INF, "max": 0.0},
	"total_ms": {"sum": 0.0, "count": 0, "min": INF, "max": 0.0}
}

# ------------------------------------------------------------
# READY
# ------------------------------------------------------------
func _ready() -> void:
	config = get_tree().get_root().get_node("Main/config")
	demand_model = config.demand_model
	graph_data = config.graph_data

	# Create initial trips during loading process
	var initial_trips := 100
	print("Demand propagator: creating ", initial_trips, " initial trips")
	while len(pending_task_ids) < initial_trips:  # Use while loop as some trips are negligible distance and don't get created
		_try_spawn_trip_async()
	print("Processes spawned... Awaiting results")

	# Wait for the trips to be generated
	for task_id in pending_task_ids.keys():
		WorkerThreadPool.wait_for_task_completion(task_id)
		pending_task_ids.erase(task_id)

	print("All jobs finished. Creating trips...")
	results_mutex.lock()
	if not pending_results.is_empty():
		for res in pending_results:
			_create_trip(res["path"])
		pending_results.clear()
	results_mutex.unlock()
	print("All initial trips created!")

	print("TripManager ready — async trips enabled")


# ------------------------------------------------------------
# PROCESS
# ------------------------------------------------------------
func _process(delta: float) -> void:
	time_accum += delta
	if time_accum >= _next_spawn_delay():
		time_accum = 0.0  # Reset timer
		_try_spawn_trip_async()

	_check_completed_tasks()  # Check for completion of trip spawning jobs
	_update_trips(delta)  # Update progress of existing trips

# ------------------------------------------------------------
# CLEANUP
# ------------------------------------------------------------
func _exit_tree() -> void:
	shutting_down = true

	# Safely wait for threads to exit, otherwise we can end up with crashes, deadlocks etc.
	for id in pending_task_ids.keys():
		WorkerThreadPool.wait_for_task_completion(id)
	pending_task_ids.clear()

# ------------------------------------------------------------
# ASYNC TRIP GENERATION
# ------------------------------------------------------------
func _try_spawn_trip_async():
	if demand_model == null or graph_data == null:
		push_error("Demand model or graph data was null, cannot spawn trips")
		return

	var task_id := WorkerThreadPool.add_task(Callable(self, "_thread_generate_trip"), false)
	pending_task_ids[task_id] = true


# Worker thread
func _thread_generate_trip():
	var t0 = Time.get_ticks_usec()

	# 1️⃣ Choose origin
	var origin = _choose_random_origin()
	var t_choose_origin = Time.get_ticks_usec()

	# 2️⃣ Compute demand
	var demand = demand_model.compute_demand(origin)
	var t_compute_demand = Time.get_ticks_usec()
	if demand.is_empty():
		return

	# 3️⃣ Sample destination
	var dest_data = _sample_destination(demand)
	var t_sample_dest = Time.get_ticks_usec()
	if dest_data == null:
		return

	# 4️⃣ Find nearest nodes
	var dest_pos: Vector3 = dest_data["world_pos"]
	var origin_utm = graph_data.world_to_utm(origin)
	var dest_utm = graph_data.world_to_utm(dest_pos)

	var start_id = graph_data.find_nearest_node(origin_utm)
	var goal_id = graph_data.find_nearest_node(dest_utm)
	var t_find_nearest = Time.get_ticks_usec()
	if start_id == -1 or goal_id == -1:
		return

	# 5️⃣ A* pathfinding
	var path_ids = graph_data.find_path_a_star(str(start_id), str(goal_id))
	var t_astar = Time.get_ticks_usec()
	if path_ids.is_empty():
		return

	# 6️⃣ Path expansion to geometry
	var geom := graph_data.expand_path_to_geometry(path_ids, config.scale_factor)
	var t_expand_geom = Time.get_ticks_usec()

	# Lock and append result with timing info
	results_mutex.lock()
	pending_results.append({
		"path": geom,
		"timing": {
			"choose_origin_ms": (t_choose_origin - t0) / 1000.0,
			"compute_demand_ms": (t_compute_demand - t_choose_origin) / 1000.0,
			"sample_dest_ms": (t_sample_dest - t_compute_demand) / 1000.0,
			"find_nearest_ms": (t_find_nearest - t_sample_dest) / 1000.0,
			"astar_ms": (t_astar - t_find_nearest) / 1000.0,
			"expand_geom_ms": (t_expand_geom - t_astar) / 1000.0,
			"total_ms": (t_expand_geom - t0) / 1000.0
		}
	})
	results_mutex.unlock()



# ------------------------------------------------------------
# CHECK COMPLETED TASKS
# ------------------------------------------------------------
func _check_completed_tasks():
	for task_id in pending_task_ids.keys():
		if WorkerThreadPool.is_task_completed(task_id):
			pending_task_ids.erase(task_id)

	results_mutex.lock()
	if not pending_results.is_empty():
		for res in pending_results:
			_create_trip(res["path"])
			_update_timing_stats(res["timing"])
		pending_results.clear()
	results_mutex.unlock()

func _update_timing_stats(timing: Dictionary) -> void:
	for key in timing.keys():
		if not timing_stats.has(key):
			continue
		var entry = timing_stats[key]
		var val = timing[key]

		entry["sum"] += val
		entry["count"] += 1
		entry["min"] = min(entry["min"], val)
		entry["max"] = max(entry["max"], val)

		timing_stats[key] = entry
# ------------------------------------------------------------
# CREATE TRIP
# ------------------------------------------------------------
func _create_trip(path: Array[Vector3]):
	if path.size() < 2:
		# This can happen for valid reasons (e.g. someone's house is right next to a POI)- in this case just don't create the trip
		return
		
	var bubble := MeshInstance3D.new()

	# --- mesh ---
	var sphere := SphereMesh.new()
	sphere.radius = bubble_radius
	sphere.height = sphere.radius * 2.0
	bubble.mesh = sphere

	# --- material ---
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	# main color
	mat.albedo_color = bubble_color

	# emission glow
	mat.emission_enabled = true
	mat.emission = bubble_color
	mat.emission_energy_multiplier = 2.5

	# make sure alpha and transparency play nice
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color.a = 0.75

	# critical fix: disable vertex lighting so emission shows correctly
	mat.vertex_color_use_as_albedo = false

	# optional “glassy” highlight
	mat.metallic = 0.4
	mat.roughness = 0.05

	bubble.material_override = mat


	add_child(bubble)
	bubble.global_position = path[0]

	var dist = _path_length(path)
	var trip = {
		"bubble": bubble,
		"path": path,
		"dist": dist,
		"progress": 0.0
	}
	active_trips.append(trip)


# ------------------------------------------------------------
# UPDATE TRIPS
# ------------------------------------------------------------
func _update_trips(delta: float):
	for i in range(active_trips.size() - 1, -1, -1):
		var trip = active_trips[i]
		if not trip.has("path") or trip["path"].size() < 2:
			active_trips.remove_at(i)
			continue

		trip["progress"] += bubble_speed_mps * delta
		if trip["progress"] >= trip["dist"]:
			trip["bubble"].queue_free()
			active_trips.remove_at(i)
			continue

		var new_pos = _interpolate_path(trip["path"], trip["progress"])
		trip["bubble"].global_position = new_pos


# ------------------------------------------------------------
# PATH HELPERS
# ------------------------------------------------------------
func _path_length(path: Array[Vector3]) -> float:
	var total := 0.0
	for i in range(path.size() - 1):
		total += path[i].distance_to(path[i + 1])
	return total


func _interpolate_path(path: Array[Vector3], dist: float) -> Vector3:
	var acc := 0.0
	for i in range(path.size() - 1):
		var seg_len = path[i].distance_to(path[i + 1])
		if acc + seg_len >= dist:
			var t = (dist - acc) / seg_len
			return path[i].lerp(path[i + 1], t)
		acc += seg_len
	return path[-1]


# ------------------------------------------------------------
# DEMAND HELPERS
# ------------------------------------------------------------
func _choose_random_origin() -> Vector3:
	var dm: DemandModel = demand_model
	var ix = rng.randi_range(0, dm.grid_num_x - 1)
	var iy = rng.randi_range(0, dm.grid_num_y - 1)
	var utm = Vector2(
		dm.grid_min_x + (ix + 0.5) * dm.grid_cell_size,
		dm.grid_min_y + (iy + 0.5) * dm.grid_cell_size
	)
	return dm.utm_to_world(utm, 0.1)


func _sample_destination(demand: Array) -> Dictionary:
	if demand.is_empty():
		return {}
	var r = rng.randf()
	var accum = 0.0
	for item in demand:
		accum += item["prob"]
		if r <= accum:
			return item
	return demand[-1]


# ------------------------------------------------------------
# RATE SAMPLING
# ------------------------------------------------------------
func _next_spawn_delay() -> float:
	# This could be made more complex later, such as with a probability distribution
	return rate


# ------------------------------------------------------------
# DEBUG CAMERA CYCLING
# ------------------------------------------------------------
func _input(event):
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_C:   # Press C to cycle camera to next bubble
			_focus_next_bubble()


func _focus_next_bubble():
	if active_trips.is_empty():
		print("There are no active trips! Cannot re-focus camera.")
		return

	var cam = get_viewport().get_camera_3d()
	if cam == null:
		return

	current_bubble_index = (current_bubble_index + 1) % active_trips.size()
	var target_bubble = active_trips[current_bubble_index]["bubble"]
	cam.global_position = target_bubble.global_position + Vector3(0, 100, 200)
	cam.look_at(target_bubble.global_position, Vector3.UP)
	print("🎥 Camera focused on bubble #%d" % current_bubble_index)

# ------------------------------------------------------------
# DEBUG TELEMETRY
# ------------------------------------------------------------
func get_debug_info() -> Dictionary:
	var info := {
		"active trips": active_trips.size(),
		"pending trip generation tasks": pending_task_ids.size(),
		"pending trip results": pending_results.size(),
		"trip spawn period": rate
	}

	# --- Add timing stats summary ---
	for key in timing_stats.keys():
		var s = timing_stats[key]
		if s["count"] == 0:
			continue
		var mean = s["sum"] / s["count"]
		info["timing_%s_mean" % key] = mean
		info["timing_%s_min" % key] = s["min"]
		info["timing_%s_max" % key] = s["max"]

	return info
