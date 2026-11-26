# Multiplayer remote viewer (see MPHost for the protocol). This process does not tick the sim: it starts its
# round from the host's HELLO, then writes the replicated territory, nations and entity lists into main's own
# arrays, so the existing renderer and HUD work unchanged. The local player is always nation 1.
class_name MPClient
extends RefCounted

const NetRepC = preload("res://net/rep.gd")
const HostC = preload("res://net/mp_host.gd")

var g  # main.gd
var send: Callable
var my_name := "Player"
var started := false
var resume_token := ""
var winner := -1
var ranks := []
var rejected := ""
var result := {}
var last_event := {}
var _motion := preload("res://client/map/viewer_motion.gd").new()


func _init(main, send_cb: Callable) -> void:
	g = main
	send = send_cb


func join(pname: String, token := "", party := "", mode := "") -> void:
	my_name = pname
	send.call(HostC._pack(HostC.C_JOIN, {"name": pname, "token": token, "party": party, "mode": mode}))


func resume() -> void:
	send.call(HostC._pack(HostC.C_JOIN, {"resume": resume_token}))


func send_intent(intent: Dictionary) -> void:
	send.call(HostC._pack(HostC.C_INTENT, intent))


var _hello_wait := false
var _held: Array = []


## The waiting room's "Vote to start" toggle.
func send_vote(v: bool) -> void:
	send.call(PackedByteArray([HostC.C_VOTE]) + var_to_bytes({"vote": v}))


func on_message(pkt: PackedByteArray) -> void:
	if pkt.size() < 1:
		return
	if _hello_wait:
		_held.append(pkt)
		return
	if not _held.is_empty():
		var q := _held
		_held = []
		for h in q: on_message(h)
	var t: int = pkt[0]
	var body := pkt.slice(1)
	match t:
		HostC.S_HELLO:
			var d: Dictionary = bytes_to_var(body)
			resume_token = str(d.get("resume", ""))
			d.erase("resume")
			g.net_remote = true
			g.net_client = self
			g.net_hello = d
			g.net_lobby = {}
			g.map_tab = int(d.map_tab)
			g.map_i = int(d.map_i)
			g.diff_i = int(d.get("diff", 1))
			var up_id: String = g.UpstreamMaps.id_at(g.map_i)
			if g.UpstreamMaps.needs_fetch(up_id):
				# web: the map's terrain is downloaded first; packets that arrive meanwhile wait their turn
				_hello_wait = true
				var ok: bool = await g.UpstreamMaps.ensure(up_id, g)
				_hello_wait = false
				if not ok:
					g.notify("Could not download that map.", "warn")
					return
			g._start_game()
			g.net_rec = false
			g.team_mode = bool(d.get("team_game", false))  # (the teams themselves arrive in S_TEAMS once the roster is full)
			if g.team_mode and not started:
				g.notify("Team match: waiting for %d players" % int(d.get("team_expected", 0)), "info")
			# the round starts in the host's phase; the replicated tiles come next
			started = true
			if not _held.is_empty():
				var q2 := _held
				_held = []
				for h2 in q2: on_message(h2)
		HostC.S_SNAPSHOT:
			NetRepC.apply_tiles(g, body)
		HostC.S_DELTA:
			NetRepC.apply_tiles(g, body)
		HostC.S_NATIONS:
			NetRepC.apply_nations(g, body)
		HostC.S_LISTS:
			NetRepC.apply_lists(g, body, _motion.update)
		HostC.S_LOBBY:
			var lb = bytes_to_var(body)
			if lb is Dictionary:
				g.net_lobby = lb
		HostC.S_STATE:
			var s: Dictionary = bytes_to_var(body)
			g.sim_atk.tick = int(s.tick)
			g.elapsed = float(s.elapsed)
			g.deploy_t = float(s.deploy_t)
			g.peace = float(s.peace)
			g.land_total = int(s.get("land_total", g.land_total))
			g.fallout_count = int(s.get("fallout", g.fallout_count))
			g.shield_until.clear()
			for id in s.shields:
				g.shield_until[int(id)] = int(s.shields[id])
			if s.has("allies"):
				g.allies.clear()
				for k in s.allies:
					g.allies[int(k)] = int(s.allies[k])
				g.traitor.clear()
				for k in s.traitor:
					g.traitor[int(k)] = int(s.traitor[k])
				var old_reqs: Dictionary = g.ally_requests
				g.ally_requests = {}
				for k in s.reqs:
					g.ally_requests[int(k)] = int(s.reqs[k])
					if int(k) % 1024 == 1 and not old_reqs.has(int(k)):  # someone asked me
						g.sfx("ally_suggest")
						g._show_ally_card("propose", int(k) / 1024)
			if str(s.state) != g.state:
				g.state = str(s.state)
		HostC.S_NATION_INFO:
			for e in bytes_to_var(body):
				var id := int(e[0])
				if id > 0 and id < g.nations.size():
					g.nations[id].name = str(e[1])
					g.nations[id].color = Color.html(str(e[2]))
					g.nations[id].alive = bool(e[3])
					if bool(e[4]): g.nations[id]["human"] = true
			g._rebuild_kind_cache()
		HostC.S_EVENT:
			var event = bytes_to_var(body)
			if event is Dictionary:
				last_event = event
				_play_event(event)
		HostC.S_TEAMS:
			var td: Dictionary = bytes_to_var(body)
			g.team_mode = true
			g.team_names = td.names
			for k in td.teams:
				if int(k) < g.nations.size():
					g.nations[int(k)]["team"] = int(td.teams[k])
			var mt := int(td.me_team)
			if mt > 0 and mt <= g.team_names.size():
				g.notify("You are on team %s" % g.team_names[mt - 1], "info")
		HostC.S_RESULT:
			result = bytes_to_var(body)
		HostC.S_REJECT:
			rejected = str(bytes_to_var(body).get("reason", "refused"))
		HostC.S_END:
			var e: Dictionary = bytes_to_var(body)
			winner = int(e.winner)
			ranks = e.ranks
			g._game_over(winner == 1 or (int(e.get("winner_team", 0)) != 0 and int(e.get("winner_team", 0)) == int(e.get("me_team", -1))))



