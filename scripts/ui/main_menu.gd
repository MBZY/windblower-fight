class_name MainMenu
extends Control

signal create_room_requested(room_name: String)
signal browse_rooms_requested
signal join_ip_requested(host_ip: String)
signal profile_submitted(display_name: String)

@onready var ip_input: LineEdit = %IpInput
@onready var name_input: LineEdit = %NameInput

const PROFILE_PATH := "user://player_profile.cfg"
const PROFILE_SECTION := "profile"
const PROFILE_NAME_KEY := "display_name"

func _ready() -> void:
	name_input.text = _load_profile_name()

func profile_name() -> String:
	return _sanitize_name(name_input.text)

func _on_create_room_pressed() -> void:
	_submit_profile()
	create_room_requested.emit("Sky Leaf Room")

func _on_find_rooms_pressed() -> void:
	browse_rooms_requested.emit()

func _on_join_ip_pressed() -> void:
	var host := ip_input.text.strip_edges()
	if not host.is_empty():
		_submit_profile()
		join_ip_requested.emit(host)

func _on_name_input_text_submitted(_value: String) -> void:
	_submit_profile()

func _on_name_input_focus_exited() -> void:
	_submit_profile()

func _submit_profile() -> void:
	var display_name := profile_name()
	name_input.text = display_name
	var config := ConfigFile.new()
	config.set_value(PROFILE_SECTION, PROFILE_NAME_KEY, display_name)
	config.save(PROFILE_PATH)
	profile_submitted.emit(display_name)

func _load_profile_name() -> String:
	var config := ConfigFile.new()
	if config.load(PROFILE_PATH) != OK:
		return "Player"
	return _sanitize_name(String(config.get_value(PROFILE_SECTION, PROFILE_NAME_KEY, "Player")))

func _sanitize_name(value: String) -> String:
	var trimmed := value.strip_edges().substr(0, 16)
	return "Player" if trimmed.is_empty() else trimmed
