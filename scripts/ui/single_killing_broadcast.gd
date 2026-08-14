class_name SingleKillingBroadcast
extends PanelContainer

@onready var killer_label: Label = $HBoxContainer/Killer
@onready var victim_label: Label = $HBoxContainer/BeKilled
@onready var lifetime_timer: Timer = $LifetimeTimer

var _dismiss_tween: Tween

func configure(killer_name: String, killer_color: Color, victim_name: String, victim_color: Color, lifetime_sec: float) -> void:
	killer_label.text = killer_name
	killer_label.add_theme_color_override("font_color", killer_color)
	victim_label.text = victim_name
	victim_label.add_theme_color_override("font_color", victim_color)
	modulate = Color.WHITE
	custom_minimum_size.y = 28.0
	lifetime_timer.start(lifetime_sec)

func dismiss() -> void:
	if _dismiss_tween != null:
		return
	lifetime_timer.stop()
	_dismiss_tween = create_tween()
	_dismiss_tween.set_parallel(true)
	_dismiss_tween.tween_property(self, "modulate:a", 0.0, 0.24).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_dismiss_tween.tween_property(self, "custom_minimum_size:y", 0.0, 0.24).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_dismiss_tween.set_parallel(false)
	_dismiss_tween.tween_callback(queue_free)

func _on_lifetime_timer_timeout() -> void:
	dismiss()
