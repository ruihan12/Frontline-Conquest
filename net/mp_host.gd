# Multiplayer host (multiplayer phases 1-2): runs the real sim inside this process (a dedicated server, or a
# player's PC) and speaks a small packet protocol to remote viewers (MPClient). Transport-agnostic: `send` is a
# Callable(peer: int, packet: PackedByteArray); feed incoming packets to on_message(peer, packet).
#
# Server to client: first byte = type, rest = payload.
#   S_HELLO    var dict {map_tab, map_i, nations:[[name,#color,ai,bot,human,prot,alive],...] (client id order), my, diff}
#   S_SNAPSHOT NetRep tiles packet (every owned tile)      S_DELTA  NetRep tiles packet (changes this tick)
#   S_NATIONS  NetRep nations packet                        S_LISTS  NetRep lists packet
#   S_STATE    var dict {tick, elapsed, state, deploy_t, peace, shields:{id:until}, tiles?}
#   S_EVENT    var dict {text, kind}                        S_END    var dict {winner, ranks:[[id,land,alive],...]}
# Client to server:
#   C_JOIN     var dict {name}                              C_INTENT var dict (validated here, applied as the sender's nation)
class_name MPHost
extends RefCounted

const NetRepC = preload("res://net/rep.gd")
const NetIntentsC = preload("res://net/intents.gd")

const S_HELLO := 1
const S_SNAPSHOT := 2
const S_DELTA := 3
const S_NATIONS := 4
const S_LISTS := 5
const S_STATE := 6
const S_EVENT := 7
const S_END := 8
const S_NATION_INFO := 9  # var [[id, name, #color, alive, human], ...] in the receiver's id space
const C_JOIN := 1
const C_INTENT := 2

const ALLOWED := ["spawn", "move_warship", "attack", "boat", "build", "nuke", "reinforce", "retreat", "ally_request", "ally_break", "donate", "donate_gold", "ally_reply", "ally_extend"]
const MAX_INTENT_BYTES := 512
const BURST := 60.0
const RATE := 30.0  # intents per second, refilled continuously

var g  # main.gd
var send: Callable
var peers := {}  # peer -> {nid, name, tokens, t}
var ended := false
var max_humans := 8
var slots: Array = []  # nation ids reserved for people (1 = PLAYER), in join order
var _sv_sent := -1
var _ntick := 0
var log_fn: Callable = Callable()


func _init(main, send_cb: Callable) -> void:
	g = main
	send = send_cb


## Starts a match: the map, `bots` AI players, and the spawn phase for the people who join.
func start_match(map_tab: int, map_i: int, bots: int, diff := 1) -> void:
	g.map_tab = map_tab
	g.map_i = map_i
	g.bot_players = bots
	g.diff_i = diff
	g.net_remote = false
	g.net_host = self
	g._start_game()
	g.net_rec = true
	g.net_dirty = PackedInt32Array()
	ended = false
	_sv_sent = -1
	peers.clear()
	# reserve a nation slot for every person that may join, so every viewer's nation list is complete from the start
	slots = [int(g.PLAYER)]
	for _i in range(1, max_humans):
		var sid: int = g._new_nation("(open)", Color(0.5, 0.5, 0.5), false)
		g.nations[sid].alive = false
		slots.append(sid)
	g._rebuild_kind_cache()


func human_count() -> int:
	return peers.size()


func any_placed() -> bool:
	for p in peers.values():
		if int(g.nations[p.nid].land) > 0:
			return true
	return false


## A person arrives. Returns their nation id or -1 (full / match over).
func join(peer: int, pname: String) -> int:
	if ended or peers.size() >= max_humans or peers.has(peer):
		return -1
	var nm := _clean_name(pname)
	var taken := {}
	for p in peers.values():
		taken[int(p.nid)] = true
	var nid := -1
	for sid in slots:
		if not taken.has(int(sid)):
			nid = int(sid)
			break
	if nid < 0:
		return -1
	g.nations[nid].name = nm
	g.nations[nid].alive = true
	if nid != int(g.PLAYER):
		g.nations[nid].color = Color.from_hsv(g.rng.randf(), g.rng.randf_range(0.6, 0.85), g.rng.randf_range(0.85, 0.97))
	g.nations[nid]["human"] = true
	g.nations[nid].ai = false
	g._rebuild_kind_cache()
	peers[peer] = {"nid": nid, "name": nm, "tokens": BURST, "t": Time.get_ticks_msec()}
	_send_hello(peer)
	_send_full(peer)
	_broadcast_nation_info(peer)
	return nid


