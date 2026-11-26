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
const AdminConsoleC = preload("res://net/admin_console.gd")

const S_HELLO := 1
const S_SNAPSHOT := 2
const S_DELTA := 3
const S_NATIONS := 4
const S_LISTS := 5
const S_STATE := 6
const S_EVENT := 7
const S_END := 8
const S_TEAMS := 12  # var {names, config, me_team, teams: {id: team}} (ids in the receiver's space), once the teams are made
const S_RESULT := 11  # var {placement, elo_before, elo_after, ranked}: this person's result, after the account service rated the match
const S_REJECT := 10  # var {reason}: the join was refused (full, ranked match needs an account, bad session)
const S_NATION_INFO := 9  # var [[id, name, #color, alive, human], ...] in the receiver's id space
const TeamsC = preload("res://net/teams.gd")
const C_JOIN := 1
const C_PARTY := 3   # var {op, ...}: the party hub (net/party_service.gd)
const S_PARTY := 13  # var {me, code, state, players}
const S_GO := 14     # var {key, ranked}: the party leader chose a match, everyone joins it
const S_NOTICE := 15 # var {text}
const C_INTENT := 2
const C_VOTE := 4    # var {vote: bool}: wants the waiting match to start now
const S_LOBBY := 16  # var {on, left, players, max, votes, need, voted, names, team, total}: the waiting room
# Waiting room (upstream MatchServer: lobby, then a shared spawn phase): LOBBY_SECS from the first player in; two thirds
# of the waiting players voting (at least VOTE_MIN of them, or one after VOTE_SOLO_AFTER alone) starts it in VOTE_START_SECS;
# joins close JOIN_CLOSE_SECS before the start; then everyone picks a start within SPAWN_SECS (nobody who didn't gets one
# chosen for them).
const LOBBY_SECS := 60.0
const VOTE_SHARE := 2.0 / 3.0
const VOTE_START_SECS := 10.0
const VOTE_MIN := 2
const VOTE_SOLO_AFTER := 30.0
const JOIN_CLOSE_SECS := 6.0
const SPAWN_SECS := 20.0

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
var join_gate: Callable = Callable()  # (peer, dict) -> void; when set, it decides (maybe later) and calls join()/reject()
var on_end: Callable = Callable()     # (result dict) once, when the match ends
var ranked := false
# team games (ranked teams, casual teams): players only, no bot players, tribes on no team
var team_game := false
var lobby_enabled := true    # a dedicated server waits for people first; a PC that hosts for friends does not
var lobby := false           # true while the waiting room is open
var lobby_secs := LOBBY_SECS  # FRONTLINE_LOBBY_SECS
var lobby_left := LOBBY_SECS
var _votes := {}             # peer -> true
var _vote_locked := false
var _alone := 0.0
var _lobby_sent := 0.0
var team_expected := 0       # the roster size; the teams are made when this many have joined (or after TEAM_WAIT_SECS)
var teams_ready := false
var team_config := ""        # Duos / Trios / Quads, picked at random when the teams are made
var pending_party := {}     # peer -> party key named in its join (checked by party_valid)
var party_valid := Callable()
var party_size := Callable()
var party_joined := Callable()
var party_left := Callable()
var _reservations := {}
const PARTY_SEAT_SECONDS := 15_000
var team_groups := {}        # peer -> party key (players who queued together stay on one team)
var _team_wait := 0.0
const TEAM_WAIT_SECS := 60.0
var host_is_player := false  # a player's PC: nation 1 is played locally, remote people take the other slots
const RESUME_GRACE_MS := 30_000
var _crypto := Crypto.new()
var started_ms := 0
var died_tick := {}  # human nid -> tick it was eliminated
var left_early := {}  # human nid -> true when the person left a running match


func _init(main, send_cb: Callable) -> void:
	g = main
	send = send_cb


