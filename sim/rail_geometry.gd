extends RefCounted
## Pure rail searches shared by the live simulation and worker.

# Upstream SimStructures.rail_path, land only: A* on a minimap (RAIL_MINIMAP = 2 below k_lin 1.5), heuristic
# weight 2, turn penalty 3, nodes that cannot lie on a path shorter than RAIL_MAX_PATH are never searched,
# the newest of equal priorities comes out first. The path (from -> to, 4-connected) is scaled back up.
# (Replaces a 4-neighbour breadth-first search over up to 30000 tiles: ~9 ms a route, 4 routes a frame.)
static func find_path(from_t: int, to_t: int, W: int, H: int, owner_map: PackedInt32Array, k_lin: float, max_path: float) -> PackedInt32Array:
	var f := 2 if k_lin < 1.5 else 1
	var mw := (W + f - 1) / f
	var mh := (H + f - 1) / f
	var start := ((from_t / W) / f) * mw + (from_t % W) / f
	var goal := ((to_t / W) / f) * mw + (to_t % W) / f
	var sx := start % mw; var sy := start / mw
	var gx := goal % mw; var gy := goal / mw
	var limit := int(ceil(max_path / float(f))) + 2
	var out := PackedInt32Array()
	if absi(sx - gx) + absi(sy - gy) > limit: return out
	var hw := 2
	var tpen := 3
	var hp := PackedInt32Array(); var hq := PackedInt32Array(); var hn := PackedInt32Array()
	var seq := 0
	var gs := {start: 0}
	var parent := {start: -1}
	var closed := {}
	# push (binary heap on priority, then newest sequence first)
	hp.append(hw * (absi(sx - gx) + absi(sy - gy))); hq.append(0); hn.append(start)
	var expanded := 0
	var found := false
	var nbs := PackedInt32Array([0, 0, 0, 0])
	while hp.size() > 0:
		var node: int = hn[0]
		var last := hp.size() - 1
		var lp: int = hp[last]; var lq: int = hq[last]; var ln: int = hn[last]
		hp.resize(last); hq.resize(last); hn.resize(last)
		if last > 0:
			var i := 0
			while true:
				var c := i * 2 + 1
				if c >= last: break
				if c + 1 < last and (hp[c + 1] < hp[c] or (hp[c + 1] == hp[c] and hq[c + 1] > hq[c])): c += 1
				if lp < hp[c] or (lp == hp[c] and lq > hq[c]): break
				hp[i] = hp[c]; hq[i] = hq[c]; hn[i] = hn[c]
				i = c
			hp[i] = lp; hq[i] = lq; hn[i] = ln
		if closed.has(node): continue
		closed[node] = true
		if node == goal:
			found = true
			break
		expanded += 1
		if expanded > 60000: break
		var x := node % mw; var y := node / mw
		var prev: int = parent[node]
		var gn: int = gs[node]
		var nn := 0
		if y > 0: nbs[nn] = node - mw; nn += 1
		if y < mh - 1: nbs[nn] = node + mw; nn += 1
		if x > 0: nbs[nn] = node - 1; nn += 1
		if x < mw - 1: nbs[nn] = node + 1; nn += 1
		for k in nn:
			var m: int = nbs[k]
			if closed.has(m): continue
			var mx := m % mw; var my := m / mw
			if m != goal and owner_map[my * f * W + mx * f] < 0: continue  # water
			var hg := absi(mx - gx) + absi(my - gy)
			if absi(mx - sx) + absi(my - sy) + hg > limit: continue
			var c := 1
			if prev >= 0 and node - prev != m - node: c += tpen
			var ng := gn + c
			var og = gs.get(m)
			if og == null or ng < int(og):
				gs[m] = ng; parent[m] = node
				seq += 1
				# push
				var pri := ng + hw * hg
				hp.append(pri); hq.append(seq); hn.append(m)
				var j := hp.size() - 1
				while j > 0:
					var pp := (j - 1) / 2
					if hp[pp] < pri or (hp[pp] == pri and hq[pp] > seq): break
					hp[j] = hp[pp]; hq[j] = hq[pp]; hn[j] = hn[pp]
					j = pp
				hp[j] = pri; hq[j] = seq; hn[j] = m
	if not found: return out
	var mini_path := []
	var cur := goal
	while cur >= 0:
		mini_path.append(cur); cur = parent[cur]
	mini_path.reverse()
	# scale up to full tiles, 4-connected (from first, to last)
	var px := from_t % W; var py := from_t / W
	out.append(from_t)
	for mnode in mini_path:
		var tx: int = (mnode % mw) * f
		var ty: int = (mnode / mw) * f
		if mnode == goal: tx = to_t % W; ty = to_t / W
		while px != tx:
			px += signi(tx - px); out.append(py * W + px)
		while py != ty:
			py += signi(ty - py); out.append(py * W + px)
	return out

