# Replication codec (multiplayer phase 1). The host records every owner change in main.net_dirty
# (map.gd _set_owner, only while main.net_rec is on) and sends them as runs; a client replays them through
# its own _set_owner, so land counts, borders and structures' ownership stay derived exactly as in the sim.
# A snapshot is the same thing for every owned tile. Nation scalars (troops, gold, alive) ride along.
# Per-client id remap: the receiving player is always nation 1 (PLAYER is a const used about 500 times),
# so ids 1 and `my` are swapped in everything sent to that client and in every intent it sends back.
class_name NetRep
extends RefCounted


static func swap_id(id: int, my: int) -> int:
	if my <= 1 or id <= 0:
		return id
	if id == 1:
		return my
	if id == my:
		return 1
	return id


static func _put_varint(b: PackedByteArray, v: int) -> void:
	while v >= 0x80:
		b.append((v & 0x7f) | 0x80)
		v >>= 7
	b.append(v)


static func _get_varint(b: PackedByteArray, pos: Array) -> int:
	var v := 0
	var sh := 0
	var p: int = pos[0]
	while true:
		var c: int = b[p]
		p += 1
		v |= (c & 0x7f) << sh
		if c < 0x80:
			break
		sh += 7
	pos[0] = p
	return v


## Owner changes since the last call, as a compressed packet for the client whose own nation is `my`.
## Takes (and clears) main.net_dirty; tiles that changed twice are sent once with their final owner.
static func encode_changes(main, my := 1) -> PackedByteArray:
	var tiles: PackedInt32Array = main.net_dirty
	main.net_dirty = PackedInt32Array()
	return encode_tiles(main, tiles, my)


## Every owned tile (a full snapshot of territory).
static func encode_snapshot(main, my := 1) -> PackedByteArray:
	var tiles := PackedInt32Array()
	var om: PackedInt32Array = main.owner_map
	for i in om.size():
		if om[i] > 0:
			tiles.append(i)
	return encode_tiles(main, tiles, my)


static func encode_tiles(main, tiles: PackedInt32Array, my := 1) -> PackedByteArray:
	var om: PackedInt32Array = main.owner_map
	var seen := {}
	var uniq := PackedInt32Array()
	for t in tiles:
		if not seen.has(t):
			seen[t] = true
			uniq.append(t)
	uniq.sort()
	var raw := PackedByteArray()
	_put_varint(raw, uniq.size())
	var prev := 0
	for t in uniq:
		_put_varint(raw, t - prev)
		prev = t
		var o: int = om[t]
		# owner: 0 neutral, water stays -1 on both sides so only land owners travel; map to o + 1 for a varint
		_put_varint(raw, 0 if o <= 0 else swap_id(o, my))
	return raw.compress(FileAccess.COMPRESSION_DEFLATE)


## Replays a packet into `main` (a remote client). Returns the number of tiles applied.
static func apply_tiles(main, packet: PackedByteArray) -> int:
	if packet.is_empty():
		return 0
	# the uncompressed size is not stored: inflate with a generous bound (4 bytes per tile varint pair at most 8)
	var raw := packet.decompress_dynamic(64 * 1024 * 1024, FileAccess.COMPRESSION_DEFLATE)
	var pos := [0]
	var n := _get_varint(raw, pos)
	var t := 0
	for _k in n:
		t += _get_varint(raw, pos)
		var o := _get_varint(raw, pos)
		main._set_owner(t, o)
	return n


## Nation scalars for the client whose nation is `my`: [{id, troops, gold, alive}].
static func encode_nations(main, my := 1) -> PackedByteArray:
	var out := []
	for id in range(1, main.nations.size()):
		var nn: Dictionary = main.nations[id]
		out.append([swap_id(id, my), float(nn.get("troops", 0.0)), float(nn.get("gold", 0.0)), bool(nn.get("alive", true))])
	return var_to_bytes(out).compress(FileAccess.COMPRESSION_DEFLATE)


static func apply_nations(main, packet: PackedByteArray) -> void:
	var raw := packet.decompress_dynamic(16 * 1024 * 1024, FileAccess.COMPRESSION_DEFLATE)
	var arr: Array = bytes_to_var(raw)
	for e in arr:
		var id: int = e[0]
		if id < main.nations.size():
			var nn: Dictionary = main.nations[id]
			nn.troops = e[1]
			nn.gold = e[2]
			nn.alive = e[3]