## Starts a match: the map, `bots` AI players, and the spawn phase for the people who join.
func start_match(map_tab: int, map_i: int, bots: int, diff := 1) -> void:
	g.map_tab = map_tab
	g.map_i = map_i
	g.bot_players = 0 if team_game else bots  # no bot players in a team game (tribes still exist)
	g.team_mode = team_game
	g.team_names = []
	g.winner_team = 0
	teams_ready = false
	_team_wait = 0.0
	g.diff_i = diff
	g.net_remote = false
	g.net_host = self
	g._start_game()
	g.net_rec = true
	g.net_dirty = PackedInt32Array()
	ended = false
	_sv_sent = -1
	if party_left.is_valid():
		for peer: int in peers:
			party_left.call(peer)
	peers.clear()
	_reservations.clear()
	team_groups.clear()
	died_tick.clear(); left_early.clear(); departed.clear()
	started_ms = Time.get_ticks_msec()
	lobby = uses_lobby()
	lobby_left = lobby_secs
	_votes.clear()
	_vote_locked = false
	_alone = 0.0
	# reserve a nation slot for every person that may join, so every viewer's nation list is complete from the start
	slots = [int(g.PLAYER)]
	for _i in range(1, max_humans):
		var sid: int = g._new_nation("(open)", Color(0.5, 0.5, 0.5), false)
		g.nations[sid].alive = false
		slots.append(sid)
	g._rebuild_kind_cache()


func uses_lobby() -> bool:
	return lobby_enabled and not host_is_player


func human_count() -> int:
	return peers.size()


func any_placed() -> bool:
	for p in peers.values():
		if int(g.nations[p.nid].land) > 0:
			return true
	return false


func _reserved_seats(except_key := "") -> int:
	var total := 0
	var now := Time.get_ticks_msec()
	for key in _reservations.keys():
		var r: Dictionary = _reservations[key]
		if now >= int(r.until) or int(r.remaining) <= 0:
			_reservations.erase(key)
		elif key != except_key:
			total += int(r.remaining)
	return total


func _admit_party(key: String) -> bool:
	var limit := mini(max_humans, team_expected) if team_game and team_expected > 0 else max_humans
	if host_is_player:
		limit -= 1
	var available := limit - peers.size() - _reserved_seats(key)
	if _reservations.has(key):
		return available > 0
	var size := int(party_size.call(key)) if not key.is_empty() and party_size.is_valid() else 1
	if maxi(size, 1) > available:
		return false
	if size > 1:
		_reservations[key] = {"remaining": size, "until": Time.get_ticks_msec() + PARTY_SEAT_SECONDS}
	return true


## A person arrives. Returns their nation id or -1 (full / match over).
func join(peer: int, pname: String, account = 0) -> int:
	if ended or peers.size() >= max_humans or peers.has(peer) or (team_game and teams_ready):
		return -1
	if uses_lobby() and (not lobby or (lobby_left < JOIN_CLOSE_SECS and not peers.is_empty())):
		reject(peer, "match_started")
		return -2
	var key := str(pending_party.get(peer, ""))
	if not _admit_party(key):
		reject(peer, "party_too_big" if not key.is_empty() else "match_full")
		return -2
	var nm := _clean_name(pname)
	var taken := {}
	for p in peers.values():
		taken[int(p.nid)] = true
	var nid := -1
	for sid in slots:
		if host_is_player and int(sid) == int(g.PLAYER):
			continue
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
	if not key.is_empty():
		team_groups[peer] = key
		if _reservations.has(key):
			_reservations[key].remaining -= 1
		if party_joined.is_valid():
			party_joined.call(peer, key)
	peers[peer] = {"nid": nid, "name": nm, "account": account, "resume": _crypto.generate_random_bytes(32).hex_encode(), "tokens": BURST, "t": Time.get_ticks_msec()}
	_send_hello(peer)
	_send_full(peer)
	_broadcast_nation_info(peer)
	if team_game and not lobby and peers.size() + (1 if host_is_player else 0) >= team_expected and _reserved_seats() == 0:
		make_teams()
	_send_lobby_all()
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


## Events are small, server-originated and capped independently per recipient.
func emit_event(data: Dictionary, recipients := []) -> void:
	var now := Time.get_ticks_msec()
	for peer in peers:
		var player: Dictionary = peers[peer]
		var my := int(player.nid)
		if not recipients.is_empty() and not recipients.has(my):
			continue
		var available := minf(10.0, float(player.get("event_budget", 10)) + (now - int(player.get("event_ms", now))) * 0.008)
		player.event_ms = now
		player.event_budget = available
		if available < 1.0:
			continue
		var event := data.duplicate()
		for field in ["actor", "target"]:
			if event.has(field):
				event[field] = NetRepC.swap_id(int(event[field]), my)
		var packet := _pack(S_EVENT, event)
		if packet.size() <= 384:
			player.event_budget -= 1.0
			send.call(peer, packet)


