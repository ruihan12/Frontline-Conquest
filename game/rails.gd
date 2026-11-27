extends "res://game/navy.gd"
# Rail drawing helpers, land paths and fx. The rail / train sim is in sim/rails.gd (SimRails).

# ---------- rail networks & moving gold trains (OpenFront v24+) ----------
func _is_land_tile(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < W and y < H and owner_map[y * W + x] >= 0

func _land_los(a: Vector2, b: Vector2) -> bool:
	var n := maxi(2, int(a.distance_to(b) * 2.0))
	for k in range(n + 1):
		var p := a.lerp(b, float(k) / float(n))
		if not _is_land_tile(int(p.x), int(p.y)): return false
	return true

func _bezier_on_land(p0: Vector2, pc: Vector2, p1: Vector2, steps := 24) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for m in range(steps + 1):
		var u: float = float(m) / float(steps)
		var om := 1.0 - u
		var p: Vector2 = om * om * p0 + 2.0 * om * u * pc + u * u * p1
		if not _is_land_tile(int(p.x), int(p.y)):
			return PackedVector2Array()
		pts.append(p)
	for m in range(1, pts.size()):
		if not _land_los(pts[m - 1], pts[m]):
			return PackedVector2Array()
	return pts

func _smooth_land_chain(raw: PackedVector2Array) -> PackedVector2Array:
	if raw.size() <= 2: return raw
	var pulled := PackedVector2Array([raw[0]])
	var idx := 0
	while idx < raw.size() - 1:
		var j := mini(raw.size() - 1, idx + 10)
		while j > idx + 1 and not _land_los(raw[idx], raw[j]): j -= 1
		pulled.append(raw[j]); idx = j
	var pts := pulled
	for _it in 3:
		if pts.size() < 3: break
		var np := PackedVector2Array([pts[0]])
		for m in pts.size() - 1:
			var p0: Vector2 = pts[m]; var p1: Vector2 = pts[m + 1]
			var q0 := p0.lerp(p1, 0.25); var q1 := p0.lerp(p1, 0.75)
			if _land_los(p0, q0) and _land_los(q0, q1) and _land_los(q1, p1):
				np.append(q0); np.append(q1)
			else:
				np.append(p0); np.append(p1)
		np.append(pts[pts.size() - 1])
		pts = np
	return pts

func _land_bfs_points(from_t: int, to_t: int, max_visit := 26000) -> PackedVector2Array:
	if from_t == to_t:
		return PackedVector2Array([Vector2(from_t % W + 0.5, from_t / W + 0.5)])
	if bfs_par.size() != W * H:
		bfs_par.resize(W * H); bfs_stamp.resize(W * H); bfs_stamp.fill(0)
	bfs_gen += 1
	var gen := bfs_gen
	var q := PackedInt32Array([to_t])
	bfs_par[to_t] = -1; bfs_stamp[to_t] = gen
	var qi := 0
	var found := -1
	var dirs8 := [1, -1, W, -W, W + 1, W - 1, -W + 1, -W - 1]
	while qi < q.size() and qi < max_visit:
		var i: int = q[qi]; qi += 1
		if i == from_t: found = i; break
		var ix := i % W
		for d in dirs8:
			var j: int = i + d
			if j < 0 or j >= W * H or absi((j % W) - ix) > 1: continue
			if owner_map[j] >= 0 and bfs_stamp[j] != gen:
				if absi(d) != 1 and absi(d) != W:
					if owner_map[i + (j % W - ix)] < 0 or owner_map[j - (j % W - ix)] < 0: continue
				bfs_par[j] = i; bfs_stamp[j] = gen; q.append(j)
	if found < 0:
		return PackedVector2Array()
	var raw := PackedVector2Array()
	var k := found
	while k != -1:
		raw.append(Vector2(k % W + 0.5, k / W + 0.5)); k = bfs_par[k]
	return raw

func _water_crossing_spans(a: Vector2, b: Vector2) -> Array:
	# Returns [[w_start, w_end], ...] along straight line a -> b where tiles are WATER
	var spans := []
	var dist := a.distance_to(b)
	if dist < 0.5: return spans
	var steps := maxi(8, int(dist * 3.0))
	var in_water := false
	var w0 := Vector2.ZERO
	for k in range(steps + 1):
		var u: float = float(k) / float(steps)
		var p := a.lerp(b, u)
		var is_w := not _is_land_tile(int(p.x), int(p.y))
		if is_w and not in_water:
			in_water = true
			w0 = a.lerp(b, maxf(0.0, float(k - 1) / float(steps)))
		elif not is_w and in_water:
			in_water = false
			spans.append([w0, p])
	if in_water:
		spans.append([w0, b])
	return spans

func _axis_land(a: Vector2i, b: Vector2i) -> bool:
	# a->b must be horizontal or vertical; every tile on it must be land
	var d := Vector2i(signi(b.x - a.x), signi(b.y - a.y))
	var p := a
	while true:
		if not _is_land_tile(p.x, p.y): return false
		if p == b: return true
		p += d
	return true

func _land_bfs4(from_t: int, to_t: int, max_visit := 30000) -> PackedInt32Array:
	if bfs_par.size() != W * H:
		bfs_par.resize(W * H); bfs_stamp.resize(W * H); bfs_stamp.fill(0)
	bfs_gen += 1
	var gen := bfs_gen
	var q := PackedInt32Array([to_t]); bfs_par[to_t] = -1; bfs_stamp[to_t] = gen
	var qi := 0; var found := -1
	while qi < q.size() and qi < max_visit:
		var i: int = q[qi]; qi += 1
		if i == from_t: found = i; break
		var ix := i % W
		for d in [1, -1, W, -W]:
			if (d == 1 and ix == W - 1) or (d == -1 and ix == 0): continue
			var j: int = i + d
			if j < 0 or j >= W * H or owner_map[j] < 0 or bfs_stamp[j] == gen: continue
			bfs_par[j] = i; bfs_stamp[j] = gen; q.append(j)
	var out := PackedInt32Array()
	if found < 0: return out
	var k := found
	while k != -1: out.append(k); k = bfs_par[k]
	return out

# ---------- rail sim: sim/rails.gd (SimRails) since the split before Step 5b2; the old names forward there ----------
func _rail_curve(tile_a: int, tile_b: int) -> Array:
	return sim_rails.curve(tile_a, tile_b)

func _rail_neighbors(st) -> Array:
	return sim_rails.neighbors(st)

func _has_rail_link(st_a, st_b) -> bool:
	return sim_rails.has_link(st_a, st_b)

func spawn_train_from(f) -> bool:
	return sim_rails.spawn(f)

func _trains_tick() -> void:
	sim_rails.tick()

# The cached links of a station for drawing: never searches, so the picture can't change what the sim
# builds or when (the tick fills the cache: _trains_tick warms every station each second).
func _rail_neighbors_view(st) -> Array:
	if not (st.k in RAIL_KINDS) or st.get("bt", 0.0) > 0.0: return []
	var ce = _rail_nb_cache.get(st.tile)
	return ce[2] if ce != null else []

# The cached rail geometry of a station pair for drawing (never searches; [] until the tick has built it).
func _rail_curve_view(tile_a: int, tile_b: int) -> Array:
	return rail_cache.get("r%d:%d" % [mini(tile_a, tile_b), maxi(tile_a, tile_b)], [])

# _has_rail_link for drawing: the cached links only, so drawing a train never searches or spends the tick's budgets.
func _has_rail_link_view(st_a, st_b) -> bool:
	if st_a == null or st_b == null or st_a == st_b: return false
	if not is_same(struct_at.get(st_a.tile), st_a) or not is_same(struct_at.get(st_b.tile), st_b): return false
	return st_b in _rail_neighbors_view(st_a) or st_a in _rail_neighbors_view(st_b)

func _factories_covering(o: int, p: Vector2) -> Array:
	var out := []
	for f in structs:
		if f.k == 2 and f.o == o and f.get("bt", 0.0) <= 0.0:
			if Vector2(f.tile % W + 0.5, f.tile / W + 0.5).distance_to(p) <= FACTORY_RANGE: out.append(f)
	return out

func _uf_find(par: Array, x: int) -> int:
	while par[x] != x:
		par[x] = par[par[x]]; x = par[x]
	return x

func _connected_rail_stations(st) -> Array:
	return _rail_neighbors(st)

# construction, reloads and batteries run per sim tick in SimArsenal.tick (sim/arsenal.gd)
func _tick_artillery(_dt: float) -> void:
	pass

## `dt` is game time (sim_speed scaled: fallout wear, nuke blasts); `adt` is the animation clock, real time
## times the speed setting, so shell bursts, SAM blasts and floating text play at the pace of the 10 ticks/s sim.
func _tick_fx(dt: float, adt := -1.0) -> void:
	if adt < 0.0: adt = dt
	for b in ([] if fx_freeze else blasts.duplicate()):
		b.t += dt if b.get("kind", "") == "nuke" else adt
		var bdur: float = float(b.get("dur", 1.35))
		if b.t >= bdur: blasts.erase(b)
	for s2 in shells.duplicate():
		s2.t += adt
		if s2.t > 0.5: shells.erase(s2)
	for fl in floats.duplicate():
		fl.t += adt
		if fl.t > 1.4: floats.erase(fl)
	fallout_tick_t += dt
	if fallout_tick_t >= 2.0:
		var step := fallout_tick_t
		fallout_tick_t = 0.0
		# only the tiles that actually carry fallout (was a 2.87M-tile scan every 2 s -> hitch)
		var q2 := _qual() >= 2
		# (fallout_list loses a tile when it is conquered again: map.gd _set_owner)
		# fallout_t: counted down from 60 at the bomb for the glow's heat only (FalloutGlow). Upstream
		# fallout stays until the land is conquered again (SimState: no decay), so nothing is cleared here.
		for i in fallout_hot.keys():
			if i >= fallout.size() or fallout[i] != 1 or fallout_t[i] <= 0.0: fallout_hot.erase(i); continue
			fallout_t[i] = maxf(0.0, fallout_t[i] - step)
			if fallout_t[i] > 30.0 and q2: _pend_paint[i] = true; dirty = true

func _tick_notes(rdt: float) -> void:
	var ch := false
	for nt in notes.duplicate():
		nt.t += rdt
		if nt.t > 7.0: notes.erase(nt); ch = true
	if ch or not notes.is_empty(): note_box.queue_redraw()

# ---------- protagonist AI ----------