func _play_event(event: Dictionary) -> void:
	var actor := int(event.get("actor", 0))
	var target := int(event.get("target", 0))
	var kind := int(event.get("kind", 7))
	match event.get("type", ""):
		"nuke_launch":
			if actor == 1:
				g.sfx("mirv_launch" if kind == 9 else ("hydrogen_launch" if kind in [8, 11] else "atom_launch"))
			elif target == 1:
				g.sfx("nuke_warning")
				g.notify("%s launched a missile at you" % g._nname(actor), "bad")
		"nuke_hit":
			var tile := int(event.get("tile", -1))
			if tile < 0 or tile >= g.W * g.H:
				return
			var nk := int(event.get("nk", 0))
			if g.fx_layer != null:
				g.fx_layer.nuke(nk, tile, clampf(float(event.get("radius", 0.0)), 0.0, 1000.0))
			var world := Vector2(tile % int(g.W), tile / int(g.W)) * float(g.TS)
			var my_hit := actor == 1 or target == 1
			g.sfx("hydrogen_hit" if kind in [8, 11] and nk != SimRules.N_WARHEAD else "atom_hit",
				0.0 if my_hit else -8.0, 0.04, 1 if my_hit else actor, world)
		"sam":
			var point: Vector2 = event.get("point", Vector2.ZERO)
			if g.fx_layer != null:
				g.fx_layer.burst("sam", point.x, point.y)
			g.sfx("sam_hit")
			g.notify("Your SAM intercepted a missile" if actor == 1 else "Your missile was intercepted", "info")
		"alliance_request":
			# The replicated request list still delivers the alliance card and its sound.
			g.notify("%s sent you an alliance request" % g._nname(actor), "info")
		"attack":
			g.notify("%s is attacking you" % g._nname(actor), "bad")
		_:
			var text := str(event.get("text", ""))
			var style := str(event.get("kind", "info"))
			if not text.is_empty() and style in ["info", "good", "bad"]:
				g.notify(text, style)