func reject(peer: int, reason: String) -> void:
	send.call(peer, _pack(S_REJECT, {"reason": reason}))


func transport_lost(peer: int, now := -1) -> void:
	if not peers.has(peer) or ended or g.state != "play" or lobby:
		leave(peer)
		return
	if now < 0:
		now = Time.get_ticks_msec()
	peers[peer]["disconnected_until"] = now + RESUME_GRACE_MS


func expire_disconnected(now: int) -> void:
	for peer in peers.keys():
		if peers[peer].has("disconnected_until") and now >= int(peers[peer].disconnected_until):
			leave(peer)


func _resume(peer: int, token: String) -> bool:
	if token.length() != 64 or peers.has(peer) or ended:
		return false
	var now := Time.get_ticks_msec()
	for former in peers.keys():
		var seat: Dictionary = peers[former]
		if not seat.has("disconnected_until") or now >= int(seat.disconnected_until):
			continue
		if not _crypto.constant_time_compare(token.to_utf8_buffer(), str(seat.resume).to_utf8_buffer()):
			continue
		seat.erase("disconnected_until")
		seat.resume = _crypto.generate_random_bytes(32).hex_encode()
		peers.erase(former)
		peers[peer] = seat
		var group := str(team_groups.get(former, ""))
		team_groups.erase(former)
		pending_party.erase(former)
		if not group.is_empty():
			team_groups[peer] = group
			if party_joined.is_valid():
				party_joined.call(peer, group)
			if party_left.is_valid():
				party_left.call(former)
		_send_hello(peer)
		_send_full(peer)
		if teams_ready:
			_send_teams(peer)
		return true
	return false


func leave(peer: int) -> void:
	_votes.erase(peer)
	pending_party.erase(peer)
	team_groups.erase(peer)
	if party_left.is_valid():
		party_left.call(peer)
	if peers.has(peer):
		if not ended:
			if g.state == "play" or (team_game and teams_ready):
				left_early[int(peers[peer].nid)] = true
				g.nations[int(peers[peer].nid)]["left"] = true  # a team game: a leaver is no longer a teammate
			if ranked:
				departed.append(peers[peer])
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
	send.call(peer, _pack(S_HELLO, {"map_tab": g.map_tab, "map_i": g.map_i, "nations": _client_nations(my), "my": my, "resume": peers[peer].resume, "diff": g.diff_i, "team_game": team_game, "team_expected": team_expected}))


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
	# diplomacy, in this viewer's id space: alliance keys are min*4096+max, request keys from*1024+to
	var al := {}
	for k in g.allies:
		var a := swap_pair(int(k) / 4096, int(k) % 4096, my)
		al[a] = int(g.allies[k])
	var rq := {}
	for k in g.ally_requests:
		rq[NetRepC.swap_id(int(k) / 1024, my) * 1024 + NetRepC.swap_id(int(k) % 1024, my)] = int(g.ally_requests[k])
	var tr := {}
	for id in g.traitor:
		tr[NetRepC.swap_id(int(id), my)] = int(g.traitor[id])
	return {"tick": g.sim_atk.tick, "elapsed": g.elapsed, "state": g.state, "deploy_t": g.deploy_t, "peace": g.peace, "shields": sh, "land_total": g.land_total, "fallout": g.fallout_count, "allies": al, "reqs": rq, "traitor": tr}


