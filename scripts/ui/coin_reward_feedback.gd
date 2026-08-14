class_name CoinRewardFeedback
extends Control

@onready var value_label: Label = $Value

func configure(amount: int) -> void:
	value_label.text = "+%d COIN" % amount
	modulate = Color.WHITE
	scale = Vector2.ONE * 0.85
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "position:y", position.y - 68.0, 0.8).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "modulate:a", 0.0, 0.8).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(self, "scale", Vector2.ONE * 1.1, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.set_parallel(false)
	tween.tween_callback(queue_free)
