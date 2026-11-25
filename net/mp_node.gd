# Glue node: owns a transport and either an MPHost (server / player host) or an MPClient (viewer), and pumps
# the transport every frame. Created by main.gd _net_boot from command-line flags:
#   server:  godot --headless --path . -- --server --port=8070 [--bots=40] [--map=0:0] [--max=8] [--enet]
#   viewer:  godot --path . -- --connect=ws://host:8070 [--name=Bob]
class_name MPNode
extends Node

const HostC = preload("res://net/mp_host.gd")
const ClientC = preload("res://net/mp_client.gd")
const TransportC = preload("res://net/transport.gd")

var g
var transport
var host
var client
var role := ""
var server_peers := {}
var joined := false
var player_name := "Player"
var connected_ok := false
var status := "idle"
signal rejected(reason: String)
signal connected
var token := ""  # client: the session token sent when joining
var api_base := "http://127.0.0.1:8071/api/v1"
var internal_key := ""
var ranked := false
var autospawn := false
var _spawned := false
var _pending := []
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
	host = HostC.new(g, func(peer: int, pkt: PackedByteArray) -> void: transport.send(peer, pkt))
	host.max_humans = max_humans
	api_base = OS.get_environment("FRONTLINE_API") if OS.has_environment("FRONTLINE_API") else api_base
	internal_key = OS.get_environment("INTERNAL_KEY")
	ranked = OS.get_environment("FRONTLINE_RANKED") == "1"
	host.ranked = ranked
	if internal_key != "":
		host.join_gate = _gate_join
		host.on_end = _report_result
	elif ranked:
		push_warning("FRONTLINE_RANKED=1 without INTERNAL_KEY: results will not be reported")
	transport.peer_connected.connect(func(id: int) -> void: server_peers[id] = true)
	transport.peer_disconnected.connect(func(id: int) -> void:
		server_peers.erase(id)
		host.leave(id))
	transport.packet.connect(func(id: int, data: PackedByteArray) -> void: host.on_message(id, data))
	_pending = [map_tab, map_i, bots]
	status = "listening on %d" % port
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
		err = transport.connect_ws(url)
	if err != OK:
		status = "connect failed (%d)" % err
		return err
	client = ClientC.new(g, func(pkt: PackedByteArray) -> void: transport.send(1, pkt))
	transport.packet.connect(func(_id: int, data: PackedByteArray) -> void: client.on_message(data))
	transport.peer_disconnected.connect(func(_id: int) -> void: status = "disconnected")
	status = "connecting"
	return OK


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
		g.set_speed_x(g.net_speed_cap)
		print("MPSERVER match started state=", g.state, " speed=", g.sim_speed / g.SPEED_BASE)
	transport.poll()
	if netlog and _log_t == 0.0 and not has_meta("first"):
		set_meta("first", true)
		print("NETLOG first frame dt=", dt)
	if netlog:
		_log_t += dt
		if _log_t >= 2.0:
			_log_t = 0.0
			print("NETLOG ", role, " status=", status, " state=", g.get("state"), " tick=", g.get("tick"), " peers=", server_peers.size(), " remote=", g.get("net_remote"), " land=", (g.nations[1].land if g.nations.size() > 1 else -1), " nations=", g.nations.size())
	if role == "client" and client != null and client.rejected != "" and status != "rejected":
		status = "rejected"
		rejected.emit(client.rejected)
	if role == "client" and not joined and transport.is_up():
		joined = true
		connected_ok = true
		status = "connected"
		connected.emit()
		client.join(player_name, token)
	if autospawn and role == "client" and joined and not _spawned and g.net_remote and g.state == "pick" and g.nations.size() > 1:
		_spawned = true
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
			host.join(peer, str(d.get("name", "")))
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
		host.join(peer, str(r.get("username", r.get("name", d.get("name", "")))), 0 if guest else int(r.get("account_id", 0))))


func _report_result(placements: Array) -> void:
	if not ranked and placements.is_empty():
		return
	var players := []
	for p in placements:
		if int(p.account) > 0:
			players.append({"account_id": int(p.account), "placement": int(p.placement), "survival_secs": int(p.survival_secs),
				"tile_share": snappedf(float(p.tile_share), 0.0001), "left_early": bool(p.left_early)})
	if players.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true) + "Z"
	var started := Time.get_datetime_string_from_unix_time(int(Time.get_unix_time_from_system()) - int(g.elapsed)) + "Z"
	_api("/internal/match-result", {"ranked": ranked, "map": "World", "started_at": started, "ended_at": now, "players": players},
		func(ok: bool, _r: Dictionary) -> void: print("MPSERVER result reported ok=", ok))
