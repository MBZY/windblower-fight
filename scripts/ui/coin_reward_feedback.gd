class_name CoinRewardFeedback
extends Control

signal arrived

@onready var flight_path: Path2D = $FlightPath
@onready var follower: PathFollow2D = $FlightPath/Follower
@onready var trail: GPUParticles2D = $FlightPath/Follower/Trail
@onready var coin_visual: Control = $FlightPath/Follower/CoinVisual
@onready var amount_label: Label = $FlightPath/Follower/Amount

func configure(amount: int, start_position: Vector2, end_position: Vector2) -> void:
	amount_label.text = "+%d" % amount
	flight_path.curve = flight_path.curve.duplicate()
	flight_path.curve.clear_points()
	var lift := clampf(start_position.distance_to(end_position) * 0.24, 84.0, 190.0)
	var control := Vector2(lerpf(start_position.x, end_position.x, 0.48), minf(start_position.y, end_position.y) - lift)
	flight_path.curve.add_point(start_position, Vector2.ZERO, control - start_position)
	flight_path.curve.add_point(end_position, control - end_position, Vector2.ZERO)
	follower.progress_ratio = 0.0
	coin_visual.visible = true
	coin_visual.scale = Vector2.ONE * 0.72
	coin_visual.rotation = -0.18
	amount_label.visible = true
	trail.restart()
	trail.emitting = true
	var tween := create_tween().set_parallel(true)
	tween.tween_property(follower, "progress_ratio", 1.0, 0.82).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(coin_visual, "rotation", TAU * 1.45, 0.82).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(coin_visual, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.chain().tween_callback(_finish_flight)

func _finish_flight() -> void:
	trail.emitting = false
	coin_visual.visible = false
	amount_label.visible = false
	arrived.emit()
	await get_tree().create_timer(0.5).timeout
	queue_free()
