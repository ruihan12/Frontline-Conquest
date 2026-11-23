# Port of src/client/Map/FrontLayer.luau: troop counts on the local player's fronts.
# Every 200 ms, for each attack by the local player on another owner (blue #3fa9f5; never
# wilderness / expansion) and each attack on the local player by a player or nation, not a tribe
# (red #f87171), the front is split into 8-connected clusters; the two largest (clusters under 30
# full-size tiles dropped, the largest always kept) get a label with the attack's troops at the
# front tile nearest the cluster's centroid. Labels glide to new positions over 250 ms (snap
# beyond 200 full-size tiles) and keep a constant on-screen size: Rubik Bold 17 px, a 1.5 px black
# stroke, no background.
#
# The front: the client has no frontier, so it uses the local player's border tiles that touch the
# other owner (here the game's border sets).
# (Moved here from main.gd / game/state.gd, where this port first lived.)
class_name FrontLayer
extends Control

const POLL_S := 0.2
const ANIM_S := 0.25
const SNAP_FULL := 200.0
const MIN_CLUSTER_FULL := 30.0
const MAX_CLUSTERS := 2
const OUT := Color(0x3f / 255.0, 0xa9 / 255.0, 0xf5 / 255.0)
const IN := Color(0xf8 / 255.0, 0x71 / 255.0, 0x71 / 255.0)
const TEXT_PX := 17.0
const STROKE_PX := 1.5

var g  # main.gd
## aid -> {text, incoming, slots: [{sx, sy, dx, dy, t0}]}
var entries := {}
var _next := 0.0
var _font: Font


func _init(main) -> void:
	g = main
	name = "Fronts"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_font = UITheme.font(700.0)


static func now_s() -> float:
	return Time.get_ticks_msec() / 1000.0


## The (at most two) clusters of `tiles` worth a label: [{size, x, y}], largest first.
func clusters_of(tiles: Array, min_size: float) -> Array:
	var W: int = g.W
	var H: int = g.H
	var in_set := {}
	for t in tiles:
		in_set[t] = true
	var seen := {}
	var out := []
	for start in tiles:
		if seen.has(start):
			continue
		seen[start] = true
		var members := [start]
		var head := 0
		var sx := 0.0
		var sy := 0.0
		while head < members.size():
			var t: int = members[head]
			head += 1
			var x := t % W
			@warning_ignore("integer_division")
			var y := t / W
			sx += x
			sy += y
			for dy in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					if dx == 0 and dy == 0:
						continue
					var nx: int = x + dx
					var ny: int = y + dy
					if nx < 0 or nx >= W or ny < 0 or ny >= H:
						continue
					var n: int = ny * W + nx
					if in_set.has(n) and not seen.has(n):
						seen[n] = true
						members.append(n)
		var cx := sx / members.size()
		var cy := sy / members.size()
		var best: int = members[0]
		var bd := INF
		for t2: int in members:
			@warning_ignore("integer_division")
			var d := pow(t2 % W - cx, 2) + pow(t2 / W - cy, 2)
			if d < bd:
				bd = d
				best = t2
		@warning_ignore("integer_division")
		out.append({"size": members.size(), "x": best % W, "y": best / W})
	out.sort_custom(func(a, b): return a.size > b.size)
	var kept := []
	for c in out:
		if kept.size() >= MAX_CLUSTERS:
			break
		if kept.is_empty() or c.size >= min_size:
			kept.append(c)
	return kept


func _set_slots(e: Dictionary, pts: Array, now: float, snap: float) -> void:
	var olds: Array = e.slots
	# two labels: keep each where it is closest (swap the pairing if that is shorter)
	if olds.size() == 2 and pts.size() == 2:
		var c0 := _cur(olds[0], now)
		var c1 := _cur(olds[1], now)
		var p0 := Vector2(pts[0].x, pts[0].y)
		var p1 := Vector2(pts[1].x, pts[1].y)
		if c0.distance_to(p1) + c1.distance_to(p0) < c0.distance_to(p0) + c1.distance_to(p1):
			pts = [pts[1], pts[0]]
	var slots := []
	for i in pts.size():
		var dst := Vector2(pts[i].x, pts[i].y)
		if i < olds.size():
			var cur := _cur(olds[i], now)
			var old_dst := Vector2(olds[i].dx, olds[i].dy)
			if old_dst == dst:
				slots.append(olds[i])
				continue
			if cur.distance_to(dst) > snap:
				cur = dst
			slots.append({"sx": cur.x, "sy": cur.y, "dx": dst.x, "dy": dst.y, "t0": now})
		else:
			slots.append({"sx": dst.x, "sy": dst.y, "dx": dst.x, "dy": dst.y, "t0": now})
	e.slots = slots