## Tells every other viewer about the nation that `new_peer` now plays.
func _broadcast_nation_info(new_peer: int) -> void:
	var nid: int = peers[new_peer].nid
	var n: Dictionary = g.nations[nid]
	for peer in peers:
		if peer == new_peer:
			continue
		var my: int = peers[peer].nid
		send.call(peer, _pack(S_NATION_INFO, [[NetRepC.swap_id(nid, my), str(n.name), "#" + Color(n.color).to_html(false), bool(n.alive), true]]))


func leave(peer: int) -> void:
	peers.erase(peer)


func _clean_name(n: String) -> String:
	var out := ""
	for c in n.strip_edges():
		var code: int = c.unicode_at(0)
		if code >= 32 and code != 127:
			out += c
	out = out.substr(0, 16)
	return out if out != "" else "Player"


func _client_nations(my: int) -> Array:
	var out := []
	for k in range(1, g.nations.size()):
		var sid: int = NetRepC.swap_id(k, my)
		var n: Dictionary = g.nations[sid]
		out.append([str(n.name), "#" + Color(n.color).to_html(false), bool(n.get("ai", false)), bool(n.get("bot", false)), bool(n.get("human", false)), bool(n.get("prot", false)), bool(n.alive)])
	return out


func _send_hello(peer: int) -> void:
	var my: int = peers[peer].nid
	send.call(peer, _pack(S_HELLO, {"map_tab": g.map_tab, "map_i": g.map_i, "nations": _client_nations(my), "my": my, "diff": g.diff_i}))


func _send_full(peer: int) -> void:
	var my: int = peers[peer].nid
	send.call(peer, _pack_raw(S_SNAPSHOT, NetRepC.encode_snapshot(g, my)))
	send.call(peer, _pack_raw(S_NATIONS, NetRepC.encode_nations(g, my)))
	send.call(peer, _pack_raw(S_LISTS, NetRepC.encode_lists(g, my)))
	send.call(peer, _pack(S_STATE, _state_dict(my)))


func _state_dict(my: int) -> Dictionary:
	var sh := {}
	for id in g.shield_until:
		sh[NetRepC.swap_id(int(id), my)] = int(g.shield_until[id])
	return {"tick": g.sim_atk.tick, "elapsed": g.elapsed, "state": g.state, "deploy_t": g.deploy_t, "peace": g.peace, "shields": sh, "land_total": g.land_total, "fallout": g.fallout_count}


static func _pack(t: int, d) -> PackedByteArray:
	var b := PackedByteArray([t])
	b.append_array(var_to_bytes(d))
	return b


static func _pack_raw(t: int, payload: PackedByteArray) -> PackedByteArray:
	var b := PackedByteArray([t])
	b.append_array(payload)
	return b


## Called once per completed sim tick (main.gd). Sends each peer this tick's changes.
func on_tick() -> void:
	_ntick += 1
	var tiles: PackedInt32Array = g.net_dirty
	g.net_dirty = PackedInt32Array()
	if peers.is_empty():
		return
	var sv_changed: bool = g._sv != _sv_sent
	_sv_sent = g._sv
	for peer in peers:
		var my: int = peers[peer].nid
		if tiles.size() > 0:
			send.call(peer, _pack_raw(S_DELTA, NetRepC.encode_tiles(g, tiles, my)))
		if _ntick % 3 == 0:
			send.call(peer, _pack_raw(S_NATIONS, NetRepC.encode_nations(g, my)))
		var names := ["boats", "traders", "warships", "missiles"]
		if sv_changed:
			names.append("structs")
		send.call(peer, _pack_raw(S_LISTS, NetRepC.encode_lists(g, my, names)))
		if _ntick % 5 == 0:
			send.call(peer, _pack(S_STATE, _state_dict(my)))


