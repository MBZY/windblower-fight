class_name GachaOption
extends PanelContainer

signal option_pressed(option: GachaOption)

var entry: EnhancementEntry

@onready var description_label: RichTextLabel = $PanelContainer/VBoxContainer/RichTextLabel

func configure(next_entry: EnhancementEntry, price: int, current_stack: int) -> void:
	entry = next_entry
	description_label.text = "[center][font_size=18][b]%s[/b][/font_size]\n%s\n[color=#74d7ff]当前 %d/%d[/color]\n[color=#ffd166][b]%d 点[/b][/color][/center]" % [entry.display_name, entry.description, current_stack, entry.max_stack, price]

func _on_select_button_pressed() -> void:
	if entry != null:
		option_pressed.emit(self)
