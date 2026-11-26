# Waiting room and shared spawn phase over an in-process pipe.
#   godot --headless --path . -s res://tests/test_net_lobby.gd
extends SceneTree

const Host = preload("res://net/mp_host.gd")
const Client = preload("res://net/mp_client.gd")
var fails := 0

func _ok(cond: bool, what: String) -> void:
	if not cond:
		fails += 1
	print(("  ok   " if cond else "  FAIL ") + what)

func _init() -> void:
	var hs = load("res://sim/headless_sim.gd").new(self)
	var ha = load("res://sim/headless_sim.gd").new(self)
	var hb = load("res://sim/headless_sim.gd").new(self)
	var hc = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async(); await ha.ready_async(); await hb.ready_async(); await hc.ready_async()
	var clients := {}
	var host := Host.new(hs.m, func(peer: int, pkt: PackedByteArray) -> void: clients[peer].on_message(pkt))
	host.start_match(0, 0, 8, 1)
	_ok(host.lobby, "the match opens in the waiting room")
	var ca := Client.new(ha.m, func(pkt: PackedByteArray) -> void: host.on_message(1, pkt))
	var cb := Client.new(hb.m, func(pkt: PackedByteArray) -> void: host.on_message(2, pkt))
	clients[1] = ca
	clients[2] = cb
	host.frame(5.0)
	_ok(is_equal_approx(host.lobby_left, Host.LOBBY_SECS), "the countdown waits for the first player")
	ca.join("Alice")
	_ok(ha.m.net_lobby.get("on", false) and int(ha.m.net_lobby.players) == 1, "Alice is told the room is open (1 player)")
	cb.join("Bob")
	_ok(int(ha.m.net_lobby.players) == 2 and int(hb.m.net_lobby.players) == 2, "both see 2 players")
	_ok(ha.m.in_waiting_room() and host.apply_intent(1, {"type": "spawn", "tile": 5}) == false, "no spawn in the waiting room")
	host.frame(10.0)
	_ok(host.lobby_left < Host.LOBBY_SECS - 9.0, "the countdown runs")
	ca.send_vote(true)
	_ok(int(ha.m.net_lobby.votes) == 1 and int(ha.m.net_lobby.need) == 2, "1 of 2 votes needed")
	_ok(host.lobby_left > Host.VOTE_START_SECS, "one vote does not start it")
	cb.send_vote(true)
	_ok(host.lobby_left <= Host.VOTE_START_SECS, "two thirds voted: it starts in %d s" % int(Host.VOTE_START_SECS))
	host.frame(Host.VOTE_START_SECS - Host.JOIN_CLOSE_SECS + 1.0)
	var cc := Client.new(hc.m, func(pkt: PackedByteArray) -> void: host.on_message(3, pkt))
	clients[3] = cc
	cc.join("Late")
	_ok(cc.rejected == "match_started", "joins close just before the start (%s)" % cc.rejected)
	host.frame(Host.JOIN_CLOSE_SECS + 1.0)
	_ok(not host.lobby and hs.m.state == "pick", "the room closed, the spawn phase is on")
	_ok(is_equal_approx(hs.m.deploy_t, Host.SPAWN_SECS), "one shared spawn timer (%d s)" % int(hs.m.deploy_t))
	_ok(not ha.m.net_lobby.on, "viewers are told it closed")
	var ta: int = hs.m._find_spawn_tile(hs.m.W / 2, hs.m.H / 2)
	ca.send_intent({"type": "spawn", "tile": ta})
	_ok(hs.m.nations[1].land > 0, "Alice picked her start")
	var nb: int = host.peers[2].nid
	_ok(hs.m.nations[nb].land == 0, "Bob has not")
	host.autoplace()
	_ok(hs.m.nations[nb].land > 0, "Bob gets a start chosen for him when the timer ends (%d tiles)" % hs.m.nations[nb].land)
	print("net lobby: %d failures" % fails)
	quit(1 if fails else 0)
