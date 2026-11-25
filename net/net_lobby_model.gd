# The lobby model for real play: the Casual and Ranked buttons connect to the game server (save.settings.server_url,
# default wss://frontline.henrymc.org/ws) and the match opens on this side as a remote viewer (net/mp_client.gd).
# Same signals as the preview model, so client/ui/lobby.gd needs no changes beyond the model it is given.
class_name NetLobbyModel
extends "res://net/lobby_model.gd"

const DEFAULT_URL := "wss://frontline.henrymc.org/ws"
const CONNECT_TIMEOUT := 12.0

var main
var party = null
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


## The party hub (net/party_net_model.gd): its leader picks the match for everyone, and the server's go
## starts the join on every member's PC, this one included.
func bind_party(p) -> void:
	party = p
	p.go.connect(func(key: String, ranked: bool) -> void: _connect(ranked, key, p.go_mode))


## True when the party took over the join (a follower may not pick; a leader asks the server to send all in).
func configure_identity(username: String, rating: int, authenticated: bool) -> void:
	super.configure_identity(username, rating, authenticated)
	if party != null:
		party.set_display_name(username)


func _party_gate(ranked: bool, mode: String) -> bool:
	if party == null or not party.in_party():
		return false
	if not party.is_leader():
		main.notify("Your party leader picks the match.", "bad")
		return true
	party.request_go(ranked, mode)
	return true


func join_casual(mode := "ffa") -> void:
	if not _party_gate(false, mode):
		_connect(false, "", mode)


func join_ranked(mode := "ffa") -> void:
	if signed_in and not _party_gate(true, mode):
		_connect(true, "", mode)


func _connect(ranked: bool, party_key := "", mode := "ffa") -> void:
	leave()
	_entered = false
	var gen := _generation
	var token := str(main.save.get("settings", {}).get("session_token", ""))
	_node = main.net_join(server_url(), player_name, token, false, party_key, mode)
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
		"party_too_big": return "There are not enough seats for your whole party. Try again next round."
		"resume_expired": return "The reconnect window expired. Open the lobby to join another match."
		"match_full": return "The match is full."
		"mode_unavailable": return "The current match uses a different mode. Try again next round."
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


## Casual: this PC runs the match (desktop only); friends join by address.
func host_local() -> void:
	leave()
	_node = main.net_host_local()
	if _node == null:
		_fail("Could not host a match on this PC.")
		return
	_entered = true
	var ips := []
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			ips.append(a)
	main.notify("Hosting on port 8070. Friends join with %s:8070" % (ips[0] if not ips.is_empty() else "your IP"), "info")
	match_starting.emit({"ranked": false, "online": true, "map": "World", "host": "this PC"})


func join_address(addr: String) -> void:
	leave()
	var gen := _generation
	var a := addr.strip_edges()
	if a == "":
		return
	if not ":" in a:
		a += ":8070"
	_node = main.net_join(a, player_name, "", true)
	if _node == null:
		_fail("Could not start the connection.")
		return
	queue_state.emit(true, 0.0)
	_node.entered.connect(func() -> void:
		if gen != _generation:
			return
		_entered = true
		queue_state.emit(false, 0.0)
		match_starting.emit({"ranked": false, "online": true, "map": "World", "host": a}))
	_node.rejected.connect(func(reason: String) -> void:
		if gen == _generation: _fail(_reason_text(reason)))
	await (Engine.get_main_loop() as SceneTree).create_timer(CONNECT_TIMEOUT).timeout
	if gen == _generation and not _entered and _node != null:
		_fail("Nobody answered at %s." % a)
