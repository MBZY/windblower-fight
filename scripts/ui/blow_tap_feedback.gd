class_name BlowTapFeedback
extends Control

@onready var wind_icon: Label = $Content/WindIcon
@onready var value_label: Label = $Content/Value
@onready var combo_label: Label = $Content/Combo

func configure(combo: int, gain: float, intensity: float) -> void:
	value_label.text = "+%d%%" % roundi(gain * 100.0)
	combo_label.text = "x%d" % combo
	wind_icon.modulate = Color(0.65, 0.95, 1.0).lerp(Color(1.0, 0.72, 0.25), clampf(intensity, 0.0, 1.0))
	_launch()

func _launch() -> void:
	modulate = Color.WHITE
	scale = Vector2.ONE * 0.8
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "position:y", position.y - 52.0, 0.65).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "modulate:a", 0.0, 0.65).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(self, "scale", Vector2.ONE, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.set_parallel(false)
	tween.tween_callback(queue_free)
