class_name LobbyModel
extends RefCounted

signal lobby_updated(snapshot: Dictionary)
signal queue_state(active: bool, elapsed: float)
signal match_starting(snapshot: Dictionary)
signal match_result(result: Dictionary)

# The default model previews the lobby flow locally. A network model can override
# the commands and emit the same signals from authoritative server messages.
var player_name := "Guest"
var elo := 1000
var signed_in := false
var auto_advance := true
var queue_title := "RANKED QUEUE"
var queue_text := "Finding ranked players…"
var _generation := 0
var _queued_at := -1
var _lobby := {}
var _mode := "ffa"


func configure_identity(username: String, rating: int, authenticated: bool) -> void:
	player_name = username
	elo = rating
	signed_in = authenticated


func join_casual(mode := "ffa") -> void:
	leave()
	_mode = mode
	_join(false)


func join_ranked(mode := "ffa") -> void:
	if not signed_in:
		return
	leave()
	_mode = mode
	_queued_at = Time.get_ticks_msec()
	queue_state.emit(true, 0.0)
	if auto_advance:
		var generation := _generation
		await (Engine.get_main_loop() as SceneTree).create_timer(3.0).timeout
		if generation == _generation:
			complete_queue()


func complete_queue() -> void:
	if _queued_at < 0:
		return
	_queued_at = -1
	queue_state.emit(false, 0.0)
	_join(true)


func _join(ranked: bool) -> void:
	var second := {"name": "RidgeWalker", "elo": 1016, "ready": true}
	if not ranked:
		second.name = "Guest_0003" if player_name == "Guest_0002" else "Guest_0002"
	_lobby = {
		"ranked": ranked,
		"mode": _mode,
		"host": "server" if ranked else "%s's PC" % player_name,
		"map": "World",
		"bots": 0 if _mode == "teams" else 40,
		"speed": 1.0,
		"can_start": not ranked,
		"players": [{"name": player_name, "elo": elo, "ready": false}, second],
	}
	lobby_updated.emit(_lobby.duplicate(true))


func leave() -> void:
	_generation += 1
	if _queued_at >= 0:
		_queued_at = -1
		queue_state.emit(false, 0.0)
	_lobby.clear()
	lobby_updated.emit({})


func set_ready(ready: bool) -> void:
	if _lobby.is_empty():
		return
	_lobby.players[0].ready = ready
	lobby_updated.emit(_lobby.duplicate(true))
	if ready and _lobby.ranked:
		_start_match()


func start() -> void:
	if not _lobby.is_empty() and _lobby.can_start and _lobby.players[0].ready:
		_start_match()


func _start_match() -> void:
	var generation := _generation
	var snapshot := _lobby.duplicate(true)
	_lobby.clear()
	match_starting.emit(snapshot)
	if snapshot.ranked and auto_advance:
		await (Engine.get_main_loop() as SceneTree).create_timer(2.0).timeout
		if generation == _generation:
			finish_ranked(2, elo, elo + 8)


func finish_ranked(placement: int, before: int, after: int) -> void:
	match_result.emit({"placement": placement, "elo_before": before, "elo_after": after})
