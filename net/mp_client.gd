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
var winner := -1
var ranks := []
var rejected := ""
var result := {}
var last_event := {}


func _init(main, send_cb: Callable) -> void:
	g = main
	send = send_cb


func join(pname: String, token := "") -> void:
	my_name = pname
	send.call(HostC._pack(HostC.C_JOIN, {"name": pname, "token": token}))


func send_intent(intent: Dictionary) -> void:
	send.call(HostC._pack(HostC.C_INTENT, intent))


func on_message(pkt: PackedByteArray) -> void:
	if pkt.size() < 1:
		return
	var t: int = pkt[0]
	var body := pkt.slice(1)
	match t:
		HostC.S_HELLO:
			var d: Dictionary = bytes_to_var(body)
			g.net_remote = true
			g.net_client = self
			g.net_hello = d
			g.map_tab = int(d.map_tab)
			g.map_i = int(d.map_i)
			g.diff_i = int(d.get("diff", 1))
			g._start_game()
			g.net_rec = false
			g.team_mode = bool(d.get("team_game", false))  # (the teams themselves arrive in S_TEAMS once the roster is full)
			if g.team_mode:
				g.notify("Team match: waiting for %d players" % int(d.get("team_expected", 0)), "info")
			# the round starts in the host's phase; the replicated tiles come next
			started = true
		HostC.S_SNAPSHOT:
			NetRepC.apply_tiles(g, body)
		HostC.S_DELTA:
			NetRepC.apply_tiles(g, body)
		HostC.S_NATIONS:
			NetRepC.apply_nations(g, body)
		HostC.S_LISTS:
			NetRepC.apply_lists(g, body)
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
			last_event = bytes_to_var(body)
			g.notify(str(last_event.get("text", "")), str(last_event.get("kind", "info")))
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
