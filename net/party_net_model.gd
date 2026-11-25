# The party panel's model for real play: its own connection to the game server's party hub (opened from the
# title screen, apart from the match connection), the server's party state, the share code, and the leader's
# "go" that sends the whole party into a match (the lobby model listens to `go`).
class_name PartyNetModel
extends "res://net/party_model.gd"

const HostC := preload("res://net/mp_host.gd")
const TransportC := preload("res://net/transport.gd")
const RETRY_S := 6.0

signal go(key: String, ranked: bool)
var go_mode := "ffa"
signal notice(text: String)

var main
var url := ""
var my_name := "Player"
var online := false
var _t = null
var _state := {"members": [], "leader": true, "invites": [], "max": 8}
var _players: Array = []
var _code := ""
var _retry := 0.0
var _hello_sent := false
var _waiting := false


func _init(m, hub_url: String, pname: String) -> void:
	main = m
	url = hub_url
	my_name = pname
	enabled = true


func connect_hub() -> void:
	if _t != null:
		return
	_t = TransportC.new()
	if _t.connect_ws(url) != OK:
		_t = null
		_retry = RETRY_S
		return
	_t.packet.connect(_on_packet)
	_t.peer_disconnected.connect(func(_id: int) -> void: _dropped())
	_hello_sent = false
	_waiting = true


func close_hub() -> void:
	if _t != null:
		_t.close()
	_t = null
	_dropped()


func _dropped() -> void:
	_t = null
	if online or _waiting:
		online = false
		_waiting = false
		_state = {"members": [], "leader": true, "invites": [], "max": 8}
		_players = []
		_code = ""
		_retry = RETRY_S
		changed.emit()


## Called every frame by the PartyNet node.
func poll(dt: float) -> void:
	if _t == null:
		_retry -= dt
		if _retry <= 0.0:
			connect_hub()
		return
	_t.poll()
	if _t != null and _t.is_up() and not _hello_sent:
		_hello_sent = true
		_send({"op": "hello", "name": my_name})


func set_display_name(display_name: String) -> void:
	if display_name.is_empty() or my_name == display_name:
		return
	my_name = display_name
	if _hello_sent:
		_send({"op": "rename", "name": my_name})


func _send(d: Dictionary) -> void:
	if _t != null and _t.is_up():
		_t.send(1, HostC._pack(HostC.C_PARTY, d))


func _on_packet(_id: int, data: PackedByteArray) -> void:
	if data.size() < 1:
		return
	var d = bytes_to_var(data.slice(1))
	if not (d is Dictionary):
		return
	match int(data[0]):
		HostC.S_PARTY:
			if d.get("state") is Dictionary:
				me = int(d.get("me", 0))
				_state = d.state
				_players = d.get("players", []) if d.get("players") is Array else []
				_code = str(d.get("code", ""))
				online = true
				_waiting = false
				changed.emit()
		HostC.S_GO:
			go_mode = str(d.get("mode", "ffa"))
			go.emit(str(d.get("key", "")), bool(d.get("ranked", false)))
		HostC.S_NOTICE:
			notice.emit(str(d.get("text", "")))


func state() -> Dictionary:
	return _state


func online_players() -> Array:
	var out := _players.duplicate()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.name).to_lower() < str(b.name).to_lower())
	return out


func code() -> String:
	return _code


func is_online() -> bool:
	return online


func in_party() -> bool:
	return online and (_state.members as Array).size() >= 2


func is_leader() -> bool:
	return bool(_state.leader)


func join_code(c: String) -> void:
	_send({"op": "join_code", "code": c.strip_edges().to_upper()})


## The leader picks the match: the server tells every member to join it (S_GO), this PC included.
func request_go(ranked: bool, mode := "ffa") -> void:
	_send({"op": "go", "ranked": ranked, "mode": mode})


func act(action: String, uid: int = 0) -> String:
	if not online:
		return "Can't reach the server."
	match action:
		"invite", "accept", "decline", "kick":
			_send({"op": action, "uid": uid})
		"leave":
			_send({"op": "leave"})
	return ""
