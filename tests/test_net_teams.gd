# A team match over in-process pipes: 4 viewers, no bot players, teams made when the roster is full.
#   godot --headless --path . -s res://tests/test_net_teams.gd
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
	var vs := []
	for i in 4:
		vs.append(load("res://sim/headless_sim.gd").new(self))
	await hs.ready_async()
	for v in vs: await v.ready_async()
	var clients := {}
	var host := Host.new(hs.m, func(peer: int, pkt: PackedByteArray) -> void: clients[peer].on_message(pkt))
	host.lobby_enabled = false  # (the waiting room has its own test: test_net_lobby.gd)
	host.max_humans = 4
	host.team_game = true
	host.team_expected = 4
	host.start_match(0, 0, 40, 1)  # 40 bots asked for: a team game must not make them
	var cl := []
	for i in 4:
		var c := Client.new(vs[i].m, func(pkt: PackedByteArray) -> void: host.on_message(i + 1, pkt))
		clients[i + 1] = c
		cl.append(c)
	var bot_nations := 0
	for n in hs.m.nations:
		if n.get("ai", false) and not n.get("tribe", false) and n.name != "(open)":
			pass
	_ok(hs.m.bot_players == 0, "no bot players in a team game")
	host.party_valid = func(k: String) -> bool: return k == "K1"
	for i in 3:
		cl[i].join("P%d" % i, "", "K1" if i < 2 else "bogus")
	_ok(not host.teams_ready, "teams wait for the roster")
	_ok(not host.apply_intent(1, {"type": "spawn", "tile": 5}), "no intents before the teams are made")
	cl[3].join("P3")
	_ok(host.teams_ready and hs.m.team_mode and hs.m.team_names.size() >= 2, "teams made when full: %s (%s)" % [str(hs.m.team_names), host.team_config])
	var seen := {}
	for p in host.peers.values():
		seen[int(hs.m.nations[p.nid].team)] = int(seen.get(int(hs.m.nations[p.nid].team), 0)) + 1
	_ok(seen.size() == hs.m.team_names.size() and not seen.has(0), "every player is on a team: %s" % str(seen))
	if hs.m.team_names.size() < 4:
		_ok(int(hs.m.nations[host.peers[1].nid].team) == int(hs.m.nations[host.peers[2].nid].team), "a party stays on one team")
	_ok(host.team_groups.has(1) and host.team_groups.has(2) and not host.team_groups.has(3), "only a valid party key groups players")
	var a: int = host.peers[1].nid
	var mate := -1
	var foe := -1
	for p in host.peers.values():
		if p.nid != a:
			if hs.m.nations[p.nid].team == hs.m.nations[a].team: mate = p.nid
			else: foe = p.nid
	_ok(foe > 0, "there is an opposing team")
	if mate > 0:
		_ok(hs.m.allied(a, mate) and hs.m.same_team(a, mate), "teammates are friendly")
		_ok(hs.m.nations[a].color != hs.m.nations[mate].color, "teammates have shades of the team colour")
	_ok(not hs.m.allied(a, foe), "opponents are not friendly")
	_ok(vs[0].m.team_mode and vs[0].m.team_names == hs.m.team_names, "viewer got the team list")
	_ok(int(vs[0].m.nations[1].team) == int(hs.m.nations[a].team), "viewer knows its own team as nation 1")
	# tribes are on no team
	var tribe_team := 0
	for i in range(1, hs.m.nations.size()):
		if hs.m.nations[i].get("tribe", false) and int(hs.m.nations[i].get("team", 0)) != 0: tribe_team += 1
	_ok(tribe_team == 0, "tribes are on no team")
	# Use a pair of local fixtures even if Quads resolved to four separate teams this round.
	var original_team: int = hs.m.nations[foe].team
	hs.m.nations[foe].team = hs.m.nations[a].team
	var target := 6
	hs.m.structs.append({"o": foe, "tile": target + 1})
	hs.m.state = "play"
	_ok(hs.m.teammate_building_in_blast(a, 7, target) and hs.m.teammate_building_in_blast(a, 8, target), "atom and hydrogen respect teammate blast radius")
	_ok(not hs.m.teammate_building_in_blast(a, 9, target), "MIRV keeps upstream rules")
	_ok(not host.apply_intent(a, {"type": "nuke", "kind": "atom", "tile": target}), "host denies a teammate blast")
	hs.m.team_mode = false
	_ok(not hs.m.teammate_building_in_blast(a, 7, target), "free-for-all is unaffected")
	hs.m.team_mode = true
	hs.m.structs.pop_back()
	hs.m.nations[foe].team = original_team
	# a leaver is no longer a teammate
	if mate > 0:
		hs.m.state = "play"
		var mate_peer := -1
		for pk in host.peers:
			if host.peers[pk].nid == mate: mate_peer = pk
		host.leave(mate_peer)
		_ok(not hs.m.allied(a, mate), "a teammate who left may be attacked")
	# winning: a team with 80% of the land ends the match
	hs.m.state = "play"; hs.m.ticks_done = 100
	hs.m.nations[a].land = int(hs.m.land_total * 0.9)
	var got := {}
	host.on_end = func(pl: Array) -> void: got["pl"] = pl
	host.check_end()
	_ok(host.ended and hs.m.winner_team == int(hs.m.nations[a].team), "the team with 80% of the land wins")
	var pl: Array = got.get("pl", [])
	_ok(pl.size() >= 2 and pl[0].team == hs.m.winner_team and pl[0].placement == 1, "winning team is placement 1")
	var other_place := 0
	for e in pl:
		if e.team != hs.m.winner_team: other_place = e.placement
	_ok(other_place == 2, "the other team is 2nd")
	print("NET_TEAMS_TEST ", "PASS" if fails == 0 else "FAIL", " fails=", fails)
	quit(fails)
