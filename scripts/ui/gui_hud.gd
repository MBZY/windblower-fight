class_name GuiHud
extends Control

const BLOW_TAP_FEEDBACK_SCENE := preload("res://scenes/ui/blow_tap_feedback.tscn")
const COIN_REWARD_FEEDBACK_SCENE := preload("res://scenes/ui/coin_reward_feedback.tscn")
const KILL_BROADCAST_SCENE := preload("res://scenes/ui/single_killing_broadcast.tscn")
const TEAM_RED := Color(1.0, 0.32, 0.4)
const TEAM_BLUE := Color(0.36, 0.76, 1.0)
const NEUTRAL := Color(0.86, 0.9, 0.94)

@onready var rest_time_label: Label = $VBoxContainer/RestTime
@onready var rest_time_progress: ProgressBar = $VBoxContainer/RestTimeProgress
@onready var winning_progress: TextureProgressBar = $VBoxContainer/HBoxContainer/VBoxContainer/PanelContainer/WiningProgress
@onready var score1_label: Label = $VBoxContainer/HBoxContainer/VBoxContainer/HBoxContainer2/Score1
@onready var score2_label: Label = $VBoxContainer/HBoxContainer/VBoxContainer/HBoxContainer2/Score2
@onready var group_money_label: Label = $VBoxContainer/HBoxContainer/VBoxContainer/HBoxContainer/GroupMoney
@onready var group_money2_label: Label = $VBoxContainer/HBoxContainer/VBoxContainer/HBoxContainer/GroupMoney2
@onready var player_list_a: VBoxContainer = $VBoxContainer/HBoxContainer/PlayerListA
@onready var player_list_b: VBoxContainer = $VBoxContainer/HBoxContainer/PlayerListB
@onready var gacha_alarm: Label = $Gacha/GachaAlarm
@onready var gacha_button: TextureButton = $Gacha/GachaButton
@onready var gacha_panel: MarginContainer = $GachaPanel
@onready var blow_button: Button = %BlowButton
@onready var fan_rotor: Node2D = %FanRotor
@onready var tap_feedback_layer: Control = %TapFeedbackLayer
@onready var broadcast_list: VBoxContainer = %KillingBroadcastList
@onready var broadcast_board: PanelContainer = $KillingBroadcastBoard
@onready var blow_tap_sfx: AudioStreamPlayer = %BlowTapSfx
@onready var kill_sfx: AudioStreamPlayer = %KillSfx
@onready var coin_sfx: AudioStreamPlayer = %CoinSfx
@onready var fall_sfx: AudioStreamPlayer = %FallSfx
@onready var blow_loop_sfx: AudioStreamPlayer = %BlowLoopSfx
@onready var countdown_tick_sfx: AudioStreamPlayer = %CountdownTickSfx
@onready var match_start_sfx: AudioStreamPlayer = %MatchStartSfx
@onready var gacha_open_sfx: AudioStreamPlayer = %GachaOpenSfx
@onready var gacha_select_sfx: AudioStreamPlayer = %GachaSelectSfx
@onready var ui_cancel_sfx: AudioStreamPlayer = %UiCancelSfx
@onready var skill_fail_sfx: AudioStreamPlayer = %SkillFailSfx
@onready var victory_sfx: AudioStreamPlayer = %VictorySfx
@onready var defeat_sfx: AudioStreamPlayer = %DefeatSfx
@onready var countdown_overlay: Control = %CountdownOverlay
@onready var countdown_card: PanelContainer = %CountdownCard
@onready var countdown_title: Label = %CountdownTitle
@onready var countdown_value: Label = %CountdownValue
var gacha_options: Array[GachaOption] = []

var _session: GameSession
var _local_player_id := 1
var _price := 50
var _fan_rotation_speed := 0.0
var _fan_boost_speed := 0.0
var _shake_tween: Tween
var _camera_shake_tween: Tween
var _countdown_tween: Tween
var _countdown_pulse_tween: Tween
var _gacha_pulse_tween: Tween
var _countdown_kind: StringName = &""
var _respawn_deadline_msec := 0
var _last_center_count := -1

