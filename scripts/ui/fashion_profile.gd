class_name FashionProfile
extends RefCounted

const PROFILE_PATH := "user://player_profile.cfg"
const PROFILE_SECTION := "fashion"
const SLOTS: PackedStringArray = ["back", "body", "hands", "face", "head"]

static func empty_loadout() -> Dictionary:
	var result: Dictionary = {}
	for slot_name in SLOTS:
		result[slot_name] = ""
	return result

static func load_loadout(catalog: FashionCatalog = null) -> Dictionary:
	var config := ConfigFile.new()
	var result := empty_loadout()
	if config.load(PROFILE_PATH) == OK:
		for slot_name in SLOTS:
			result[slot_name] = String(config.get_value(PROFILE_SECTION, slot_name, ""))
	return catalog.sanitize_loadout(result) if catalog != null else sanitize_loadout(result)

static func save_loadout(value: Dictionary, catalog: FashionCatalog = null) -> Dictionary:
	var sanitized := catalog.sanitize_loadout(value) if catalog != null else sanitize_loadout(value)
	var config := ConfigFile.new()
	config.load(PROFILE_PATH)
	for slot_name in SLOTS:
		config.set_value(PROFILE_SECTION, slot_name, String(sanitized.get(slot_name, "")))
	config.save(PROFILE_PATH)
	return sanitized

static func sanitize_loadout(value: Dictionary) -> Dictionary:
	var result := empty_loadout()
	for slot_name in SLOTS:
		result[slot_name] = String(value.get(slot_name, "")).strip_edges().substr(0, 64)
	return result
