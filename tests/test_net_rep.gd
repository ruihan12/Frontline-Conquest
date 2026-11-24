# Multiplayer replication codec: a host sim and a client main node joined by a byte pipe.
#   godot --headless --path . -s res://tests/test_net_rep.gd
extends SceneTree

const NetRep = preload("res://net/rep.gd")
var fails := 0

func _ok(cond: bool, what: String) -> void:
	if not cond:
		fails += 1
	print(("  ok   " if cond else "  FAIL ") + what)

func _init() -> void:
	var host = load("res://sim/headless_sim.gd").new(self)
	var cli = load("res://sim/headless_sim.gd").new(self)
	await host.ready_async()
	await cli.ready_async()
	host.start(0, 0, Vector2(0.5, 0.38), 40, 5e8)
	cli.start(0, 0, Vector2(0.5, 0.38), 40, 5e8)
	var hm = host.m
	var cm = cli.m
	# the client begins neutral (same map, no tribes): clear what its own start claimed
	for i in cm.owner_map.size():
		if cm.owner_map[i] > 0:
			cm._set_owner(i, 0)
	_ok(cm.nations[1].land == 0, "client starts with no territory")
	hm.net_rec = true
	hm.net_dirty = PackedInt32Array()
	var snap: PackedByteArray = NetRep.encode_snapshot(hm, 1)
	var n0: int = NetRep.apply_tiles(cm, snap)
	print("  snapshot tiles=%d bytes=%d" % [n0, snap.size()])
	NetRep.apply_nations(cm, NetRep.encode_nations(hm, 1))
	_ok(_same(hm, cm), "snapshot reproduces owner_map")
	hm.net_dirty = PackedInt32Array()
	var total := 0
	for round in 5:
		host.step(60)
		var d: PackedByteArray = NetRep.encode_changes(hm, 1)
		total += d.size()
		NetRep.apply_tiles(cm, d)
		NetRep.apply_nations(cm, NetRep.encode_nations(hm, 1))
	print("  5 rounds of 60 ticks: delta bytes=%d" % total)
	_ok(_same(hm, cm), "deltas keep owner_map identical after 300 ticks")
	_ok(hm.nations[1].land == cm.nations[1].land, "land counts match (%d)" % hm.nations[1].land)
	_ok(absf(float(hm.nations[1].troops) - float(cm.nations[1].troops)) < 0.01, "troops replicated")
	# entity lists: a structure and its fields survive the pipe, owners swapped for client nation 3
	hm._struct_add(3, 7 * hm.W + 7, 2)
	var lp: PackedByteArray = NetRep.encode_lists(hm, 1)
	NetRep.apply_lists(cm, lp)
	_ok(cm.structs.size() == hm.structs.size() and cm.structs.size() > 0, "structs replicated (%d)" % cm.structs.size())
	_ok(cm.struct_at.has(7 * cm.W + 7) and int(cm.struct_at[7 * cm.W + 7].o) == 2, "struct_at rebuilt with owner")
	_ok(cm.boats.size() == hm.boats.size() and cm.warships.size() == hm.warships.size() and cm.missiles.size() == hm.missiles.size(), "boats/warships/missiles counts match")
	NetRep.apply_lists(cm, NetRep.encode_lists(hm, 3))
	_ok(int(cm.struct_at[7 * cm.W + 7].o) == 2, "id 2 unchanged by swap(1,3)")
	# id remap: a client whose nation is 3 sees itself as 1 and the host's player as 3
	_ok(NetRep.swap_id(1, 3) == 3 and NetRep.swap_id(3, 3) == 1 and NetRep.swap_id(5, 3) == 5 and NetRep.swap_id(0, 3) == 0, "remap swaps 1 and my only")
	var snap3: PackedByteArray = NetRep.encode_snapshot(hm, 3)
	var raw := snap3.decompress_dynamic(64 * 1024 * 1024, FileAccess.COMPRESSION_DEFLATE)
	_ok(raw.size() > 0, "remapped snapshot decodes")
	print("NET_REP_TEST ", "PASS" if fails == 0 else "FAIL", " fails=", fails)
	host.m.queue_free(); cli.m.queue_free()
	quit(fails)

func _same(a, b) -> bool:
	var oa: PackedInt32Array = a.owner_map
	var ob: PackedInt32Array = b.owner_map
	for i in oa.size():
		var x: int = maxi(oa[i], 0) if oa[i] > 0 else (oa[i] if oa[i] < 0 else 0)
		var y: int = maxi(ob[i], 0) if ob[i] > 0 else (ob[i] if ob[i] < 0 else 0)
		if x != y:
			print("  diff at ", i, ": ", oa[i], " vs ", ob[i])
			return false
	return true