func _ready() -> void:
	gacha_options.assign(get_tree().get_nodes_in_group("gacha_options"))
	if gacha_options.is_empty():
		gacha_options.assign([get_node("GachaPanel/PanelContainer/VBoxContainer/HBoxContainer/GachaOption1"), get_node("GachaPanel/PanelContainer/VBoxContainer/HBoxContainer/GachaOption2"), get_node("GachaPanel/PanelContainer/VBoxContainer/HBoxContainer/GachaOption3")])

func bind_session(session: GameSession) -> void:
	_session = session
	_local_player_id = session.local_player_id()
	_price = session.balance.skill_upgrade_price if session.balance != null else _price
	session.score_changed.connect(_on_score_changed)
	session.countdown_changed.connect(_on_countdown_changed)
	session.respawn_countdown_started.connect(_on_respawn_countdown_started)
	session.player_respawned.connect(_on_player_respawned)
	session.skill_points_changed.connect(_on_skill_points_changed)
	session.phase_changed.connect(_on_phase_changed)
	session.match_finished.connect(_on_match_finished)
	session.player_eliminated.connect(_on_player_eliminated)
	_on_score_changed(session.red_score, session.blue_score)
	_on_phase_changed(session.phase)
	_refresh_player_lists()
	_update_money_labels()

func _process(_delta: float) -> void:
	_update_fan(_delta)
	if _session == null:
		return
	_update_center_countdown()
	if _session.phase == &"playing" and _session.match_timer != null:
		var remaining := _session.match_time_left()
		rest_time_label.text = "%ds" % ceili(remaining)
		rest_time_progress.value = 100.0 * (1.0 - remaining / maxf(_session.balance.match_duration_sec, 1.0))
	elif _session.phase == &"countdown":
		rest_time_label.text = "%ds" % ceili(_session.countdown_timer.time_left)
		rest_time_progress.value = 100.0

func _on_score_changed(red: int, blue: int) -> void:
	score1_label.text = str(red)
	score2_label.text = str(blue)
	var total := red + blue
	winning_progress.value = 50.0 if total == 0 else 100.0 * red / float(total)

func _on_countdown_changed(seconds_left: int) -> void:
	rest_time_label.text = "%ds" % seconds_left
	rest_time_progress.value = 100.0
	_show_center_countdown(&"match", "准备开战", seconds_left)

func _on_skill_points_changed(_player_id: int, _points: int) -> void:
	_update_money_labels()
	_refresh_player_lists()

func _on_phase_changed(phase: StringName) -> void:
	if phase != &"countdown" and _countdown_kind == &"match":
		_hide_center_countdown()
	if phase != &"playing" and blow_loop_sfx.playing:
		blow_loop_sfx.stop()
	match phase:
		&"playing", &"countdown", &"score_lock":
			gacha_panel.visible = false
			$Gacha.visible = true
		&"results":
			$Gacha.visible = false
		_:
			$Gacha.visible = false
			gacha_panel.visible = false

func _on_match_finished(winner: int, red: int, blue: int) -> void:
	rest_time_label.text = "结束"
	rest_time_progress.value = 100.0
	_hide_center_countdown()
	var local := _local_player()
	if winner >= 0 and local != null and local.team == winner:
		victory_sfx.play()
	elif winner >= 0:
		defeat_sfx.play()
	else:
		ui_cancel_sfx.play()

func _on_respawn_countdown_started(player_id: int, seconds: float) -> void:
	if _session == null or player_id != _session.local_player_id():
		return
	_respawn_deadline_msec = Time.get_ticks_msec() + int(seconds * 1000.0)
	_show_center_countdown(&"respawn", "即将复活", ceili(seconds))

func _on_player_respawned(player_id: int) -> void:
	if _session == null or player_id != _session.local_player_id():
		return
	_respawn_deadline_msec = 0
	if _countdown_kind == &"respawn":
		_hide_center_countdown()

func _update_center_countdown() -> void:
	var seconds_left := -1
	if _countdown_kind == &"match" and _session.phase == &"countdown":
		seconds_left = ceili(_session.countdown_timer.time_left)
	elif _countdown_kind == &"respawn" and _respawn_deadline_msec > 0:
		seconds_left = ceili(maxf(float(_respawn_deadline_msec - Time.get_ticks_msec()) / 1000.0, 0.0))
	if seconds_left >= 0 and seconds_left != _last_center_count:
		_set_center_count(seconds_left)

