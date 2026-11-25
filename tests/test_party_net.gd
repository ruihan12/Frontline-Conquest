extends SceneTree
# Party hub over real WebSockets: net/party_service.gd on a listening NetTransport, three PartyNetModel clients.

const Transport := preload("res://net/transport.gd")
const Service := preload("res://net/party_service.gd")
const Host := preload("res://net/mp_host.gd")
const Model := preload("res://net/party_net_model.gd")

var fails := 0
var srv
var svc
var clients: Array = []
var gos := {}


func _check(ok: bool, message: String) -> void:
	if not ok:
		fails += 1
		print("FAIL ", message)


func _initialize() -> void:
	create_timer(30).timeout.connect(func() -> void:
		print("PARTY_NET_TEST FAIL timeout")
		quit(1))
	_run.call_deferred()


func _pump(frames: int) -> void:
	for i in frames:
		srv.poll()
		for c in clients:
			c.poll(0.05)
		await create_timer(0.02).timeout


func _until(cond: Callable, what: String) -> void:
	for i in 150:
		await _pump(1)
		if cond.call():
			return
	_check(false, "timeout: " + what)


func _run() -> void:
	srv = Transport.new()
	_check(srv.listen_ws(18091, "127.0.0.1") == OK, "listen")
	svc = Service.new(func(peer: int, t: int, payload) -> void: srv.send(peer, Host._pack(t, payload)))
	srv.peer_disconnected.connect(func(id: int) -> void: svc.peer_left(id))
	srv.packet.connect(func(id: int, data: PackedByteArray) -> void:
		if data.size() > 1 and data[0] == Host.C_PARTY:
			svc.on_message(id, bytes_to_var(data.slice(1))))
	for nm in ["Ann", "Bob", "Cy"]:
		var m := Model.new(null, "ws://127.0.0.1:18091", nm)
		m.go.connect(func(key: String, ranked: bool) -> void: gos[nm] = [key, ranked])
		clients.append(m)
		m.connect_hub()
	var a = clients[0]
	var b = clients[1]
	var c = clients[2]
	await _until(func() -> bool: return a.online and b.online and c.online, "all online")
	await _until(func() -> bool: return a.online_players().size() == 2, "Ann sees two players")
	_check(a.code().length() == 6 and a.code() != b.code(), "unique 6-char codes")
	_check(not a.in_party(), "alone")
	var bob_uid := -1
	for p in a.online_players():
		if p.name == "Bob":
			bob_uid = p.uid
	b.set_display_name("Bobby")
	await _until(func() -> bool: return a.online_players().any(func(p): return p.name == "Bobby"), "renamed player appears")
	a.act("invite", bob_uid)
	await _until(func() -> bool: return b.state().invites.size() == 1, "Bob sees the invite")
	b.act("accept", int(b.state().invites[0].uid))
	await _until(func() -> bool: return a.in_party() and b.in_party(), "party of two")
	_check(a.is_leader() and not b.is_leader(), "Ann leads")
	_check(a.online_players().size() == 1, "Ann's list drops Bob")
	var key: String = svc.party.key_of(int(a.local_id()))
	var host := Host.new(null, Callable())
	host.max_humans = 2
	host.party_size = svc.size_for_key
	host.peers[1] = {}
	_check(not host._admit_party(key), "entire party is refused with one seat remaining")
	host.peers.clear()
	_check(host._admit_party(key) and not host._admit_party(""), "reserved party seats cannot be taken by solo joins")
	svc.match_joined(12345, key)
	await _until(func() -> bool: return c.online_players().is_empty(), "busy party hidden from invite list")
	svc.match_left(12345)
	await _until(func() -> bool: return c.online_players().size() == 2, "party can be invited again")
	c.join_code(a.code())
	await _until(func() -> bool: return a.state().members.size() == 3, "Cy joins by code")
	c.join_code("ZZZZZZ")
	var notes := []
	c.notice.connect(func(t: String) -> void: notes.append(t))
	await _pump(10)
	_check(notes.size() == 1 and notes[0].contains("No party"), "bad code refused (%s)" % str(notes))
	# a follower cannot send everyone in; the leader can
	b.request_go(false)
	await _pump(10)
	_check(gos.is_empty(), "follower go ignored")
	a.request_go(true)
	await _until(func() -> bool: return gos.size() == 3, "go reaches all three")
	_check(gos["Ann"][0] == gos["Bob"][0] and gos["Bob"][0] == gos["Cy"][0] and gos["Ann"][0] != "" and gos["Ann"][1] == true, "same key, ranked flag")
	_check(svc.key_alive(gos["Ann"][0]) and not svc.key_alive("nope"), "key checked by the server")
	a.act("kick", int(c.local_id()))
	await _until(func() -> bool: return a.state().members.size() == 2, "kick")
	a.act("leave")
	await _until(func() -> bool: return not a.in_party() and not b.in_party(), "leader leaves: the pair dissolves")
	# disconnect cleanup
	c.close_hub()
	await _until(func() -> bool: return a.online_players().size() == 1, "Cy gone from the list")
	print("PARTY_NET_TEST ", "PASS" if fails == 0 else "FAIL %d" % fails)
	quit(1 if fails > 0 else 0)