static func _cur(sl: Dictionary, now: float) -> Vector2:
	var f := clampf((now - float(sl.t0)) / ANIM_S, 0.0, 1.0)
	return Vector2(sl.sx, sl.sy).lerp(Vector2(sl.dx, sl.dy), f)


func poll(now: float) -> void:
	var me: int = g.PLAYER
	if g.state != "play" or g.nations.size() <= me or g.border.size() <= me or g.nations[me].land <= 0:
		entries.clear()
		return
	var todo := {}  # aid -> [other owner, incoming, troops]
	var wanted := {}
	for at in g.attacks:
		if at.get("dead", false):
			continue
		var aid: int = int(at.get("aid", -1))
		if at.a == me and at.t > 0:
			todo[aid] = [int(at.t), false, float(at.troops)]
			wanted[int(at.t)] = true
		elif at.t == me and at.a > 0 and g.kind_of(at.a) != SimRules.KIND_TRIBE:
			todo[aid] = [int(at.a), true, float(at.troops)]
			wanted[int(at.a)] = true
	for aid2 in entries.keys():
		if not todo.has(aid2):
			entries.erase(aid2)
	if todo.is_empty():
		return
	# fronts by owner: our border tiles with a 4-neighbour owned by a wanted owner (first hit counts)
	var W: int = g.W
	var H: int = g.H
	var own: PackedInt32Array = g.owner_map
	var by_owner := {}
	for t: int in g.border[me]:
		var x: int = t % W
		var hit := -1
		if x > 0 and wanted.has(own[t - 1]):
			hit = own[t - 1]
		elif x < W - 1 and wanted.has(own[t + 1]):
			hit = own[t + 1]
		elif t >= W and wanted.has(own[t - W]):
			hit = own[t - W]
		elif t + W < W * H and wanted.has(own[t + W]):
			hit = own[t + W]
		if hit > 0:
			if not by_owner.has(hit):
				by_owner[hit] = []
			by_owner[hit].append(t)
	var k: float = g.sim_rules.k_lin
	var clusters := {}
	for aid3 in todo:
		var oid: int = todo[aid3][0]
		if not by_owner.has(oid):
			entries.erase(aid3)
			continue
		if not clusters.has(oid):
			clusters[oid] = clusters_of(by_owner[oid], MIN_CLUSTER_FULL / k)
		var pts: Array = clusters[oid]
		if pts.is_empty():
			entries.erase(aid3)
			continue
		var e: Dictionary = entries.get(aid3, {"slots": []})
		e.text = UITheme.fmt_troops(float(todo[aid3][2]))
		e.incoming = todo[aid3][1]
		e.oid = oid
		_set_slots(e, pts, now, SNAP_FULL / k)
		entries[aid3] = e


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var now := now_s()
	if now >= _next:
		_next = now + POLL_S
		poll(now)
	queue_redraw()


func _draw() -> void:
	var _pt0 := Time.get_ticks_usec()
	_draw_body()
	g._pf_add("fronts", Time.get_ticks_usec() - _pt0)


func _draw_body() -> void:
	if entries.is_empty():
		return
	var now := now_s()
	var ds: float = g.hud._device_scale() if g.hud and g.hud.has_method("_device_scale") else 1.0
	var fs := maxi(1, int(round(TEXT_PX / ds)))
	var stroke := maxi(1, int(round(STROKE_PX * 2.0 / ds)))
	var f := _font
	var vs := size
	var stack := {}  # (opponent, direction) -> labels drawn so far: several attacks on one front stack, not overprint
	for aid in entries:
		var e: Dictionary = entries[aid]
		var skey := int(e.get("oid", 0)) * 2 + (1 if e.incoming else 0)
		var layer: int = stack.get(skey, 0)
		stack[skey] = layer + 1
		var col: Color = IN if e.incoming else OUT
		var ts := f.get_string_size(e.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		for sl in e.slots:
			var c := _cur(sl, now)
			var sp: Vector2 = g._screen_of((c + Vector2(0.5, 0.5)) * g.TS)
			if sp.x < -40 or sp.y < -40 or sp.x > vs.x + 40 or sp.y > vs.y + 40:
				continue
			# whole pixels only: a fractional origin smears glyph edges
			var pos := Vector2(roundf(sp.x - ts.x * 0.5), roundf(sp.y + (f.get_ascent(fs) - f.get_descent(fs)) * 0.5) + float(layer) * float(fs + 2))
			draw_string_outline(f, pos, e.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, stroke, Color.BLACK)
			draw_string(f, pos, e.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