static func swap_pair(a: int, b: int, my: int) -> int:
	var x: int = NetRepC.swap_id(a, my)
	var y: int = NetRepC.swap_id(b, my)
	return mini(x, y) * 4096 + maxi(x, y)


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
	for p in peers.values():
		var pn: int = p.nid
		if not died_tick.has(pn) and (not g.nations[pn].alive or (g.state == "play" and int(g.nations[pn].land) <= 0)):
			died_tick[pn] = g.ticks_done
	var sv_changed: bool = g._sv != _sv_sent
	_sv_sent = g._sv
	for peer in peers:
		if peers[peer].has("disconnected_until"):
			continue
		var my: int = peers[peer].nid
		if tiles.size() > 0:
			send.call(peer, _pack_raw(S_DELTA, NetRepC.encode_tiles(g, tiles, my)))
		if _ntick % 3 == 0:
			send.call(peer, _pack_raw(S_NATIONS, NetRepC.encode_nations(g, my)))
		var names := ["boats", "traders", "warships", "missiles", "planes"]
		if _ntick % 5 == 0:
			names.append("attacks")  # 400+ light entries (~14 KB): twice a second is enough for the attack rows
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
	var winner_team := 0
	if team_game:
		# the team's land together reaches 80% of the contestable land (upstream Sim._check_victory); players only
		if teams_ready:
			var sums := team_land()
			for t in range(1, sums.size()):
				if float(sums[t]) >= g.win_threshold_tiles():
					winner_team = t
			if winner_team == 0 and g.state == "play":
				# only one team still has a living human: it wins
				var live := {}
				for p in peers.values():
					if g.nations[p.nid].alive and int(g.nations[p.nid].land) > 0 and not g.nations[p.nid].get("left", false):
						live[int(g.nations[p.nid].get("team", 0))] = true
				if host_is_player and g.nations[g.PLAYER].alive and int(g.nations[g.PLAYER].land) > 0:
					live[int(g.nations[g.PLAYER].get("team", 0))] = true
				if live.size() == 1 and g.ticks_done > 100:
					winner_team = int(live.keys()[0])
			if winner_team != 0:
				var bt := -1
				for id in range(1, g.nations.size()):
					if int(g.nations[id].get("team", 0)) == winner_team and g.nations[id].alive and int(g.nations[id].land) > bt:
						bt = int(g.nations[id].land)
						winner = id
	else:
		for id in range(1, g.nations.size()):
			if g.dominates(id):
				winner = id
				break
	var humans_alive := 0
	if host_is_player and g.nations[g.PLAYER].alive and int(g.nations[g.PLAYER].land) > 0:
		humans_alive += 1
	for p in peers.values():
		if g.nations[p.nid].alive and int(g.nations[p.nid].land) > 0:
			humans_alive += 1
	if winner == 0 and (humans_alive > 0 or g.state != "play" or (peers.is_empty() and not host_is_player)):
		return
	ended = true
	g.state = "over"
	g.winner_team = winner_team
	if on_end.is_valid():
		on_end.call(placements(winner))
	if host_is_player:
		g._game_over(winner == int(g.PLAYER) or (winner_team != 0 and int(g.nations[g.PLAYER].get("team", 0)) == winner_team))
	for peer in peers:
		var my: int = peers[peer].nid
		var ranks := []
		for id in range(1, g.nations.size()):
			ranks.append([NetRepC.swap_id(id, my), int(g.nations[id].land), bool(g.nations[id].alive)])
		send.call(peer, _pack(S_END, {"winner": NetRepC.swap_id(winner, my) if winner > 0 else 0, "ranks": ranks, "winner_team": winner_team, "me_team": int(g.nations[my].get("team", 0))}))


## One packet from `peer`.
func on_message(peer: int, pkt: PackedByteArray) -> void:
	if pkt.size() < 1 or pkt.size() > 4096:
		return
	var t: int = pkt[0]
	var d = bytes_to_var(pkt.slice(1))  # no objects (allow_objects defaults to false in bytes_to_var)
	if t == C_JOIN:
		if d is Dictionary and not peers.has(peer):
			var resume := str(d.get("resume", ""))
			if not resume.is_empty():
				if not _resume(peer, resume):
					reject(peer, "resume_expired")
				return
			var pk := str(d.get("party", ""))
			if pk != "" and party_valid.is_valid() and party_valid.call(pk):
				pending_party[peer] = pk
			if join_gate.is_valid():
				join_gate.call(peer, d)
			else:
				join(peer, str(d.get("name", "")))
		return
	if t == C_VOTE:
		if lobby and peers.has(peer) and d is Dictionary:
			if bool(d.get("vote", false)):
				_votes[peer] = true
			else:
				_votes.erase(peer)
			_check_votes()
			_send_lobby_all()
		return
	if t != C_INTENT or not peers.has(peer) or peers[peer].has("disconnected_until") or not (d is Dictionary):
		return
	if pkt.size() > (1024 if str(d.get("type", "")) == "console" else MAX_INTENT_BYTES):
		return
	var p: Dictionary = peers[peer]
	var now := Time.get_ticks_msec()
	p.tokens = minf(BURST, float(p.tokens) + float(now - int(p.t)) / 1000.0 * RATE)
	p.t = now
	if float(p.tokens) < 1.0:
		return  # rate limited: dropped
	p.tokens = float(p.tokens) - 1.0
	if str(d.get("type", "")) == "console":
		_admin_console(p, d)
		return
	apply_intent(int(p.nid), d)


