# Packet transport over a Godot MultiplayerPeer, used without SceneMultiplayer (raw packets, no RPC):
# WebSocket for the dedicated server and web clients (nginx proxies wss://.../ws to it), ENet for LAN hosting.
# Peer id 1 is always the server. Call poll() every frame.
class_name NetTransport
extends RefCounted

signal peer_connected(id: int)
signal peer_disconnected(id: int)
signal packet(id: int, data: PackedByteArray)

var peer: MultiplayerPeer
var is_server := false
var kind := ""

const BUF := 1 << 22  # 4 MB WebSocket buffers: a full snapshot of a busy map is well below this


func listen_ws(port: int, bind := "*") -> int:
	var p := WebSocketMultiplayerPeer.new()
	p.outbound_buffer_size = BUF
	p.inbound_buffer_size = BUF
	var err := p.create_server(port, bind)
	if err == OK:
		_attach(p, true, "ws")
	return err


func connect_ws(url: String) -> int:
	var p := WebSocketMultiplayerPeer.new()
	p.outbound_buffer_size = BUF
	p.inbound_buffer_size = BUF
	var err := p.create_client(url)
	if err == OK:
		_attach(p, false, "ws")
	return err


func listen_enet(port: int, max_clients := 16) -> int:
	var p := ENetMultiplayerPeer.new()
	var err := p.create_server(port, max_clients)
	if err == OK:
		_attach(p, true, "enet")
	return err


func connect_enet(host: String, port: int) -> int:
	var p := ENetMultiplayerPeer.new()
	var err := p.create_client(host, port)
	if err == OK:
		_attach(p, false, "enet")
	return err


func _attach(p: MultiplayerPeer, server: bool, k: String) -> void:
	peer = p
	is_server = server
	kind = k
	p.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
	p.peer_connected.connect(func(id: int) -> void: peer_connected.emit(id))
	p.peer_disconnected.connect(func(id: int) -> void: peer_disconnected.emit(id))


func poll() -> void:
	if peer == null:
		return
	peer.poll()
	while peer.get_available_packet_count() > 0:
		var id := peer.get_packet_peer()
		var data := peer.get_packet()
		packet.emit(id, data)


## True once a client is connected to the server (always true for a server).
func is_up() -> bool:
	return peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func send(id: int, data: PackedByteArray) -> void:
	if peer == null:
		return
	peer.set_target_peer(id)
	peer.put_packet(data)


func disconnect_peer(id: int) -> void:
	if peer != null:
		peer.disconnect_peer(id)


func close() -> void:
	if peer != null:
		peer.close()
		peer = null
