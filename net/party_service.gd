# The party hub on the game server: players connect from the title screen (before any match), see who else is
# connected, invite them or share a code, and the leader sends the whole party into a match together.
# Rules live in net/party.gd (upstream Party.luau). Messages (net/mp_host.gd C_PARTY / S_PARTY / S_GO):
#   C_PARTY var {op, ...}: hello {name} · invite {uid} · accept {uid} · decline {uid} · kick {uid} · leave
#                          · join_code {code} · go {ranked}
#   S_PARTY var {me, code, state: Party.state, players: [{uid, name}]}      S_GO var {key, ranked}
class_name PartyService
extends RefCounted

const PartyCore := preload("res://net/party.gd")
const MAX_HUB := 200
const LISTED := 64
const CODE_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const CODE_LEN := 6
const BURST := 12.0
const RATE := 4.0

var party: PartyCore
var send: Callable           # (peer: int, type: int, payload) -> void
var rng := RandomNumberGenerator.new()
var peers := {}              # peer -> {name, code, tokens, t}
var _codes := {}             # code -> peer


func _init(send_fn: Callable) -> void:
	send = send_fn
	rng.randomize()
	party = PartyCore.new()
	party.changed.connect(func(ids: Array) -> void:
		for id: int in ids:
			if peers.has(id):
				_push(id))


func has_peer(peer: int) -> bool:
	return peers.has(peer)


## True while a party with this key exists (a match join may name it to keep the party on one team).
func key_alive(key: String) -> bool:
	if key == "":
		return false
	for peer: int in peers:
		if party.key_of(peer) == key:
			return true
	return false


func on_message(peer: int, d: Variant) -> void:
	if not (d is Dictionary):
		return
	var op := str(d.get("op", ""))
	if op == "hello":
		_hello(peer, str(d.get("name", "")))
		return
	if not peers.has(peer):
		return
	var p: Dictionary = peers[peer]
	var now := Time.get_ticks_msec()
	p.tokens = minf(BURST, float(p.tokens) + float(now - int(p.t)) / 1000.0 * RATE)
	p.t = now
	if float(p.tokens) < 1.0:
		return
	p.tokens = float(p.tokens) - 1.0
	var uid := int(d.get("uid", 0)) if d.get("uid", 0) is int else 0
	match op:
		"invite":
			var r := party.invite(peer, uid)
			if not r.ok and r.reason != "":
				_notice(peer, r.reason)
		"accept":
			var r := party.accept(peer, uid)
			if not r.ok:
				_notice(peer, r.reason)
		"decline": party.decline(peer, uid)
		"kick": party.kick(peer, uid)
		"leave": party.leave(peer)
		"join_code": _join_code(peer, str(d.get("code", "")))
		"go": _go(peer, bool(d.get("ranked", false)), "teams" if d.get("mode") == "teams" else "ffa")


func peer_left(peer: int) -> void:
	if not peers.has(peer):
		return
	_codes.erase(peers[peer].code)
	peers.erase(peer)  # (before the party notices: nothing is pushed to the closed connection)
	party.removed(peer)
	_push_all()


func _hello(peer: int, pname: String) -> void:
	if peers.has(peer) or peers.size() >= MAX_HUB:
		return
	var nm := ""
	for c in pname.strip_edges():
		if c.unicode_at(0) >= 32 and c.unicode_at(0) != 127:
			nm += c
	nm = nm.substr(0, 16)
	if nm == "":
		nm = "Player"
	var code := ""
	while code == "" or _codes.has(code):
		code = ""
		for i in CODE_LEN:
			code += CODE_CHARS[rng.randi() % CODE_CHARS.length()]
	peers[peer] = {"name": nm, "code": code, "tokens": BURST, "t": Time.get_ticks_msec()}
	_codes[code] = peer
	party.names[peer] = nm
	_push_all()


## Joining by code: the code's owner's party takes you in (made if they had none). The code is the consent.
func _join_code(peer: int, code: String) -> void:
	var owner: int = _codes.get(code.strip_edges().to_upper(), 0)
	if owner == 0 or owner == peer:
		_notice(peer, "No party found for that code.")
		return
	if party.key_of(peer) != "" and party.key_of(peer) == party.key_of(owner):
		_notice(peer, "You are already in that party.")
		return
	# (the owner's own invite, accepted at once; a party of 8 refuses)
	var box: Dictionary = party._invites.get(peer, {})
	box[owner] = party.now()
	party._invites[peer] = box
	var r := party.accept(peer, owner)
	if not r.ok:
		_notice(peer, r.reason)


func _go(peer: int, ranked: bool, mode: String) -> void:
	var key := party.key_of(peer)
	if key == "" or not party.is_leader(peer):
		return
	for m: int in party.members(peer):
		if peers.has(m):
			send.call(m, 14, {"key": key, "ranked": ranked, "mode": mode})


func _notice(peer: int, text: String) -> void:
	send.call(peer, 15, {"text": text})


func _push_all() -> void:
	for peer: int in peers:
		_push(peer)


func _push(peer: int) -> void:
	var mine := party.key_of(peer)
	var players: Array = []
	for o: int in peers:
		if o != peer and (mine == "" or party.key_of(o) != mine):
			players.append({"uid": o, "name": peers[o].name})
			if players.size() >= LISTED:
				break
	send.call(peer, 13, {"me": peer, "code": peers[peer].code, "state": party.state(peer), "players": players})