## The owner's console online: a signed token (net/admin_console.gd) for this very account, then a short list of
## commands on the sender's own nation or a named nation. Nothing here evaluates expressions.
func _admin_console(p: Dictionary, d: Dictionary) -> void:
	var nid := int(p.nid)
	if ended or int(p.get("account", 0)) <= 0 or nid <= 0 or nid >= g.nations.size() or g.state != "play":
		return
	var who := AdminConsoleC.check(str(d.get("payload", "")), str(d.get("sig", "")))
	if who == "" or who != str(p.name).to_lower():
		return
	var words := str(d.get("cmd", "")).strip_edges().split(" ", false)
	if words.is_empty():
		return
	var head := words[0].to_lower()
	var n = g.nations[nid]
	if head in ["gold", "troops"] and words.size() >= 2 and words[1].lstrip("+-").is_valid_float():
		var v := clampf(float(words[1]), -1e15, 1e15)
		n[head] = maxf(0.0, (float(n[head]) + v) if words[1].begins_with("+") else v)
	elif head == "god":
		n.gold = maxf(float(n.gold), 999e6)
		n.troops = g.troop_cap(nid)
	elif head == "claim":
		var rad := int(words[1]) if words.size() >= 2 and words[1].is_valid_int() else 15
		var t := int(d.get("tile", -1)) if d.get("tile") is int else -1
		if t < 0 or t >= g.W * g.H:
			return
		g._claim_blob(nid, t, clampi(rad, 1, 120))
	elif head == "nation" and words.size() >= 4 and words[2].to_lower() in ["gold", "troops"] and words[3].lstrip("+-").is_valid_float():
		var q := words[1].to_lower()
		var tid := int(q) if q.is_valid_int() else -1
		if tid < 0:
			for id in range(1, g.nations.size()):
				if str(g.nations[id].name).to_lower().find(q) >= 0:
					tid = id
					break
		if tid > 0 and tid < g.nations.size():
			g.nations[tid][words[2].to_lower()] = clampf(float(words[3]), 0.0, 1e15)


## Validates and applies one intent from the person who owns nation `nid`. Returns true when it was applied.
func apply_intent(nid: int, d: Dictionary) -> bool:
	if ended or nid <= 0 or nid >= g.nations.size() or not g.nations[nid].alive:
		return false
	var ty := str(d.get("type", ""))
	if not ALLOWED.has(ty):
		return false
	if team_game and not teams_ready:
		return false  # nothing is allowed until the teams are made
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
	if it.has("target"):
		it["target"] = NetRepC.swap_id(int(it.target), nid)  # the viewer's id space to the host's
	if it.has("amount"):
		it["amount"] = clampi(int(it.amount), 1, 10)
	# phases: spawning only in the spawn phase; everything else only in play
	if ty == "spawn":
		if g.state != "pick" or lobby:
			return false
	elif g.state != "play":
		return false
	if ty in ["build", "nuke"] and g.teammate_building_in_blast(
			nid, int(RWGameState.BUILD_ID.get(it.get("kind", ""), -1)), int(it.get("tile", -1))):
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


