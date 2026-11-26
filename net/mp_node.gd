# Glue node: owns a transport and either an MPHost (server / player host) or an MPClient (viewer), and pumps
# the transport every frame. Created by main.gd _net_boot from command-line flags:
#   server:  godot --headless --path . -- --server --port=8070 [--bots=40] [--map=0:0] [--max=8] [--enet]
#   viewer:  godot --path . -- --connect=ws://host:8070 [--name=Bob]
class_name MPNode
extends Node

const HostC = preload("res://net/mp_host.gd")
const ClientC = preload("res://net/mp_client.gd")
const TransportC = preload("res://net/transport.gd")
const PartyServiceC = preload("res://net/party_service.gd")

var g
var transport
var host
var client
var role := ""
var server_peers := {}
var party_service  # server: the party hub
var requested_mode := ""
var mixed_modes := false
var _mode_locked := false
var party := ""    # client: the party key named when joining a match
var joined := false
var player_name := "Player"
var connected_ok := false
var _ws_url := ""
var _retrying := false
var _retry_until := 0
var _retry_at := 0
const RETRY_INTERVAL_MS := 2200
var status := "idle"
signal rejected(reason: String)
signal connected
signal entered  # the host accepted us and the round has started on this side
signal result(data: Dictionary)
var _entered := false
var _result_sent := false
var token := ""  # client: the session token sent when joining
var api_base := "http://127.0.0.1:8071/api/v1"
var internal_key := ""
var ranked := false
var _spawn_wait := 0.0
var autospawn := false
var _spawned := false
var local_player := false
var _pending := []
var _end_wait := 0.0
var _last_args := []
const NEXT_MATCH_AFTER := 25.0  # seconds the end screen stays up before the server starts the next match
var netlog := false
var _log_t := 0.0


func start_server(main, port: int, bots: int, map_tab: int, map_i: int, max_humans: int, use_enet := false) -> int:
	g = main
	role = "server"
	transport = TransportC.new()
	var err: int = transport.listen_enet(port, max_humans) if use_enet else transport.listen_ws(port)
	if err != OK:
		status = "listen failed (%d)" % err
		return err
	host = HostC.new(g, func(peer: int, pkt: PackedByteArray) -> void:
		if server_peers.has(peer):
			transport.send(peer, pkt))
	host.max_humans = max_humans
	if OS.has_environment("FRONTLINE_LOBBY_SECS"):
		host.lobby_secs = clampf(float(OS.get_environment("FRONTLINE_LOBBY_SECS")), 5.0, 600.0)
	if not use_enet or DisplayServer.get_name() == "headless":
		g.net_dedicated = DisplayServer.get_name() == "headless"
	if g.net_dedicated and g.names != null:
		g.names.set_process(false)
		g.names.hide()
	api_base = OS.get_environment("FRONTLINE_API") if OS.has_environment("FRONTLINE_API") else api_base
	internal_key = OS.get_environment("INTERNAL_KEY")
	ranked = OS.get_environment("FRONTLINE_RANKED") == "1"
	host.ranked = ranked
	# team games: FRONTLINE_MODE=teams, FRONTLINE_TEAM_PLAYERS = how many people the match waits for (4-12)
	mixed_modes = OS.get_environment("FRONTLINE_MODE") == "mixed"
	if OS.get_environment("FRONTLINE_MODE") == "teams" or mixed_modes:
		host.team_game = true
		host.team_expected = clampi(int(OS.get_environment("FRONTLINE_TEAM_PLAYERS")) if OS.has_environment("FRONTLINE_TEAM_PLAYERS") else 6, 4, 12)
	if internal_key != "":
		host.join_gate = _gate_join
		host.on_end = _report_result
	elif ranked:
		push_warning("FRONTLINE_RANKED=1 without INTERNAL_KEY: results will not be reported")
	if mixed_modes and not host.join_gate.is_valid():
		host.join_gate = func(peer: int, d: Dictionary) -> void: _join_match(peer, d, str(d.get("name", "")))
	party_service = PartyServiceC.new(func(peer: int, t: int, payload) -> void: transport.send(peer, HostC._pack(t, payload)))
	host.party_valid = party_service.key_alive
	host.party_size = party_service.size_for_key
	host.party_joined = party_service.match_joined
	host.party_left = party_service.match_left
	transport.peer_connected.connect(func(id: int) -> void: server_peers[id] = true)
	transport.peer_disconnected.connect(func(id: int) -> void:
		server_peers.erase(id)
		party_service.peer_left(id)
		if use_enet:
			host.leave(id)
		else:
			host.transport_lost(id))
	transport.packet.connect(func(id: int, data: PackedByteArray) -> void:
		if data.size() > 1 and data[0] == HostC.C_PARTY:
			if data.size() <= 512:
				party_service.on_message(id, bytes_to_var(data.slice(1)))
		else:
			host.on_message(id, data))
	_pending = [map_tab, map_i, bots]
	_last_args = [map_tab, map_i, bots]
	status = "listening on %d" % port
	return OK


