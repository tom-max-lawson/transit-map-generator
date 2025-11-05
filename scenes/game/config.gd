extends Node
class_name MapConfig

# Configurable by user
@export var scale_factor: float = 1.0
@export_file("*.json") var graph_path: String
@export_file("*.json") var poi_path: String

# Graph network of current map
var graph_data: GraphData

# Demand model of current map
var demand_model: DemandModel

# As long as config is the top-most node, this will be called first among its siblings
func _ready() -> void:
	graph_data = GraphData.new(graph_path)

	demand_model = DemandModel.new()
	demand_model.load_poi_data(poi_path, graph_data.info.center_x, graph_data.info.center_y)
	add_child(demand_model)