func _show_center_countdown(kind: StringName, title: String, seconds_left: int) -> void:
	_countdown_kind = kind
	countdown_title.text = title
	_set_center_count(seconds_left)
	if _countdown_tween != null:
		_countdown_tween.kill()
	countdown_overlay.visible = true
	countdown_card.visible = true
	var viewport_size := countdown_overlay.size
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		viewport_size = get_viewport_rect().size
	var target := Vector2((viewport_size.x - countdown_card.size.x) * 0.5, (viewport_size.y - countdown_card.size.y) * 0.5)
	countdown_card.position = Vector2(viewport_size.x + 32.0, target.y)
	countdown_card.modulate.a = 0.0
	_countdown_tween = create_tween().set_parallel(true)
	_countdown_tween.tween_property(countdown_card, "position", target, 0.42).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_countdown_tween.tween_property(countdown_card, "modulate:a", 1.0, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _hide_center_countdown() -> void:
	if _countdown_kind == &"" or countdown_card == null:
		return
	_countdown_kind = &""
	_last_center_count = -1
	if _countdown_tween != null:
		_countdown_tween.kill()
	_countdown_tween = create_tween().set_parallel(true)
	_countdown_tween.tween_property(countdown_card, "position:x", -countdown_card.size.x - 32.0, 0.34).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	_countdown_tween.tween_property(countdown_card, "modulate:a", 0.0, 0.22).set_delay(0.1)
	_countdown_tween.chain().tween_callback(func() -> void:
		countdown_card.visible = false
		countdown_overlay.visible = false
	)

func _set_center_count(seconds_left: int) -> void:
	_last_center_count = seconds_left
	countdown_value.text = "GO!" if seconds_left <= 0 and _countdown_kind == &"match" else str(maxi(seconds_left, 0))
	if seconds_left > 0:
		countdown_tick_sfx.pitch_scale = lerpf(1.0, 1.16, clampf(1.0 - float(seconds_left - 1) / 4.0, 0.0, 1.0))
		countdown_tick_sfx.play()
	elif _countdown_kind == &"match":
		match_start_sfx.play()
	if _countdown_pulse_tween != null:
		_countdown_pulse_tween.kill()
	countdown_value.pivot_offset = countdown_value.size * 0.5
	countdown_value.scale = Vector2(1.16, 1.16)
	_countdown_pulse_tween = create_tween()
	_countdown_pulse_tween.tween_property(countdown_value, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _update_money_labels() -> void:
	var local := _local_player()
	if local != null:
		gacha_alarm.text = "%d$" % local.skill_points
	var team0 := 0
	var team1 := 0
	if _session != null:
		for player_variant in _session.players.values():
			var player: IslandPlayer = player_variant
			if player.team == 0:
				team0 += player.skill_points
			else:
				team1 += player.skill_points
	group_money_label.text = "%d$" % team0
	group_money2_label.text = "%d$" % team1

func _refresh_player_lists() -> void:
	if _session == null:
		return
	var team_a: Array = []
	var team_b: Array = []
	for player_variant in _session.players.values():
		var player: IslandPlayer = player_variant
		if player.team == 0:
			team_a.append(player)
		else:
			team_b.append(player)
	_fill_player_list(player_list_a, team_a)
	_fill_player_list(player_list_b, team_b)

func _fill_player_list(list_container: VBoxContainer, team_players: Array) -> void:
	for index in range(3):
		var unit: PanelContainer = list_container.get_child(index)
		if index < team_players.size():
			var player: IslandPlayer = team_players[index]
			unit.visible = true
			unit.get_node("PlayerName").text = _session.player_display_name(player.player_id)
			unit.get_node("PlayerMoney").text = "%d$" % player.skill_points
		else:
			unit.visible = false

func _local_player() -> IslandPlayer:
	if _session == null:
		return null
	_local_player_id = _session.local_player_id()
	return _session.players.get(_local_player_id) as IslandPlayer

func _open_gacha() -> void:
	var player := _local_player()
	if player == null or _session == null or _session.phase != &"playing":
		skill_fail_sfx.play()
		return
	if player.skill_points < _price:
		gacha_alarm.text = "金币不足!"
		skill_fail_sfx.play()
		return
	var available := _session.enhancement_catalog.available(player.enhancement_stacks) if _session.enhancement_catalog != null else []
	if available.is_empty():
		gacha_alarm.text = "已全部强化!"
		skill_fail_sfx.play()
		return
	var picks := _weighted_picks(available, 3)
	for index in range(gacha_options.size()):
		var option: GachaOption = gacha_options[index]
		if index < picks.size():
			var entry: EnhancementEntry = picks[index]
			option.configure(entry, _price, int(player.enhancement_stacks.get(entry.id, 0)))
			option.visible = true
		else:
			option.visible = false
	gacha_panel.visible = true
	gacha_open_sfx.play()

func _weighted_picks(pool: Array, count: int) -> Array:
	var candidates: Array = pool.duplicate()
	var picks: Array = []
	var total_weight := 0
	for candidate in candidates:
		total_weight += candidate.weight
	while picks.size() < count and not candidates.is_empty():
		var roll := randf() * total_weight
		var pick_index := 0
		for index in range(candidates.size()):
			roll -= candidates[index].weight
			if roll <= 0.0:
				pick_index = index
				break
		var picked: EnhancementEntry = candidates[pick_index]
		picks.append(picked)
		candidates.remove_at(pick_index)
		total_weight -= picked.weight
	return picks

func _on_gacha_option_pressed(option: GachaOption) -> void:
	if _session == null or option.entry == null:
		return
	_local_player_id = _session.local_player_id()
	var result := _session.request_skill_upgrade(_local_player_id, option.entry.id)
	if result.get("ok", false):
		gacha_panel.visible = false
		gacha_alarm.text = "%d$" % _local_player().skill_points
		gacha_select_sfx.play()
	else:
		gacha_alarm.text = String(result.get("reason", "失败"))
		skill_fail_sfx.play()

func _on_gacha_skip_pressed() -> void:
	gacha_panel.visible = false
	ui_cancel_sfx.play()

func _on_blow_button_down() -> void:
	if _session == null:
		return
	var result: Dictionary = _session.pump_local_wind()
	if result.is_empty():
		return
	_show_blow_feedback(int(result.get("combo", 1)), float(result.get("gain", 0.0)), float(result.get("intensity", 0.0)))
	_fan_boost_speed = maxf(_fan_boost_speed, 18.0 + float(result.get("combo", 1)) * 0.8)
	_shake_screen(1.2 + float(result.get("intensity", 0.0)) * 2.2)
	blow_tap_sfx.pitch_scale = lerpf(0.9, 1.3, float(result.get("intensity", 0.0)))
	blow_tap_sfx.play()

func _on_blow_button_up() -> void:
	return

func _update_fan(delta: float) -> void:
	var intensity := 0.0
	var local_player := _local_player()
	if local_player != null:
		intensity = local_player.wind_intensity
	_fan_boost_speed = move_toward(_fan_boost_speed, 0.0, delta * 20.0)
	var target_speed := TAU * 8.5 * intensity + _fan_boost_speed
	_fan_rotation_speed = move_toward(_fan_rotation_speed, target_speed, delta * 28.0)
	if fan_rotor != null:
		fan_rotor.rotation += _fan_rotation_speed * delta
	var wind_audio_active := _session != null and _session.phase == &"playing" and intensity > 0.04
	if wind_audio_active:
		blow_loop_sfx.volume_db = lerpf(-25.0, -14.0, intensity)
		blow_loop_sfx.pitch_scale = lerpf(0.84, 1.24, intensity)
		if not blow_loop_sfx.playing:
			blow_loop_sfx.play()
	elif blow_loop_sfx.playing:
		blow_loop_sfx.stop()

func _show_blow_feedback(combo: int, gain: float, intensity: float) -> void:
	var feedback := BLOW_TAP_FEEDBACK_SCENE.instantiate() as BlowTapFeedback
	var layer_inverse := tap_feedback_layer.get_global_transform_with_canvas().affine_inverse()
	feedback.position = layer_inverse * blow_button.get_global_rect().get_center() + Vector2(-40.0, -56.0)
	tap_feedback_layer.add_child(feedback)
	feedback.configure(combo, gain, intensity)

func _on_player_eliminated(killer_id: int, victim_id: int, reward: int) -> void:
	if _session == null:
		return
	_show_kill_broadcast(killer_id, victim_id)
	kill_sfx.play()
	if killer_id == _session.local_player_id() and reward > 0:
		_show_coin_feedback(reward)
	elif victim_id == _session.local_player_id():
		fall_sfx.play()

func _show_kill_broadcast(killer_id: int, victim_id: int) -> void:
	var max_entries := _session.balance.kill_broadcast_max_entries if _session.balance != null else 4
	var visible_entries: Array[SingleKillingBroadcast] = []
	for child in broadcast_list.get_children():
		if child is SingleKillingBroadcast and child.visible:
			visible_entries.append(child)
	while visible_entries.size() >= max_entries:
		var oldest: SingleKillingBroadcast = visible_entries.pop_front()
		oldest.dismiss()
	var killer := _session.players.get(killer_id) as IslandPlayer
	var victim := _session.players.get(victim_id) as IslandPlayer
	var entry := KILL_BROADCAST_SCENE.instantiate() as SingleKillingBroadcast
	var killer_name := _session.player_display_name(killer_id) if killer != null else "边界"
	var victim_name := _session.player_display_name(victim_id) if victim != null else "Player %d" % victim_id
	var lifetime := _session.balance.kill_broadcast_lifetime_sec if _session.balance != null else 3.5
	broadcast_list.add_child(entry)
	entry.configure(killer_name, _team_color(killer), victim_name, _team_color(victim), lifetime)

func _show_coin_feedback(amount: int) -> void:
	var feedback := COIN_REWARD_FEEDBACK_SCENE.instantiate() as CoinRewardFeedback
	var layer_inverse := tap_feedback_layer.get_global_transform_with_canvas().affine_inverse()
	tap_feedback_layer.add_child(feedback)
	feedback.arrived.connect(_on_coin_feedback_arrived)
	var start_position := layer_inverse * broadcast_board.get_global_rect().get_center()
	var end_position := layer_inverse * gacha_button.get_global_rect().get_center()
	feedback.configure(amount, start_position, end_position)

func _on_coin_feedback_arrived() -> void:
	coin_sfx.play()
	if _gacha_pulse_tween != null:
		_gacha_pulse_tween.kill()
	gacha_button.pivot_offset = gacha_button.size * 0.5
	gacha_button.scale = Vector2.ONE
	_gacha_pulse_tween = create_tween()
	_gacha_pulse_tween.tween_property(gacha_button, "scale", Vector2.ONE * 1.28, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_gacha_pulse_tween.tween_property(gacha_button, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)

func _team_color(player: IslandPlayer) -> Color:
	if player == null:
		return NEUTRAL
	return TEAM_RED if player.team == 0 else TEAM_BLUE

func _shake_screen(strength: float) -> void:
	var canvas_layer := get_parent() as CanvasLayer
	if canvas_layer != null:
		if _shake_tween != null:
			_shake_tween.kill()
		canvas_layer.offset = Vector2(strength, -strength * 0.5)
		_shake_tween = create_tween()
		_shake_tween.tween_property(canvas_layer, "offset", Vector2(-strength, strength * 0.35), 0.045)
		_shake_tween.tween_property(canvas_layer, "offset", Vector2.ZERO, 0.07).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	var local_player := _local_player()
	if local_player == null or local_player.player_camera == null or not local_player.player_camera.enabled:
		return
	if _camera_shake_tween != null:
		_camera_shake_tween.kill()
	var camera_strength := strength * 1.4
	local_player.player_camera.offset = Vector2(-camera_strength, camera_strength * 0.45)
	_camera_shake_tween = create_tween()
	_camera_shake_tween.tween_property(local_player.player_camera, "offset", Vector2(camera_strength, -camera_strength * 0.35), 0.045)
	_camera_shake_tween.tween_property(local_player.player_camera, "offset", Vector2.ZERO, 0.08).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