## A player's PC hosts a casual match: this process runs the sim and plays nation 1, others connect over ENet.
func start_local_host(main, port: int, bots: int, max_humans: int) -> int:
	var err: int = start_server(main, port, bots, int(main.map_tab), int(main.map_i), max_humans, true)
	if err != OK:
		return err
	role = "server"
	local_player = true
	host.host_is_player = true
	return OK


func start_client(main, url: String, pname: String, use_enet := false) -> int:
	g = main
	role = "client"
	player_name = pname
	transport = TransportC.new()
	var err: int
	if use_enet:
		var parts := url.split(":")
		err = transport.connect_enet(parts[0], int(parts[1]) if parts.size() > 1 else 8070)
	else:
		_ws_url = url
		err = transport.connect_ws(url)
	if err != OK:
		status = "connect failed (%d)" % err
		return err
	client = ClientC.new(g, func(pkt: PackedByteArray) -> void: transport.send(1, pkt))
	_wire_client()
	status = "connecting"
	return OK


func _wire_client() -> void:
	transport.packet.connect(func(_id: int, data: PackedByteArray) -> void:
		client.on_message(data)
		if _retrying and not data.is_empty() and data[0] == HostC.S_HELLO:
			_retrying = false
			status = "connected"
			g.notify("Reconnected to the match.", "good"))
	transport.peer_disconnected.connect(func(_id: int) -> void: _lost_connection())


func _lost_connection() -> void:
	status = "disconnected"
	if _ws_url.is_empty() or not _entered or client.resume_token.is_empty() or g.state != "play":
		return
	if not _retrying:
		_retrying = true
		_retry_until = Time.get_ticks_msec() + HostC.RESUME_GRACE_MS
		_retry_at = 0
		g.notify("Connection lost. Reconnecting…", "info")


func _poll_reconnect() -> void:
	var now := Time.get_ticks_msec()
	if now >= _retry_until:
		_retrying = false
		client.rejected = "resume_expired"
		return
	if now < _retry_at:
		return
	_retry_at = now + RETRY_INTERVAL_MS
	transport.close()
	transport = TransportC.new()
	joined = false
	if transport.connect_ws(_ws_url) == OK:
		_wire_client()


func _dbg(m: String) -> void:
	var f := FileAccess.open("/tmp/mpnode.log", FileAccess.READ_WRITE if FileAccess.file_exists("/tmp/mpnode.log") else FileAccess.WRITE)
	f.seek_end()
	f.store_line(m)
	f.close()

func _process(dt: float) -> void:
	if transport == null:
		return
	if not _pending.is_empty():
		# the match starts in a normal frame: inside the boot's deferred-call flush the UI relayout never settles
		var pm := _pending
		_pending = []
		host.start_match(pm[0], pm[1], pm[2])
		var cap := float(OS.get_environment("FRONTLINE_SPEED_CAP")) if OS.has_environment("FRONTLINE_SPEED_CAP") else 1.0
		g.net_speed_cap = clampf(cap, 0.5, 2.0 if ranked else 10.0)
		if local_player:
			g.net_speed_cap = 1.0  # a hosted casual match is 1x for everyone
		g.set_speed_x(g.net_speed_cap)
		print("MPSERVER match started state=", g.state, " speed=", g.sim_speed / g.SPEED_BASE)
	if _retrying:
		_poll_reconnect()
	transport.poll()
	if role == "client" and joined and status == "connected" and not transport.is_up():
		_lost_connection()
	if role == "server" and host != null:
		host.frame(dt)
	if role == "server" and host != null and host.ended and not local_player:
		_end_wait += dt
		if _end_wait >= NEXT_MATCH_AFTER:
			_end_wait = 0.0
			for peer in server_peers.keys():
				if party_service.has_peer(peer):
					continue  # people waiting in the party hub stay connected
				transport.disconnect_peer(peer)
				server_peers.erase(peer)
			if mixed_modes:
				_mode_locked = false
				host.team_game = not host.team_game  # default for older clients
				host.team_expected = clampi(int(OS.get_environment("FRONTLINE_TEAM_PLAYERS")) if OS.has_environment("FRONTLINE_TEAM_PLAYERS") else 6, 4, 12)
			_pending = _last_args.duplicate()  # the next match starts next frame
	if netlog and _log_t == 0.0 and not has_meta("first"):
		set_meta("first", true)
		print("NETLOG first frame dt=", dt)
	if netlog:
		_log_t += dt
		if _log_t >= 2.0:
			_log_t = 0.0
			print("NETLOG ", role, " status=", status, " state=", g.get("state"), " ticks=", g.get("ticks_done"), " peers=", server_peers.size(), " remote=", g.get("net_remote"), " land=", (g.nations[1].land if g.nations.size() > 1 else -1), " nations=", g.nations.size())
	if role == "client" and client != null and client.rejected != "" and status != "rejected":
		status = "rejected"
		_retrying = false
		rejected.emit(client.rejected)
	if role == "client" and client != null:
		if not _entered and client.started:
			_entered = true
			entered.emit()
		if not client.result.is_empty() and not _result_sent:
			_result_sent = true
			result.emit(client.result)
	if role == "client" and not joined and transport.is_up():
		joined = true
		connected_ok = true
		status = "connected"
		connected.emit()
		if _retrying:
			client.resume()
		else:
			client.join(player_name, token, party, requested_mode)
	if autospawn and role == "client" and joined and g.net_remote and g.state == "pick" and not g.in_waiting_room() and g.nations.size() > 1 and int(g.nations[1].land) == 0 \
			and (not g.team_mode or not g.team_names.is_empty()):
		_spawn_wait += dt
		if _spawn_wait < 1.0:
			return
		_spawn_wait = 0.0
		client.send_intent({"type": "spawn", "tile": g._find_spawn_tile(g.W / 2 + randi() % 200, g.H / 2)})


