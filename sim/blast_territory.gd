extends RefCounted
## Computes the territory and border changes of one blast in original fallout order.

static func prepare(tiles: PackedInt32Array, owners: PackedInt32Array, fallout_before: PackedByteArray,
		width: int, height: int, has_borders: bool) -> Dictionary:
	var fallout := fallout_before.duplicate()
	var lost := {}
	var sums := {}
	var removed := PackedInt32Array()
	var additions := {}
	var paints := PackedInt32Array()
	var snapshot := PackedInt32Array()
	var offsets := [1, -1, width, -width]
	var size := width * height
	for tile in tiles:
		var owner := owners[tile]
		if owner > 0:
			var x := tile % width
			var y := tile / width
			lost[owner] = lost.get(owner, 0) + 1
			if not sums.has(owner):
				sums[owner] = [0, 0]
			var sum: Array = sums[owner]
			sum[0] += x
			sum[1] += y
			removed.append(tile)
			removed.append(owner)
			owners[tile] = 0
			if has_borders:
				# A surviving tile gets inserted at the first adjacent neutralization.
				if x > 0 and owners[tile - 1] > 0: additions[tile - 1] = owners[tile - 1]
				if x + 1 < width and owners[tile + 1] > 0: additions[tile + 1] = owners[tile + 1]
				if y > 0 and owners[tile - width] > 0: additions[tile - width] = owners[tile - width]
				if y + 1 < height and owners[tile + width] > 0: additions[tile + width] = owners[tile + width]
		fallout[tile] = 1
		var repaint := tile * 16
		for bit in offsets.size():
			var adjacent: int = tile + offsets[bit]
			if adjacent >= 0 and adjacent < size and (owners[adjacent] > 0 or fallout[adjacent] == 1):
				repaint |= 1 << bit
		paints.append(repaint)
		snapshot.append(tile)
		snapshot.append(owners[tile])
		snapshot.append(1)
	for tile in additions.keys():
		if owners[tile] == 0:
			additions.erase(tile)
	return {"owners": owners, "fallout": fallout, "lost": lost, "sums": sums,
		"removed": removed, "additions": additions, "paints": paints, "snapshot": snapshot}
