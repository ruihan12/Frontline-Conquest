# Port of src/client/Map/WakeRoute.luau.
# A transport ship's route as a smooth line (the unit layer draws the ship and its wake along it).
#
# The sim's water paths are string-pulled: long straight legs that meet at sharp corners in open
# water, and near a coast a staircase of two-tile steps. Here:
#   1. the path is cut into straight legs that stay within TOL tiles of its tiles;
#   2. every corner is rounded: the route leaves a leg up to CORNER full-size tiles before the
#      corner (never more than half the leg) and joins the next one as far after it, along a
#      quadratic Bezier whose control point is the corner, cut into short straight pieces.
#   * The curve passes inside the corner. Where that would put it on land it is tried at half and
#     at a quarter the size, and the corner stays sharp if none fits.
#   * Each point carries how many path tiles along the route it is (`ss`), so the ship is placed by
#     the sim's own timing and reaches both ends of every curve when it would have on the legs.
#
# Indices are 0-based here (the Luau is 1-based); a route is {xs, ys, ss, n}.
class_name WakeRoute
extends RefCounted

## A straight leg may stray this far (tiles) from the path's tiles.
const TOL := 1.5
## Full-size tiles of each leg a corner's curve may take (a ship is drawn 13 wide).
const CORNER := 16.0
## Legs that turn less than this meet as they are.
const MIN_TURN := 0.03490658503988659  # 2 degrees
## One straight piece per this much turn, at least ARC_MIN and at most ARC_MAX a corner.
const ARC_STEP := 0.15707963267948966  # 9 degrees
const ARC_MIN := 3
const ARC_MAX := 12
## The smallest curve worth drawing (tiles of leg).
const MIN_CUT := 1.0


## A path as straight runs: path index pairs [a, b] (consecutive, a < b), each staying within TOL
## tiles of every tile it passes. A run ends where the path is farthest from the straight line
## (Ramer-Douglas-Peucker), so a corner of the path is a corner of the runs.
static func runs(path: PackedInt32Array, w: int) -> Array:
	var n := path.size()
	if n < 2:
		return []
	var tol2 := TOL * TOL
	var keep := PackedByteArray()
	keep.resize(n)
	keep[0] = 1
	keep[n - 1] = 1
	var stack: Array[int] = [0, n - 1]
	while not stack.is_empty():
		var b: int = stack.pop_back()
		var a: int = stack.pop_back()
		if b - a < 2:
			continue
		@warning_ignore("integer_division")
		var ax := path[a] % w
		@warning_ignore("integer_division")
		var ay := path[a] / w
		@warning_ignore("integer_division")
		var dx := path[b] % w - ax
		@warning_ignore("integer_division")
		var dy := path[b] / w - ay
		var len2 := float(dx * dx + dy * dy)
		var worst := tol2
		var at := -1
		for m in range(a + 1, b):
			var px := path[m] % w - ax
			@warning_ignore("integer_division")
			var py := path[m] / w - ay
			# squared distance to the segment a-b
			var t := clampf(float(px * dx + py * dy) / len2, 0.0, 1.0) if len2 > 0.0 else 0.0
			var ex := px - dx * t
			var ey := py - dy * t
			var d2 := ex * ex + ey * ey
			if d2 > worst:
				worst = d2
				at = m
		if at > 0:
			keep[at] = 1
			stack.append_array([a, at, at, b])
	var out := []
	var from := 0
	for i in range(1, n):
		if keep[i] == 1:
			out.append([from, i])
			from = i
	return out


