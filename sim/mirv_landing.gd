extends RefCounted
## Shared seeded target selection and flight plans for a missile bus.

static func _cell(tile: int, width: int, gap: int) -> int:
	return ((tile / width) / gap) * 65536 + ((tile % width) / gap)

static func _overlaps(grid: Dictionary, tile: int, width: int, gap: int) -> bool:
	var gx := (tile % width) / gap
	var gy := (tile / width) / gap
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if gx + dx < 0 or gy + dy < 0:
				continue
			var cell = grid.get((gy + dy) * 65536 + gx + dx)
			if cell == null:
				continue
			for previous: int in cell:
				if absi(previous % width - tile % width) + absi(previous / width - tile / width) < gap:
					return true
	return false

static func prepare(missile: Dictionary, width: int, height: int, owners: PackedInt32Array,
		land: PackedInt32Array, rules: SimRules, rng: RandomNumberGenerator, speed: float) -> Array:
	var to: Vector2 = missile.to
	var tile := int(to.y) * width + int(to.x)
	var target: int = missile.get("tgt_o", 0)
	var spread := rules.mirv_spread()
	var squared := spread * spread
	var gap := ceili(55.0 / rules.k_lin)
	var targets := [tile]
	var grid := {}
	grid[_cell(tile, width, gap)] = [tile]
	var count := land.size()
	var x := tile % width
	var y := tile / width
	for _i in 8000:
		if targets.size() >= SimRules.MIRV_WARHEADS or count == 0:
			break
		var candidate := land[rng.randi() % count]
		if owners[candidate] != target or target <= 0:
			continue
		var dx := candidate % width - x
		var dy := candidate / width - y
		if float(dx * dx + dy * dy) > squared or _overlaps(grid, candidate, width, gap):
			continue
		targets.append(candidate)
		var key := _cell(candidate, width, gap)
		if not grid.has(key):
			grid[key] = []
		grid[key].append(candidate)
	var origin := SimArsenal.tpos(tile, width)
	var result := []
	for destination: int in targets:
		var point := SimArsenal.tpos(destination, width)
		var arc: Dictionary = rules.nuke_arc(height, origin, point)
		var ticks := maxi(1, ceili(float(rules.nuke_arc_ticks(arc, SimRules.N_WARHEAD)) / speed))
		result.append([origin, point, ticks + rng.randi_range(0, 15), arc])
	return result