# ---- account checks on the server (the account service is on this machine; the key never leaves it) ----

func _api(path: String, body: Dictionary, done: Callable) -> void:
	var req := HTTPRequest.new()
	req.timeout = 8.0
	add_child(req)
	req.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, data: PackedByteArray) -> void:
		req.queue_free()
		var parsed = JSON.parse_string(data.get_string_from_utf8())
		done.call(result == HTTPRequest.RESULT_SUCCESS and code == 200, parsed if parsed is Dictionary else {}))
	var err := req.request(api_base + path, PackedStringArray(["Content-Type: application/json", "X-Internal-Key: " + internal_key]), HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		req.queue_free()
		done.call(false, {})


func _gate_join(peer: int, d: Dictionary) -> void:
	var tok := str(d.get("token", ""))
	if tok == "":
		if ranked:
			host.reject(peer, "account_required")
		else:
			_join_match(peer, d, str(d.get("name", "")))
		return
	_api("/internal/verify-session", {"token": tok}, func(ok: bool, r: Dictionary) -> void:
		if not server_peers.has(peer):
			return  # left while we were asking
		if not ok:
			host.reject(peer, "invalid_session")
			return
		var guest := bool(r.get("guest", false))
		if ranked and guest:
			host.reject(peer, "account_required")
			return
		for p in host.peers.values():  # one seat per account
			if not guest and int(p.get("account", 0)) == int(r.get("account_id", -1)):
				host.reject(peer, "already_joined")
				return
		_join_match(peer, d, str(r.get("username", r.get("name", d.get("name", "")))), 0 if guest else int(r.get("account_id", 0))))



func _join_match(peer: int, data: Dictionary, display_name: String, account := 0) -> void:
	if mixed_modes:
		var mode = data.get("mode", "")
		if mode not in ["", "ffa", "teams"]:
			host.reject(peer, "mode_unavailable")
			return
		if mode != "" and (mode == "teams") != host.team_game:
			if _mode_locked or host.ended or not host.peers.is_empty() or g.state != "pick":
				host.reject(peer, "mode_unavailable")
				return
			host.team_game = mode == "teams"
			host.start_match(_last_args[0], _last_args[1], _last_args[2])
	var nation: int = host.join(peer, display_name, account)
	if nation >= 0:
		_mode_locked = true
	elif nation == -1:
		host.reject(peer, "match_full")


func _report_result(placements: Array) -> void:
	if not ranked and placements.is_empty():
		return
	var players := []
	for p in placements:
		if int(p.account) > 0:
			var row := {"account_id": int(p.account), "placement": int(p.placement), "survival_secs": int(p.survival_secs),
				"tile_share": snappedf(float(p.tile_share), 0.0001), "left_early": bool(p.left_early)}
			if host.team_game:
				row["team"] = int(p.get("team", 0))
			players.append(row)
	if players.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true) + "Z"
	var started := Time.get_datetime_string_from_unix_time(int(Time.get_unix_time_from_system()) - int(g.elapsed)) + "Z"
	_api("/internal/match-result", {"ranked": ranked, "team_mode": host.team_game, "map": "World", "started_at": started, "ended_at": now, "players": players},
		func(ok: bool, r: Dictionary) -> void:
			print("MPSERVER result reported ok=", ok)
			if not ok: return
			var by_account := {}
			for c in r.get("changes", []):
				by_account[int(c.get("account_id", 0))] = c
			for peer in host.peers:
				var pl: Dictionary = host.peers[peer]
				var ch: Dictionary = by_account.get(int(pl.get("account", 0)), {})
				if ch.is_empty():
					continue
				var place := 0
				for q in placements:
					if int(q.account) == int(pl.account): place = int(q.placement)
				host.send.call(peer, host._pack(host.S_RESULT, {"placement": place, "elo_before": int(ch.elo_before), "elo_after": int(ch.elo_after), "ranked": ranked})))
