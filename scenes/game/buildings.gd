extends Node3D

@export_dir var tiles_folder: String
@export var load_radius_tiles: int = 2
@export var tile_size_m: float = 1000.0
@export var update_interval_s: float = 1.0

var config: MapConfig
var loaded_tiles := {}          # key: Vector2i(ix, iy) -> MeshInstance3D
var cached_tile_data := {}      # key: Vector2i(ix, iy) -> Array of buildings
var last_camera_tile := Vector2i(999999, 999999)


# ---------------------------------------------------------
# MAIN SETUP
# ---------------------------------------------------------
func _ready():
	config = get_tree().get_root().get_node("Main/config")
	print("🧱 Preloading all building tiles from:", tiles_folder)
	_preload_all_tiles()
	_start_tile_updater()


# ---------------------------------------------------------
# LOAD ALL TILES INTO MEMORY
# ---------------------------------------------------------
func _preload_all_tiles():
	var dir := DirAccess.open(tiles_folder)
	if dir == null:
		push_error("Cannot open tiles folder: " + tiles_folder)
		return

	dir.list_dir_begin()
	var file_name = dir.get_next()
	var total_buildings := 0
	while file_name != "":
		if file_name.ends_with(".json"):
			var parts := file_name.trim_prefix("tile_").trim_suffix(".json").split("_")
			if parts.size() == 2:
				var ix = int(parts[0])
				var iy = int(parts[1])
				var key = Vector2i(ix, iy)

				var file_path = tiles_folder.path_join(file_name)
				var file := FileAccess.open(file_path, FileAccess.READ)
				if file != null:
					var text = file.get_as_text()
					file.close()
					var data = JSON.parse_string(text)
					if data != null and data.has("buildings"):
						cached_tile_data[key] = data["buildings"]
						total_buildings += data["buildings"].size()
					else:
						push_warning("Invalid tile JSON: " + file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	print("✅ Preloaded", cached_tile_data.size(), "tiles with", total_buildings, "buildings total.")


# ---------------------------------------------------------
# CAMERA UPDATE LOOP
# ---------------------------------------------------------
func _start_tile_updater():
	var timer := Timer.new()
	timer.wait_time = update_interval_s
	timer.autostart = true
	timer.timeout.connect(_update_visible_tiles)
	add_child(timer)
	_update_visible_tiles()


func _update_visible_tiles():
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return

	# Convert camera world position → UTM coordinates
	var cam_world = camera.global_position
	var utm_x = cam_world.x / config.scale_factor + config.graph_data.info.center_x
	var utm_y = -cam_world.z / config.scale_factor + config.graph_data.info.center_y

	# --- Compute tile indices relative to dataset origin ---
	var ix = floor((utm_x - config.graph_data.info.min_x) / tile_size_m)
	var iy = floor((utm_y - config.graph_data.info.min_y) / tile_size_m)
	var cam_tile = Vector2i(int(ix), int(iy))

	if cam_tile == last_camera_tile:
		return
	last_camera_tile = cam_tile

	#print("📍 Camera in tile", cam_tile)
	_manage_tiles(cam_tile)



# ---------------------------------------------------------
# TILE MANAGEMENT
# ---------------------------------------------------------
func _manage_tiles(cam_tile: Vector2i):
	var needed_tiles := {}

	for dx in range(-load_radius_tiles, load_radius_tiles + 1):
		for dy in range(-load_radius_tiles, load_radius_tiles + 1):
			var key = Vector2i(cam_tile.x + dx, cam_tile.y + dy)

			needed_tiles[key] = true

	# Unload far tiles
	for key in loaded_tiles.keys():
		if not needed_tiles.has(key):
			_remove_tile(key)

	# Spawn new tiles (from cache)
	for key in needed_tiles.keys():
		if not loaded_tiles.has(key) and cached_tile_data.has(key):
			_spawn_tile_from_cache(key)



func _remove_tile(key: Vector2i):
	if loaded_tiles.has(key):
		loaded_tiles[key].queue_free()
		loaded_tiles.erase(key)
		#print("🗑 Unloaded tile", key)


# ---------------------------------------------------------
# CREATE TILE INSTANCES FROM MEMORY
# ---------------------------------------------------------
func _spawn_tile_from_cache(key: Vector2i):
	var buildings = cached_tile_data.get(key, null)
	if buildings == null:
		# print("⚠️ No cached data for tile", key)
		return

	var mesh := _create_tile_mesh(buildings)
	if mesh == null:
		return

	var tile_instance := MeshInstance3D.new()
	tile_instance.mesh = mesh
	add_child(tile_instance)
	loaded_tiles[key] = tile_instance
	#print("🏗️ Spawned cached tile", key, "with", buildings.size(), "buildings")


# ---------------------------------------------------------
# MESH CREATION (unchanged)
# ---------------------------------------------------------
func _create_tile_mesh(buildings: Array) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for b in buildings:
		var footprint = b["footprint"]
		if footprint.size() < 3:
			continue
		var height: float = b.get("height", 10.0)

		var bottom3: Array[Vector3] = []
		var top3: Array[Vector3] = []
		var poly2d: PackedVector2Array = []

		var cleaned: Array = []
		for i in range(footprint.size()):
			var a = footprint[i]
			if i > 0 and a[0] == footprint[i - 1][0] and a[1] == footprint[i - 1][1]:
				continue
			cleaned.append(a)
		if cleaned.size() >= 2:
			var a0 = cleaned[0]
			var an = cleaned[cleaned.size() - 1]
			if a0[0] == an[0] and a0[1] == an[1]:
				cleaned.pop_back()
		if cleaned.size() < 3:
			continue

		for coord in cleaned:
			var x = (coord[0] - config.graph_data.info.center_x) * config.scale_factor
			var z = -(coord[1] - config.graph_data.info.center_y) * config.scale_factor
			var p3 = Vector3(x, 0.0, z)
			bottom3.append(p3)
			top3.append(p3 + Vector3(0.0, height * config.scale_factor, 0.0))
			poly2d.append(Vector2(x, z))

		var area := 0.0
		for i in range(poly2d.size()):
			var j = (i + 1) % poly2d.size()
			area += poly2d[i].x * poly2d[j].y - poly2d[j].x * poly2d[i].y
		if area < 0.0:
			poly2d.reverse()
			bottom3.reverse()
			top3.reverse()

		var idx := Geometry2D.triangulate_polygon(poly2d)
		if idx.size() >= 3:
			for k in range(0, idx.size(), 3):
				var a_pt := top3[idx[k]]
				var b_pt := top3[idx[k + 1]]
				var c_pt := top3[idx[k + 2]]
				var n := -(b_pt - a_pt).cross(c_pt - a_pt).normalized()
				st.set_normal(n); st.add_vertex(a_pt)
				st.set_normal(n); st.add_vertex(b_pt)
				st.set_normal(n); st.add_vertex(c_pt)

		for i in range(bottom3.size()):
			var j = (i + 1) % bottom3.size()
			var v0 = bottom3[i]
			var v1 = bottom3[j]
			var v2 = top3[j]
			var v3 = top3[i]

			var n1 := -(v1 - v0).cross(v2 - v0).normalized()
			st.set_normal(n1); st.add_vertex(v0)
			st.set_normal(n1); st.add_vertex(v1)
			st.set_normal(n1); st.add_vertex(v2)

			var n2 := -(v3 - v2).cross(v0 - v2).normalized()
			st.set_normal(n2); st.add_vertex(v2)
			st.set_normal(n2); st.add_vertex(v3)
			st.set_normal(n2); st.add_vertex(v0)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.486, 0.486, 0.486, 1.0)
	mat.roughness = 0.9
	st.set_material(mat)

	return st.commit()
