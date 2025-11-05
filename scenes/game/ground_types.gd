extends Node3D

@export_file("*.json") var json_path: String
@export var show_outlines: bool = true
@export var ground_y: float = 0.0

# Category colors (for fill)
var category_colors := {
	"water": Color(0.2, 0.4, 0.9, 1.0),
	"artificial_greenery": Color(0.3, 0.8, 0.3, 1.0),
	"natural_greenery": Color(0.1, 0.5, 0.1, 1.0),
	"beach": Color(0.9, 0.8, 0.6, 1.0)
}

# Rendering hierarchy (Y offsets to avoid z-fighting)
# Higher numbers render visually on top.
var layer_offsets := {
	"water": 0.000,
	"beach": 0.005,
	"artificial_greenery": 0.010,
	"natural_greenery": 0.015
}

# Outline color (red)
var outline_color := Color(1, 0, 0, 1)

var config: MapConfig

func _ready():
	config = get_tree().get_root().get_node("Main/config")
	
	if json_path == "":
		push_warning("No JSON file selected.")
		return

	var f := FileAccess.open(json_path, FileAccess.READ)
	if f == null:
		push_error("Failed to open JSON: " + json_path)
		return

	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Invalid JSON structure in: " + json_path)
		return

	var categories = parsed.get("categories", {})
	for cat_name in categories.keys():
		var poly_list = categories[cat_name]
		if poly_list == null or poly_list.is_empty():
			continue

		var fill_mat := StandardMaterial3D.new()
		fill_mat.albedo_color = category_colors.get(cat_name, Color(1, 1, 1, 1))
		fill_mat.roughness = 1.0
		fill_mat.cull_mode = BaseMaterial3D.CULL_BACK

		var y_offset = layer_offsets.get(cat_name, 0.02)

		for poly_coords in poly_list:
			if poly_coords.size() < 3:
				continue

			# --- Build vertex arrays ---
			var verts3 := PackedVector3Array()
			var verts2 := PackedVector2Array()  # used for triangulation
			for coord in poly_coords:
				var x = (coord[0] - config.graph_data.info.center_x) * config.scale_factor
				var z = -(coord[1] - config.graph_data.info.center_y) * config.scale_factor
				verts3.append(Vector3(x, ground_y + y_offset, z))
				verts2.append(Vector2(x, z))

			# --- Triangulate polygon (handles concave shapes) ---
			var indices := Geometry2D.triangulate_polygon(verts2)
			if indices.is_empty():
				continue

			# --- Create filled mesh ---
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			st.set_material(fill_mat)

			for i in indices:
				st.add_vertex(verts3[i])

			var mesh := st.commit()
			if mesh == null:
				continue

			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			add_child(mi)

			# --- Optional red outline ---
			if show_outlines:
				var st_line := SurfaceTool.new()
				st_line.begin(Mesh.PRIMITIVE_LINES)
				var line_mat := StandardMaterial3D.new()
				line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				line_mat.albedo_color = outline_color
				st_line.set_material(line_mat)

				for j in range(verts3.size()):
					var a := verts3[j]
					var b := verts3[(j + 1) % verts3.size()]
					st_line.add_vertex(a)
					st_line.add_vertex(b)

				var line_mesh := st_line.commit()
				if line_mesh != null:
					var line_inst := MeshInstance3D.new()
					line_inst.mesh = line_mesh
					add_child(line_inst)

	print("✅ Loaded and rendered 3D ground polygons (layered) from:", json_path)
