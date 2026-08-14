class_name GachaOption
extends PanelContainer

signal option_pressed(option: GachaOption)

var entry: EnhancementEntry

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		option_pressed.emit(self)
