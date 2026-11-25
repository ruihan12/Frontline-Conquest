# Multiplayer match over an in-process pipe: a host main node with two remote viewers.
#   godot --headless --path . -s res://tests/test_net_match.gd
extends SceneTree

const Host = preload("res://net/mp_host.gd")
const Client = preload("res://net/mp_client.gd")
const NetRep = preload("res://net/rep.gd")
var fails := 0

func _ok(cond: bool, what: String) -> void:
	if not cond:
		fails += 1
	print(("  ok   " if cond else "  FAIL ") + what)

func _init() -> void:
	var hs = load("res://sim/headless_sim.gd").new(self)
	var ha = load("res://sim/headless_sim.gd").new(self)
	var hb = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async(); await ha.ready_async(); await hb.ready_async()
	var clients := {}
	var host := Host.new(hs.m, func(peer: int, pkt: PackedByteArray) -> void: clients[peer].on_message(pkt))
	host.start_match(0, 0, 8, 1)
	var ca := Client.new(ha.m, func(pkt: PackedByteArray) -> void: host.on_message(1, pkt))
	var cb := Client.new(hb.m, func(pkt: PackedByteArray) -> void: host.on_message(2, pkt))
	clients[1] = ca
	clients[2] = cb
	ca.join("Alice")
	cb.join("Bob")
	_ok(host.human_count() == 2, "two people joined")
	_ok(ca.started and cb.started, "both viewers started their round from HELLO")
	_ok(ha.m.nations.size() == hs.m.nations.size() and hb.m.nations.size() == hs.m.nations.size(), "nation counts match the host (%d)" % hs.m.nations.size())
	_ok(ha.m.nations[1].name == "Alice" and hb.m.nations[1].name == "Bob", "each viewer is nation 1 under its own name")
	var nb: int = host.peers[2].nid
	_ok(nb > 1 and hs.m.nations[nb].name == "Bob", "Bob has nation %d on the host" % nb)
	_ok(hb.m.nations[nb].name == "Alice" and ha.m.nations[nb].name == "Bob", "each viewer sees the other under the host id (swap 1 and own)")
	# spawn phase: both pick a spot
	_ok(hs.m.state == "pick", "host is in the spawn phase")
	var ta: int = hs.m._find_spawn_tile(hs.m.W / 2, hs.m.H / 2)
	var tb: int = hs.m._find_spawn_tile(hs.m.W / 4, hs.m.H / 2)
	ca.send_intent({"type": "spawn", "tile": ta})
	cb.send_intent({"type": "spawn", "tile": tb})
	_ok(hs.m.nations[1].land > 0 and hs.m.nations[nb].land > 0, "spawn intents took effect (%d, %d tiles)" % [hs.m.nations[1].land, hs.m.nations[nb].land])
	# illegal intents are ignored
	var before: int = hs.m.nations[1].land
	_ok(not host.apply_intent(1, {"type": "format_disk"}), "unknown intent type refused")
	_ok(not host.apply_intent(1, {"type": "attack", "tile": "x"}), "malformed intent refused")
	_ok(not host.apply_intent(1, {"type": "attack", "tile": 1}), "attack refused during the spawn phase")
	# start play
	hs.m.state = "play"; hs.m.deploy_t = 0.0; hs.m.peace = 0.0
	hs.m.begin_shields()
	hs.step(50)
	# Alice attacks from her blob
	var edge := -1
	var W: int = hs.m.W
	for i in range(ta, ta + 400):
		pass
	for r in range(1, 80):
		var t: int = ta + r
		if t < W * hs.m.H and hs.m.owner_map[t] == 0:
			edge = t
			break
	var a0: int = hs.m.nations[1].land
	ca.send_intent({"type": "attack", "tile": edge, "ratio": 0.5})
	hs.step(80)
	_ok(hs.m.nations[1].land > a0, "Alice's attack grew her territory (%d -> %d)" % [a0, hs.m.nations[1].land])
	# both viewers hold the same world as the host, in their own id space
	var diff_a := 0
	var diff_b := 0
	for i in hs.m.owner_map.size():
		var o: int = hs.m.owner_map[i]
		var want_a: int = NetRep.swap_id(o, 1) if o > 0 else (o if o < 0 else 0)
		var want_b: int = NetRep.swap_id(o, nb) if o > 0 else (o if o < 0 else 0)
		var ga: int = ha.m.owner_map[i]; var gb: int = hb.m.owner_map[i]
		if (ga if ga > 0 else (ga if ga < 0 else 0)) != want_a: diff_a += 1
		if (gb if gb > 0 else (gb if gb < 0 else 0)) != want_b: diff_b += 1
	_ok(diff_a == 0, "Alice's view equals the host's world (%d differing tiles)" % diff_a)
	_ok(diff_b == 0, "Bob's view equals the host's world (%d differing tiles)" % diff_b)
	_ok(ha.m.nations[1].land == hs.m.nations[1].land, "Alice's land count matches")
	_ok(hb.m.nations[nb].land == hs.m.nations[1].land, "Bob sees Alice's land under host id %d" % nb)
	# rate limit: a flood is dropped
	var applied := 0
	for _k in 200:
		var pkt := Host._pack(Host.C_INTENT, {"type": "reinforce"})
		var tick0: int = hs.m.ticks_done
		host.on_message(1, pkt)
	_ok(float(host.peers[1].tokens) < 1.0, "intent flood drains the rate-limit bucket")
	print("NET_MATCH_TEST ", "PASS" if fails == 0 else "FAIL", " fails=", fails)
	for h in [hs, ha, hb]:
		h.m.queue_free()
	quit(fails)
