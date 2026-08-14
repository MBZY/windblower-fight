class_name LanDiscovery
extends Node

signal room_seen(room: Dictionary)
signal room_expired(host_ip: String)

@export var discovery_port: int = 47777
@export var beacon_interval_sec: float = 1.0
@export var room_timeout_sec: float = 3.0
@export var protocol_version: String = "1.0.0"

var room_name: String = "Sky Leaf Room"
var game_port: int = 10567
var max_players: int = 8
var map_size: String = "medium"
var room_state: String = "waiting"
var _socket := PacketPeerUDP.new()
var _known_rooms: Dictionary = {}
var _listener_started := false

func _ready() -> void:
	# Kept as a compatibility scene node for older layouts. The active
	# NetworkManager owns UDP discovery, so this transport stays closed.
	_socket.close()

func start_listener() -> int:
	_listener_started = false
	return ERR_UNAVAILABLE

func stop_listener() -> void:
	_socket.close()
	_listener_started = false

func get_rooms() -> Array:
	var result: Array = []
	for entry in _known_rooms.values():
		result.append(Dictionary(entry.get("room", {})).duplicate(true))
	return result

func publish_beacon() -> void:
	return

func poll() -> void:
	return

func _local_ip() -> String:
	var addresses := IP.get_local_addresses()
	for address in addresses:
		if String(address).contains(".") and not String(address).begins_with("127."):
			return String(address)
	return "127.0.0.1"