## Final order of the people in this match: survivors by land (the winner first), then the eliminated, latest out first.
## [{nid, name, account, placement, tile_share, survival_secs, left_early}]
func placements(winner: int) -> Array:
	var list := []
	var total := maxf(1.0, float(g.land_total))
	for peer in peers:
		var p: Dictionary = peers[peer]
		_add_placement(list, int(p.nid), str(p.name), p.get("account", 0), total)
	for e in departed:
		_add_placement(list, int(e.nid), str(e.name), e.get("account", 0), total)
	if team_game:
		return _team_placements(list, winner)
	list.sort_custom(func(a, b) -> bool:
		if (a.nid == winner) != (b.nid == winner): return a.nid == winner
		if a.alive != b.alive: return a.alive
		if a.alive: return a.land > b.land
		return a.died > b.died)
	for i in list.size():
		list[i].placement = i + 1
	return list


## Team games: every member shares the team's place. The winning team is first; the others by their land together
## while any member lives, else by when their last member fell (later is better).
func _team_placements(list: Array, winner: int) -> Array:
	var tl := {}
	for e in list:
		var t: int = int(g.nations[e.nid].get("team", 0))
		e["team"] = t
		if not tl.has(t):
			tl[t] = {"team": t, "land": 0, "alive": false, "died": 0}
		var rec: Dictionary = tl[t]
		rec.land += int(e.land)
		rec.alive = rec.alive or e.alive
		rec.died = maxi(int(rec.died), int(e.died))
	var order: Array = tl.values()
	var wt: int = int(g.winner_team)
	order.sort_custom(func(a, b) -> bool:
		if (a.team == wt) != (b.team == wt): return a.team == wt
		if a.alive != b.alive: return a.alive
		if a.alive: return a.land > b.land
		return a.died > b.died)
	var place := {}
	for i in order.size():
		place[order[i].team] = i + 1
	for e in list:
		e.placement = int(place[e.team])
		e["team_size"] = 0
	var sizes := {}
	for e in list:
		sizes[e.team] = int(sizes.get(e.team, 0)) + 1
	for e in list:
		e.team_size = int(sizes[e.team])
	list.sort_custom(func(a, b) -> bool: return a.placement < b.placement)
	return list


var departed: Array = []  # people who left (kept for the result)


func _add_placement(list: Array, nid: int, pname: String, account, total: float) -> void:
	var n: Dictionary = g.nations[nid]
	list.append({"nid": nid, "name": pname, "account": account, "alive": bool(n.alive) and int(n.land) > 0, "land": int(n.land),
		"died": int(died_tick.get(nid, g.ticks_done)), "tile_share": float(n.land) / total,
		"survival_secs": int(float(died_tick.get(nid, g.ticks_done)) / 10.0), "left_early": left_early.has(nid), "placement": 0})


# ---- team games ----

## Called every frame by the node: waits for the roster, then makes the teams anyway after TEAM_WAIT_SECS.
func frame(dt: float) -> void:
	expire_disconnected(Time.get_ticks_msec())
	if lobby and not ended:
		_lobby_frame(dt)
		return
	if team_game and not teams_ready and not ended:
		_team_wait += dt
		if _team_wait >= TEAM_WAIT_SECS and peers.size() + (1 if host_is_player else 0) >= 2:
			make_teams()


## Teams are made once, from whoever is in: a random team size (Duos / Trios / Quads), teams filled one by one,
## a party kept together (upstream Core/Teams); each player gets the team's colour in a shade of their own.
func make_teams() -> void:
	if teams_ready or not team_game:
		return
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	team_config = TeamsC.random_config(rng)
	var players := []
	if host_is_player:
		players.append({"id": int(g.PLAYER), "group": ""})
	for peer in peers:
		players.append({"id": int(peers[peer].nid), "group": str(team_groups.get(peer, ""))})
	g.team_names = TeamsC.resolve(team_config, players.size())
	var out: Dictionary = TeamsC.assign(players, g.team_names.size(), true, rng)
	var counts := {}
	for p in players:
		var t: int = out[p.id]
		var idx: int = int(counts.get(t, 0))
		counts[t] = idx + 1
		g.nations[p.id]["team"] = t
		g.nations[p.id].color = TeamsC.color(str(g.team_names[t - 1]), t, idx)
	teams_ready = true
	g._rebuild_kind_cache()
	for peer in peers:
		_send_teams(peer)
		for q in peers:
			var my: int = peers[peer].nid
			var nq: Dictionary = g.nations[peers[q].nid]
			send.call(peer, _pack(S_NATION_INFO, [[NetRepC.swap_id(int(peers[q].nid), my), str(nq.name), "#" + Color(nq.color).to_html(false), bool(nq.alive), true]]))