static func cache_key(tile_a: int, tile_b: int) -> String:
	return "r%d:%d" % [mini(tile_a, tile_b), maxi(tile_a, tile_b)]

static func curve(lo_t: int, hi_t: int, W: int, H: int, terrain: PackedInt32Array, k_lin: float, max_path: float) -> Array:
	var raw := find_path(lo_t, hi_t, W, H, terrain, k_lin, max_path)
	if raw.size() < 2 or float(raw.size()) >= max_path:
		return []
	var pts := PackedVector2Array()
	for t in raw:
		var v := Vector2(t % W + 0.5, t / W + 0.5)
		if pts.size() >= 1 and pts[pts.size() - 1] == v: continue
		if pts.size() >= 2:
			var u := pts[pts.size() - 2]; var w := pts[pts.size() - 1]
			if (u.x == w.x and w.x == v.x) or (u.y == w.y and w.y == v.y): pts[pts.size() - 1] = v; continue
		pts.append(v)
	if pts.size() < 2:
		return []
	var cum := PackedFloat32Array([0.0])
	for m in range(1, pts.size()): cum.append(cum[m - 1] + pts[m].distance_to(pts[m - 1]))
	return [pts, cum, []]

static func station_edges(nodes: Array, facs: Array, W: int, rmin: float, rmax: float) -> Array:
	var R2 := rmax * rmax
	var cov := []
	for nd in nodes:
		var p := Vector2(nd.tile % W + 0.5, nd.tile / W + 0.5); var l := []
		for fi in facs.size():
			if facs[fi].distance_squared_to(p) <= R2: l.append(fi)
		if nd.k == 2: l.append(-1)
		cov.append(l)
	var edges := []
	for i in nodes.size():
		if cov[i].is_empty(): continue
		var pi := Vector2(nodes[i].tile % W + 0.5, nodes[i].tile / W + 0.5)
		for j in range(i + 1, nodes.size()):
			if cov[j].is_empty(): continue
			var pj := Vector2(nodes[j].tile % W + 0.5, nodes[j].tile / W + 0.5)
			var d: float = pi.distance_to(pj)
			if d <= rmin or d > rmax: continue
			edges.append([d, i, j])
	edges.sort_custom(func(x, y): return x[0] < y[0])
	return edges

static func station_signature(nodes: Array) -> PackedInt32Array:
	var values := PackedInt32Array()
	values.resize(nodes.size() * 2)
	for i in nodes.size():
		values[i * 2] = nodes[i].tile
		values[i * 2 + 1] = nodes[i].k
	return values

# A movement prediction carries only scalar inputs and outputs. Live link
# validation and payout recipients are resolved in train order at commit.
class TrainStep:
	var time: float
	var duration: float
	var leg: int
	var stops: int
	var next_time: float
	var arrives: bool
	var next_leg: int
	var self_gold: float
	var ally_gold: float
	var other_gold: float

	func _init(train: Dictionary) -> void:
		time = train.t
		duration = train.dur
		leg = train.leg
		stops = train.stops

	func calculate() -> void:
		next_time = time + 1.0
		arrives = next_time >= duration
		if arrives:
			next_leg = leg + 1
			self_gold = SimRules.train_gold("self", stops)
			ally_gold = SimRules.train_gold("ally", stops)
			other_gold = SimRules.train_gold("other", stops)

	func matches(train: Dictionary) -> bool:
		return time == train.t and duration == train.dur and leg == train.leg and stops == train.stops

	func payout(relation: String) -> float:
		match relation:
			"self": return self_gold
			"ally": return ally_gold
			_: return other_gold
