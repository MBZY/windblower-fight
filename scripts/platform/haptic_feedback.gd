class_name HapticFeedback
extends RefCounted

static func light() -> void:
	_vibrate(22, 0.22)

static func medium() -> void:
	_vibrate(42, 0.52)

static func heavy() -> void:
	_vibrate(85, 0.9)

static func alert() -> void:
	_vibrate(120, 0.75)

static func wind_tap(intensity: float) -> void:
	_vibrate(int(lerpf(18.0, 36.0, clampf(intensity, 0.0, 1.0))), lerpf(0.18, 0.72, clampf(intensity, 0.0, 1.0)))

static func _vibrate(duration_ms: int, amplitude: float) -> void:
	if not OS.has_feature("mobile") and not OS.has_feature("android"):
		return
	Input.vibrate_handheld(maxi(duration_ms, 1), clampf(amplitude, 0.0, 1.0))