func _send_teams(peer: int) -> void:
	var my: int = peers[peer].nid
	var teams := {}
	for id in range(1, g.nations.size()):
		var t: int = int(g.nations[id].get("team", 0))
		if t != 0:
			teams[NetRepC.swap_id(id, my)] = t
	send.call(peer, _pack(S_TEAMS, {"names": g.team_names, "config": team_config, "me_team": int(g.nations[my].get("team", 0)), "teams": teams}))


## Land per team (alive members): index 1..n.
func team_land() -> Array:
	var sums := []
	sums.resize(g.team_names.size() + 1)
	sums.fill(0)
	for id in range(1, g.nations.size()):
		var t: int = int(g.nations[id].get("team", 0))
		if t != 0 and g.nations[id].alive:
			sums[t] += int(g.nations[id].land)
	return sums


# ---------------- waiting room ----------------

func _vote_counts() -> Array:
	var players := 0
	var votes := 0
	for peer in peers:
		if peers[peer].has("disconnected_until"):
			continue
		players += 1
		if _votes.has(peer):
			votes += 1
	var need := maxi(1, ceili(float(players) * VOTE_SHARE - 0.000001))
	return [votes, need, players]


func _check_votes() -> void:
	if _vote_locked or not lobby:
		return
	var c := _vote_counts()
	var min_players := 1 if _alone >= VOTE_SOLO_AFTER else VOTE_MIN
	if int(c[2]) >= min_players and int(c[0]) >= int(c[1]):
		_vote_locked = true  # later joiners or changed votes don't cancel it
		lobby_left = minf(lobby_left, VOTE_START_SECS)


func _lobby_frame(dt: float) -> void:
	var c := _vote_counts()
	if int(c[2]) == 0:
		lobby_left = lobby_secs  # the countdown starts when the first player is in
		_vote_locked = false
		_alone = 0.0
		return
	_alone = _alone + dt if int(c[2]) == 1 else 0.0
	lobby_left -= dt
	_check_votes()
	if peers.size() >= max_humans:
		lobby_left = minf(lobby_left, JOIN_CLOSE_SECS + 1.0)
	if lobby_left <= 0.0:
		if team_game and not teams_ready:
			if int(c[2]) < 2:
				lobby_left = 1.0  # a team game needs at least two people
				return
			make_teams()
		_end_lobby()
		return
	_lobby_sent += dt
	if _lobby_sent >= 0.5:
		_lobby_sent = 0.0
		_send_lobby_all()


func _end_lobby() -> void:
	lobby = false
	lobby_left = 0.0
	g.deploy_t = SPAWN_SECS
	_send_lobby_all()
	for peer in peers:
		send.call(peer, _pack(S_STATE, _state_dict(int(peers[peer].nid))))


func _lobby_dict(peer: int) -> Dictionary:
	var c := _vote_counts()
	var names := []
	for p in peers.values():
		if names.size() < 3:
			names.append(str(p.name))
	return {"on": lobby, "left": maxf(0.0, lobby_left), "players": int(c[2]), "max": max_humans, "votes": int(c[0]), "need": int(c[1]),
		"voted": _votes.has(peer), "names": names, "team": team_game, "teams": team_config,
		"total": lobby_secs, "vote_min": 1 if _alone >= VOTE_SOLO_AFTER else VOTE_MIN, "spawn": SPAWN_SECS}


func _send_lobby(peer: int) -> void:
	if peers.has(peer):
		send.call(peer, _pack(S_LOBBY, _lobby_dict(peer)))


func _send_lobby_all() -> void:
	for peer in peers:
		if not peers[peer].has("disconnected_until"):
			_send_lobby(peer)


## The spawn phase is over: anybody who didn't choose a start gets one on free land.
func autoplace() -> void:
	for peer in peers:
		var nid: int = int(peers[peer].nid)
		if int(g.nations[nid].land) > 0:
			continue
		var t: int = g._random_start()
		if t < 0:
			t = g._find_spawn_tile(g.W / 2, g.H / 2)
		if t >= 0:
			NetIntentsC.apply(g, nid, {"type": "spawn", "tile": t})
