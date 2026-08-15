class_name FashionCatalog
extends Resource

const SLOTS: PackedStringArray = ["back", "body", "hands", "face", "head"]

@export var items: Array[FashionItem] = []

func item_by_id(item_id: StringName) -> FashionItem:
	if item_id == &"":
		return null
	for item in items:
		if item != null and item.id == item_id:
			return item
	return null

func items_for_slot(slot_name: String) -> Array[FashionItem]:
	var result: Array[FashionItem] = []
	for item in items:
		if item != null and item.slot == slot_name:
			result.append(item)
	return result

func sanitize_loadout(value: Dictionary) -> Dictionary:
	var result := empty_loadout()
	for slot_name in SLOTS:
		var item_id := StringName(String(value.get(slot_name, "")).strip_edges())
		var item := item_by_id(item_id)
		if item != null and item.slot == slot_name:
			result[slot_name] = String(item.id)
	return result

func empty_loadout() -> Dictionary:
	var result: Dictionary = {}
	for slot_name in SLOTS:
		result[slot_name] = ""
	return result
