class_name FashionPanel
extends Control

signal closed
signal loadout_changed(loadout: Dictionary)

@export var catalog: FashionCatalog

@onready var tabs: TabBar = %FashionTabs
@onready var item_list: ItemList = %FashionItemList
@onready var selection_label: Label = %FashionSelectionLabel
@onready var preview_layers: Dictionary = {
	"back": %PreviewBack,
	"body": %PreviewBody,
	"hands": %PreviewHands,
	"face": %PreviewFace,
	"head": %PreviewHead,
}

var _loadout: Dictionary = {}
var _visible_items: Array[FashionItem] = []
var _panel_tween: Tween

func _ready() -> void:
	if catalog == null:
		catalog = load("res://resources/fashion/catalog.tres") as FashionCatalog
	_loadout = FashionProfile.load_loadout(catalog)
	_refresh_preview()
	_refresh_items()

func open() -> void:
	_loadout = FashionProfile.load_loadout(catalog)
	_refresh_preview()
	_refresh_items()
	visible = true
	modulate.a = 0.0
	scale = Vector2(0.96, 0.96)
	pivot_offset = size * 0.5
	if _panel_tween != null:
		_panel_tween.kill()
	_panel_tween = create_tween().set_parallel(true)
	_panel_tween.tween_property(self, "modulate:a", 1.0, 0.16)
	_panel_tween.tween_property(self, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	item_list.grab_focus()

func current_loadout() -> Dictionary:
	return _loadout.duplicate(true)

func _on_tab_changed(_tab_index: int) -> void:
	_refresh_items()

func _on_item_selected(index: int) -> void:
	var slot_name := _current_slot()
	var item_id := ""
	var display_name := "无"
	if index > 0 and index - 1 < _visible_items.size():
		var item := _visible_items[index - 1]
		item_id = String(item.id)
		display_name = item.display_name
	_loadout[slot_name] = item_id
	_loadout = FashionProfile.save_loadout(_loadout, catalog)
	selection_label.text = "%s：%s" % [_slot_title(slot_name), display_name]
	_refresh_preview()
	loadout_changed.emit(_loadout.duplicate(true))
	HapticFeedback.light()

func _on_close_pressed() -> void:
	if _panel_tween != null:
		_panel_tween.kill()
	_panel_tween = create_tween().set_parallel(true)
	_panel_tween.tween_property(self, "modulate:a", 0.0, 0.12)
	_panel_tween.tween_property(self, "scale", Vector2(0.97, 0.97), 0.12)
	_panel_tween.chain().tween_callback(func() -> void:
		visible = false
		scale = Vector2.ONE
		closed.emit()
	)
	HapticFeedback.light()

func _refresh_items() -> void:
	if item_list == null or catalog == null:
		return
	item_list.clear()
	_visible_items = catalog.items_for_slot(_current_slot())
	item_list.add_item("无")
	for item in _visible_items:
		item_list.add_item(item.display_name, item.texture)
	var selected_id := String(_loadout.get(_current_slot(), ""))
	var selected_index := 0
	for index in range(_visible_items.size()):
		if String(_visible_items[index].id) == selected_id:
			selected_index = index + 1
			break
	item_list.select(selected_index)
	var selected_name := "无" if selected_index == 0 else _visible_items[selected_index - 1].display_name
	selection_label.text = "%s：%s" % [_slot_title(_current_slot()), selected_name]

func _refresh_preview() -> void:
	if catalog == null:
		return
	for slot_name in FashionCatalog.SLOTS:
		var layer := preview_layers.get(slot_name) as TextureRect
		if layer == null:
			continue
		var item := catalog.item_by_id(StringName(String(_loadout.get(slot_name, ""))))
		layer.texture = item.texture if item != null else null

func _current_slot() -> String:
	if tabs == null:
		return "head"
	var slots: PackedStringArray = ["head", "face", "body", "hands", "back"]
	return slots[clampi(tabs.current_tab, 0, slots.size() - 1)]

func _slot_title(slot_name: String) -> String:
	match slot_name:
		"head": return "头部"
		"face": return "面部"
		"body": return "服装"
		"hands": return "手部"
		"back": return "背部"
	return "时装"
