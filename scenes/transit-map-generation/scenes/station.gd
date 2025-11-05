extends Node2D

@export var radius: float = 50.0:
	set(value):
		radius = value
		queue_redraw()

@export var outer_color: Color = Color.RED:
	set(value):
		outer_color = value
		queue_redraw()

@export var inner_color: Color = Color.WHITE:
	set(value):
		inner_color = value
		queue_redraw()

@export_range(0, 1, 0.01)
var ring_thickness_ratio: float = 0.2:
	set(value):
		ring_thickness_ratio = clamp(value, 0, 1)
		queue_redraw()

func _draw():
	var ring_thickness = radius * ring_thickness_ratio
	var inner_radius = radius - ring_thickness

	# Outer ring
	draw_circle(Vector2.ZERO, radius, outer_color)
	# Inner white area
	draw_circle(Vector2.ZERO, inner_radius, inner_color)
