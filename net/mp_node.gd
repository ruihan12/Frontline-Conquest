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
		print("MPSERVER match started state=", g.state)
	transport.poll()
	if netlog and _log_t == 0.0 and not has_meta("first"):
		set_meta("first", true)
		print("NETLOG first frame dt=", dt)
	if netlog:
		_log_t += dt
		if _log_t >= 2.0:
			_log_t = 0.0
			print("NETLOG ", role, " status=", status, " state=", g.get("state"), " tick=", g.get("tick"), " peers=", server_peers.size(), " remote=", g.get("net_remote"), " land=", (g.nations[1].land if g.nations.size() > 1 else -1), " nations=", g.nations.size())
	if role == "client" and not joined and transport.is_up():
		joined = true
		connected_ok = true
		status = "connected"
		client.join(player_name)
	if autospawn and role == "client" and joined and not _spawned and g.net_remote and g.state == "pick" and g.nations.size() > 1:
		_spawned = true
		client.send_intent({"type": "spawn", "tile": g._find_spawn_tile(g.W / 2 + randi() % 200, g.H / 2)})
