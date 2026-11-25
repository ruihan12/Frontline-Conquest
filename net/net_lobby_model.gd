# The lobby model for real play: the Casual and Ranked buttons connect to the game server (save.settings.server_url,
# default wss://frontline.henrymc.org/ws) and the match opens on this side as a remote viewer (net/mp_client.gd).
# Same signals as the preview model, so client/ui/lobby.gd needs no changes beyond the model it is given.
class_name NetLobbyModel
extends "res://net/lobby_model.gd"

const DEFAULT_URL := "wss://frontline.henrymc.org/ws"
const CONNECT_TIMEOUT := 12.0

var main
var token_getter := Callable()
var _node: Node
var _entered := false


func _init(m) -> void:
	main = m
	auto_advance = false
	queue_title = "CONNECTING"
	queue_text = "Connecting to the server…"


func server_url() -> String:
	return str(main.save.get("settings", {}).get("server_url", DEFAULT_URL))


func join_casual() -> void:
	_connect(false)


func join_ranked() -> void:
	if signed_in:
		_connect(true)


func _connect(ranked: bool) -> void:
	leave()
	var gen := _generation
	var token := str(main.save.get("settings", {}).get("session_token", ""))
	_node = main.net_join(server_url(), player_name, token)
	if _node == null:
		_fail("Could not start the connection.")
		return
	queue_state.emit(true, 0.0)
	_node.entered.connect(func() -> void:
		if gen != _generation:
			return
		_entered = true
		queue_state.emit(false, 0.0)
		match_starting.emit({"ranked": ranked, "online": true, "map": "World", "host": "server"}))
	_node.rejected.connect(func(reason: String) -> void:
		if gen != _generation:
			return
		_fail(_reason_text(reason)))
	_node.result.connect(func(r: Dictionary) -> void:
		match_result.emit(r)
		main.notify("%s: #%d  Elo %d → %d" % ["Ranked" if r.get("ranked", false) else "Result", int(r.placement), int(r.elo_before), int(r.elo_after)], "info"))
	await (Engine.get_main_loop() as SceneTree).create_timer(CONNECT_TIMEOUT).timeout
	if gen == _generation and not _entered and _node != null:
		_fail("The server did not answer. Try again in a moment.")


func _reason_text(reason: String) -> String:
	match reason:
		"account_required": return "This match needs an account. Log in from the Account screen."
		"invalid_session": return "Your session expired. Log in again."
		"already_joined": return "This account is already in the match."
	return "The server refused the connection."


func _fail(text: String) -> void:
	leave()
	main.notify(text, "bad")


func leave() -> void:
	_generation += 1
	if _node != null and not _entered:
		if is_instance_valid(_node):
			_node.queue_free()
	_node = null
	if _queued_at >= 0:
		_queued_at = -1
	queue_state.emit(false, 0.0)
	_lobby.clear()
	lobby_updated.emit({})
