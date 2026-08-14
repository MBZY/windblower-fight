class_name LanRoomDiscovery
extends RefCounted

## UDP room discovery is deliberately transport-only. Game and UI code receive
## normalized room dictionaries through signals and never need to touch sockets.

signal room_seen(room: Dictionary)
signal room_expired(room_key: String, room: Dictionary)
signal incompatible_room_seen(room: Dictionary)

const DEFAULT_BROADCAST_ADDRESS := "255.255.255.255"
const MAX_BEACON_BYTES := 4096

var discovery_port: int = 47777
var protocol_version: String = "1.0.0"
var room_timeout_sec: float = 3.0
var broadcast_address: String = DEFAULT_BROADCAST_ADDRESS

var _listener := PacketPeerUDP.new()
var _broadcaster := PacketPeerUDP.new()
var _scanning := false
var _advertising := false
var _beacon: Dictionary = {}
var _known_rooms: Dictionary = {}


func configure(port: int, version: String, timeout_sec: float) -> void:
	discovery_port = clampi(port, 1, 65535)
	protocol_version = version.strip_edges()
	room_timeout_sec = maxf(timeout_sec, 0.1)


func start_scanning() -> Error:
	if _scanning:
		return OK
	_listener.close()
	_listener = PacketPeerUDP.new()
	var error := _listener.bind(discovery_port)
	if error == OK:
		_scanning = true
	return error


func stop_scanning() -> void:
	_scanning = false
	_listener.close()
	_listener = PacketPeerUDP.new()
	_known_rooms.clear()


func start_advertising(beacon: Dictionary) -> Error:
	_beacon = beacon.duplicate(true)
	_broadcaster.close()
	_broadcaster = PacketPeerUDP.new()
	_broadcaster.set_broadcast_enabled(true)
	_broadcaster.set_dest_address(broadcast_address, discovery_port)
	_advertising = true
	return publish_beacon()


func stop_advertising() -> void:
	_advertising = false
	_broadcaster.close()
	_broadcaster = PacketPeerUDP.new()


func set_beacon(beacon: Dictionary) -> void:
	_beacon = beacon.duplicate(true)


func publish_beacon() -> Error:
	if not _advertising:
		return ERR_UNCONFIGURED
	var payload := _beacon.duplicate(true)
	payload["version"] = protocol_version
	return _broadcaster.put_packet(JSON.stringify(payload).to_utf8_buffer())


func poll() -> void:
	if not _scanning:
		return
	while _listener.get_available_packet_count() > 0:
		var packet := _listener.get_packet()
		if packet.size() == 0 or packet.size() > MAX_BEACON_BYTES:
			continue
		var parsed = JSON.parse_string(packet.get_string_from_utf8())
		if not (parsed is Dictionary):
			continue
		var room: Dictionary = parsed
		if String(room.get("version", "")) != protocol_version:
			incompatible_room_seen.emit(room.duplicate(true))
			continue
		var source_ip := _listener.get_packet_ip()
		var game_port := int(room.get("game_port", 0))
		if source_ip.is_empty() or game_port < 1 or game_port > 65535:
			continue
		# The UDP source is authoritative. Never trust host_ip sent in the JSON.
		room["host_ip"] = source_ip
		var room_key := "%s:%d" % [source_ip, game_port]
		var previous: Dictionary = _known_rooms.get(room_key, {})
		_known_rooms[room_key] = {"room": room.duplicate(true), "last_seen_ms": Time.get_ticks_msec()}
		if previous.is_empty() or previous.get("room", {}) != room:
			room_seen.emit(room.duplicate(true))


func expire_rooms() -> void:
	var now := Time.get_ticks_msec()
	var expired_keys: Array[String] = []
	for room_key_variant in _known_rooms.keys():
		var room_key := String(room_key_variant)
		var entry: Dictionary = _known_rooms[room_key]
		if now - int(entry.get("last_seen_ms", now)) > int(room_timeout_sec * 1000.0):
			expired_keys.append(room_key)
	for room_key in expired_keys:
		var entry: Dictionary = _known_rooms[room_key]
		_known_rooms.erase(room_key)
		room_expired.emit(room_key, Dictionary(entry.get("room", {})).duplicate(true))


func rooms() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry_variant in _known_rooms.values():
		var entry: Dictionary = entry_variant
		result.append(Dictionary(entry.get("room", {})).duplicate(true))
	return result


func get_preferred_local_address() -> String:
	for address_variant in IP.get_local_addresses():
		var address := String(address_variant)
		if address.contains(".") and not address.begins_with("127."):
			return address
	return "127.0.0.1"