## The route of `path` (tiles on a grid `w` wide; `k` = the map's k_lin, full-size tiles per tile).
## `is_water`: Callable(tile) -> bool; an invalid Callable skips the land check. Points are tile
## centres (x + 0.5, y + 0.5).
static func build(path: PackedInt32Array, w: int, k: float, is_water: Callable = Callable()) -> Dictionary:
	var np := path.size()
	if np == 0:
		return {"xs": PackedFloat32Array(), "ys": PackedFloat32Array(), "ss": PackedFloat32Array(), "n": 0}
	if np == 1:
		@warning_ignore("integer_division")
		return {"xs": PackedFloat32Array([path[0] % w + 0.5]), "ys": PackedFloat32Array([path[0] / w + 0.5]), "ss": PackedFloat32Array([0.0]), "n": 1}
	var rs := runs(path, w)
	var m := rs.size()
	# the legs' ends
	var vx := PackedFloat32Array()
	var vy := PackedFloat32Array()
	var vs := PackedFloat32Array()
	for run in rs:
		var t: int = path[run[0]]
		vx.append(t % w + 0.5)
		@warning_ignore("integer_division")
		vy.append(t / w + 0.5)
		vs.append(float(run[0]))
	var last: int = path[rs[m - 1][1]]
	vx.append(last % w + 0.5)
	@warning_ignore("integer_division")
	vy.append(last / w + 0.5)
	vs.append(float(rs[m - 1][1]))
	var xs := PackedFloat32Array([vx[0]])
	var ys := PackedFloat32Array([vy[0]])
	var ss := PackedFloat32Array([vs[0]])
	var corner := CORNER / maxf(k, 1e-6)
	var check := is_water.is_valid()
	for i in range(1, m):
		var cx := vx[i]
		var cy := vy[i]
		var ax := cx - vx[i - 1]
		var ay := cy - vy[i - 1]
		var bx := vx[i + 1] - cx
		var by := vy[i + 1] - cy
		var la := sqrt(ax * ax + ay * ay)
		var lb := sqrt(bx * bx + by * by)
		var rounded := false
		if la > 0.0 and lb > 0.0:
			var turn := acos(clampf((ax * bx + ay * by) / (la * lb), -1.0, 1.0))
			if turn >= MIN_TURN:
				var steps := clampi(ceili(turn / ARC_STEP), ARC_MIN, ARC_MAX)
				var d := minf(corner, minf(la * 0.5, lb * 0.5))
				for _try in 3:
					if d < MIN_CUT:
						break
					var x0 := cx - ax / la * d
					var y0 := cy - ay / la * d
					var x1 := cx + bx / lb * d
					var y1 := cy + by / lb * d
					var ok := true
					if check:
						for j in range(1, steps):
							var t2 := float(j) / steps
							var u := 1.0 - t2
							var px := int(floor(u * u * x0 + 2.0 * u * t2 * cx + t2 * t2 * x1))
							var py := int(floor(u * u * y0 + 2.0 * u * t2 * cy + t2 * t2 * y1))
							# on water, or on the shore beside it
							if not (is_water.call(py * w + px) or (px > 0 and is_water.call(py * w + px - 1)) or (px < w - 1 and is_water.call(py * w + px + 1)) or is_water.call((py - 1) * w + px) or is_water.call((py + 1) * w + px)):
								ok = false
								break
					if ok:
						var s0 := vs[i] - d * (vs[i] - vs[i - 1]) / la
						var s1 := vs[i] + d * (vs[i + 1] - vs[i]) / lb
						for j in range(0, steps + 1):
							var t3 := float(j) / steps
							var u2 := 1.0 - t3
							xs.append(u2 * u2 * x0 + 2.0 * u2 * t3 * cx + t3 * t3 * x1)
							ys.append(u2 * u2 * y0 + 2.0 * u2 * t3 * cy + t3 * t3 * y1)
							ss.append(s0 + (s1 - s0) * t3)
						rounded = true
						break
					d *= 0.5
		if not rounded:
			xs.append(cx)
			ys.append(cy)
			ss.append(vs[i])
	xs.append(vx[m])
	ys.append(vy[m])
	ss.append(vs[m])
	return {"xs": xs, "ys": ys, "ss": ss, "n": xs.size()}


## Where a ship `done` path tiles along the route is: [x, y, the index of the last route point at
## or before it (0 .. n - 2; the wake is the points up to it, then the ship)].
static func at(route: Dictionary, done: float) -> Array:
	var n: int = route.n
	var xs: PackedFloat32Array = route.xs
	var ys: PackedFloat32Array = route.ys
	var ss: PackedFloat32Array = route.ss
	if n == 0:
		return [0.5, 0.5, -1]
	if n == 1 or done <= ss[0]:
		return [xs[0], ys[0], 0]
	if done >= ss[n - 1]:
		return [xs[n - 1], ys[n - 1], n - 2]
	# the last point with ss <= done
	var lo := 0
	var hi := n - 1
	while hi - lo > 1:
		@warning_ignore("integer_division")
		var mid := (lo + hi) / 2
		if ss[mid] <= done:
			lo = mid
		else:
			hi = mid
	var span := ss[lo + 1] - ss[lo]
	var f := (done - ss[lo]) / span if span > 0.0 else 0.0
	return [xs[lo] + (xs[lo + 1] - xs[lo]) * f, ys[lo] + (ys[lo + 1] - ys[lo]) * f, lo]