## Win check for a hosted match (replaces the solo "you win / you lose" in main.gd).
func check_end() -> void:
	if ended or g.ticks_done % 10 != 0:
		return
	var winner := 0
	for id in range(1, g.nations.size()):
		if g.dominates(id):
			winner = id
			break
	var humans_alive := 0
	for p in peers.values():
		if g.nations[p.nid].alive and int(g.nations[p.nid].land) > 0:
			humans_alive += 1
	if winner == 0 and (humans_alive > 0 or g.state != "play" or peers.is_empty()):
		return
	ended = true
	g.state = "over"
	for peer in peers:
		var my: int = peers[peer].nid
		var ranks := []
		for id in range(1, g.nations.size()):
			ranks.append([NetRepC.swap_id(id, my), int(g.nations[id].land), bool(g.nations[id].alive)])
		send.call(peer, _pack(S_END, {"winner": NetRepC.swap_id(winner, my) if winner > 0 else 0, "ranks": ranks}))


## One packet from `peer`.
func on_message(peer: int, pkt: PackedByteArray) -> void:
	if pkt.size() < 1 or pkt.size() > 4096:
		return
	var t: int = pkt[0]
	var d = bytes_to_var(pkt.slice(1))  # no objects (allow_objects defaults to false in bytes_to_var)
	if t == C_JOIN:
		if d is Dictionary and not peers.has(peer):
			join(peer, str(d.get("name", "")))
		return
	if t != C_INTENT or not peers.has(peer) or not (d is Dictionary):
		return
	if pkt.size() > MAX_INTENT_BYTES:
		return
	var p: Dictionary = peers[peer]
	var now := Time.get_ticks_msec()
	p.tokens = minf(BURST, float(p.tokens) + float(now - int(p.t)) / 1000.0 * RATE)
	p.t = now
	if float(p.tokens) < 1.0:
		return  # rate limited: dropped
	p.tokens = float(p.tokens) - 1.0
	apply_intent(int(p.nid), d)


## Validates and applies one intent from the person who owns nation `nid`. Returns true when it was applied.
func apply_intent(nid: int, d: Dictionary) -> bool:
	if ended or nid <= 0 or nid >= g.nations.size() or not g.nations[nid].alive:
		return false
	var ty := str(d.get("type", ""))
	if not ALLOWED.has(ty):
		return false
	var it := {"type": ty}
	for k in ["tile", "target", "uid", "amount", "attack_id"]:
		if d.has(k):
			if not (d[k] is int):
				return false
			it[k] = int(d[k])
	for k in ["ratio", "troops"]:
		if d.has(k):
			if not (d[k] is float or d[k] is int):
				return false
			var f := float(d[k])
			if is_nan(f) or is_inf(f):
				return false
			it[k] = clampf(f, 0.0, 1e12 if k == "troops" else 1.0)
	if d.has("kind"):
		if not (d.kind is String) or not RWGameState.BUILD_ID.has(String(d.kind)):
			return false
		it["kind"] = String(d.kind)
	if d.has("accept"):
		it["accept"] = bool(d.accept)
	if it.has("tile") and (int(it.tile) < -1 or int(it.tile) >= g.W * g.H):
		return false
	if it.has("target") and (int(it.target) < 0 or int(it.target) >= g.nations.size()):
		return false
	if it.has("amount"):
		it["amount"] = clampi(int(it.amount), 1, 10)
	# phases: spawning only in the spawn phase; everything else only in play
	if ty == "spawn":
		if g.state != "pick":
			return false
	elif g.state != "play":
		return false
	if ty == "retreat":
		var ok := false
		for at in g.attacks:
			if int(at.get("aid", -2)) == int(it.get("attack_id", -1)) and int(at.a) == nid:
				ok = true
		if not ok:
			return false
	NetIntentsC.apply(g, nid, it)
	return true
