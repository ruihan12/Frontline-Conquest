# Port of src/client/Map/RoadLayer.luau: railroads on the 2D map.
# Every railroad follows its tile path and fades in over FADE_RANGE up to zoom MIN_ZOOM (device px per
# full-size tile). Zoomed out it is a line a full-size tile wide along the path's centre (the path's
# straight runs); zoomed in (from DETAIL_ZOOM) a detailed track: each tile a 3 x 3 grid, two rails
# along its sides and a tie between them, a turn's tile its own piece (rail_kinds), the track a tile
# image (assets/rw/rails) along each straight stretch and one per turn.
# Coloured by the land under them: grey on unclaimed land, a light rail on the local player's land
# (dark over light territory) and the owner's border colour elsewhere; recoloured every RECOLOR_S.
#
# (Upstream pools GUI bars; here everything is drawn onto the map overlay each frame. The game finds
# its rails as Manhattan paths between structures (game/rails.gd, rail_cache); this layer expands each
# to its tiles. game/planes_fx.gd hands it the edges it found.)
class_name RoadLayer
extends RefCounted

const MIN_ZOOM := 3.0
const FADE_RANGE := 2.0
const DETAIL_ZOOM := 6.0
const THICKNESS := 1.0
const DEVICE_RATIO := 1.0
const RUN_MAX := 12
const RECOLOR_S := 0.5
const UNOWNED := Color(0.75, 0.75, 0.75)
const LIGHT := Color8(0xE6, 0xE6, 0xE6)
const DARK := Color(0, 0, 0)
const LIGHT_ABOVE := 0.8
const BORDER_DARKEN := 0.125
## a tile's rail kind
const H := 0
const V := 1
const TL := 2
const TR := 3
const BL := 4
const BR := 5
const KIND_ART := ["h", "v", "tl", "tr", "bl", "br"]
const ART_CELL := 24.0

var g  # main.gd
var _art: Array = []
## "lo:hi" -> {src: the game's rail curve (identity check), runs, pieces, bbox_runs, bbox_pieces}
var _roads := {}
var _recolor_at := -1.0


func _init(main) -> void:
	g = main
	for n in KIND_ART:
		_art.append(g._tex("rw/rails/%s.png" % n, 4))


# ---------------------------------------------------------------------------------------------
# Geometry (static: the tile paths)
# ---------------------------------------------------------------------------------------------

## The straight runs of a tile path (at most run_max tiles each): [{x0,y0,x1,y1,mid}].
static func build_runs(tiles: PackedInt32Array, w: int, run_max: int) -> Array:
	var runs := []
	var n := tiles.size()
	if n == 0:
		return runs
	if n == 1:
		var t := tiles[0]
		runs.append({"x0": t % w, "y0": t / w, "x1": t % w, "y1": t / w, "mid": t})
		return runs
	var i0 := 0
	while i0 < n - 1:
		var a := tiles[i0]
		var b := tiles[i0 + 1]
		var dx := b % w - a % w
		var dy := b / w - a / w
		var j := i0 + 1
		while j < n - 1 and j - i0 < run_max:
			var c := tiles[j]
			var d := tiles[j + 1]
			if d % w - c % w != dx or d / w - c / w != dy:
				break
			j += 1
		var s := tiles[i0]
		var e := tiles[j]
		runs.append({"x0": s % w, "y0": s / w, "x1": e % w, "y1": e / w, "mid": tiles[(i0 + j) / 2]})
		i0 = j
	return runs


static func _extremity(t: int, n: int, w: int) -> int:
	var dx := n % w - t % w
	var dy := n / w - t / w
	if dx == 0:
		return V
	elif dy == 0:
		return H
	return V


static func _direction(p: int, c: int, n: int, w: int) -> int:
	var dx1 := c % w - p % w
	var dy1 := c / w - p / w
	var dx2 := n % w - c % w
	var dy2 := n / w - c / w
	if dx1 == dx2 and dy1 == dy2:
		return H if dx1 != 0 else V
	if (dx1 == 0 and dx2 != 0) or (dx1 != 0 and dx2 == 0):
		if dx1 == 0 and dx2 == 1 and dy1 == -1:
			return BR
		elif dx1 == 0 and dx2 == -1 and dy1 == -1:
			return BL
		elif dx1 == 0 and dx2 == 1 and dy1 == 1:
			return TR
		elif dx1 == 0 and dx2 == -1 and dy1 == 1:
			return TL
		elif dx1 == 1 and dx2 == 0 and dy2 == -1:
			return TL
		elif dx1 == -1 and dx2 == 0 and dy2 == -1:
			return TR
		elif dx1 == 1 and dx2 == 0 and dy2 == 1:
			return BL
		elif dx1 == -1 and dx2 == 0 and dy2 == 1:
			return BR
	return V


## The kind of every tile of a path.
static func rail_kinds(tiles: PackedInt32Array, w: int) -> PackedInt32Array:
	var n := tiles.size()
	var kinds := PackedInt32Array()
	kinds.resize(n)
	kinds.fill(V)
	if n >= 2:
		kinds[0] = _extremity(tiles[0], tiles[1], w)
		for i in range(1, n - 1):
			kinds[i] = _direction(tiles[i - 1], tiles[i], tiles[i + 1], w)
		kinds[n - 1] = _extremity(tiles[n - 1], tiles[n - 2], w)
	return kinds


## The detailed track: a straight stretch of tiles of one kind side by side is one piece (at most
## run_max tiles), each turn a piece of its own: [{x0,y0,x1,y1,kind,mid}].
static func build_pieces(tiles: PackedInt32Array, w: int, run_max: int) -> Array:
	var kinds := rail_kinds(tiles, w)
	var pieces := []
	var cur: Dictionary = {}
	var lx := 0
	var ly := 0
	for i in tiles.size():
		var t := tiles[i]
		var x := t % w
		var y := t / w
		var k := kinds[i]
		if not cur.is_empty() and cur.kind == k and cur.n < run_max and ((k == H and y == ly and absi(x - lx) == 1) or (k == V and x == lx and absi(y - ly) == 1)):
			cur.x0 = mini(cur.x0, x)
			cur.x1 = maxi(cur.x1, x)
			cur.y0 = mini(cur.y0, y)
			cur.y1 = maxi(cur.y1, y)
			cur.n += 1
		else:
			cur = {"x0": x, "y0": y, "x1": x, "y1": y, "kind": k, "n": 1}
			pieces.append(cur)
		lx = x
		ly = y
	for pc in pieces:
		pc.mid = ((pc.y0 + pc.y1) / 2) * w + (pc.x0 + pc.x1) / 2
	return pieces


## The tiles a rail curve (corner points at tile centres) passes through, in order.
static func tiles_of(pts: PackedVector2Array, w: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for m in pts.size():
		var cx := int(pts[m].x)
		var cy := int(pts[m].y)
		if m == 0:
			out.append(cy * w + cx)
			continue
		var px := int(pts[m - 1].x)
		var py := int(pts[m - 1].y)
		var sx := signi(cx - px)
		var sy := signi(cy - py)
		var x := px
		var y := py
		while x != cx or y != cy:
			x += sx
			y += sy
			out.append(y * w + x)
	return out


static func luminance(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b


# ---------------------------------------------------------------------------------------------
# Frame
# ---------------------------------------------------------------------------------------------

func _road(a: int, b: int, now: float) -> Dictionary:
	var lo := mini(a, b)
	var hi := maxi(a, b)
	var key := (lo << 22) | hi  # (an int key: a string key per edge per frame was a lot of garbage)
	var r = _roads.get(key)
	# the game's curve is re-checked twice a second, not every frame
	if r != null and now - float(r.chk) < RECOLOR_S:
		return r
	var rc: Array = g._rail_curve(lo, hi)
	if rc.is_empty():
		_roads.erase(key)
		return {}
	if r == null or not is_same(r.src, rc):
		var tiles := tiles_of(rc[0], g.W)
		var w: int = g.W
		var x0 := 1 << 30
		var y0 := 1 << 30
		var x1 := -1
		var y1 := -1
		for t in tiles:
			x0 = mini(x0, t % w)
			x1 = maxi(x1, t % w)
			y0 = mini(y0, t / w)
			y1 = maxi(y1, t / w)
		r = {"src": rc, "tiles": tiles, "runs": build_runs(tiles, w, RUN_MAX), "pieces": build_pieces(tiles, w, RUN_MAX), "bb": Rect2(x0 - 1, y0 - 1, x1 - x0 + 3, y1 - y0 + 3)}
		_roads[key] = r
	r["chk"] = now
	return r


func _colour(item: Dictionary, now: float, me_col: Color, recolor: bool) -> Color:
	if recolor or not item.has("col"):
		var own: int = g.owner_map[int(item.mid)]
		var c: Color
		if own <= 0:
			c = UNOWNED
		elif own == g.PLAYER:
			c = me_col
		else:
			c = StructureLayer.border_color(g.nations[own].color)
		item["col"] = c
	return item.col


## Draws the railroads between the given tile pairs ([[tile_a, tile_b], ...]).
func draw(ci: CanvasItem, edges: Array) -> void:
	var k: float = maxf(0.01, float(g.sim_rules.k_lin))
	var ppt: float = g.cam.zoom.x * g.TS  # screen px per map tile
	var zoom := ppt / k * DEVICE_RATIO
	var a := clampf((zoom - (MIN_ZOOM - FADE_RANGE)) / FADE_RANGE, 0.0, 1.0)
	if a <= 0.01:
		return
	var now := FrameClock.now()
	var recolor := now - _recolor_at >= RECOLOR_S
	if recolor:
		_recolor_at = now
	var detail := zoom >= DETAIL_ZOOM
	var thick := THICKNESS * ppt / k
	var line_a := a
	if thick < 1.0 / DEVICE_RATIO:
		line_a = a * thick * DEVICE_RATIO
		thick = 1.0 / DEVICE_RATIO
	var me_col := LIGHT
	if g.PLAYER > 0 and g.PLAYER < g.nations.size():
		me_col = DARK if luminance(g.nations[g.PLAYER].color) > LIGHT_ABOVE else LIGHT
	var vp: Vector2 = g.get_viewport_rect().size
	var w: int = g.W
	# the visible part of the map in tiles: a road wholly outside it is skipped
	var vis: Rect2 = g.get_canvas_transform().affine_inverse() * Rect2(Vector2.ZERO, vp)
	vis = Rect2(vis.position / g.TS, vis.size / g.TS)
	for e in edges:
		var r := _road(int(e[0]), int(e[1]), now)
		if r.is_empty():
			continue
		if not vis.intersects(r.bb):
			continue
		if detail:
			for pc in r.pieces:
				var tl: Vector2 = g._screen_of(Vector2(pc.x0, pc.y0) * g.TS)
				var tw: int = pc.x1 - pc.x0 + 1
				var th: int = pc.y1 - pc.y0 + 1
				if tl.x > vp.x + ppt or tl.y > vp.y + ppt or tl.x + tw * ppt < -ppt or tl.y + th * ppt < -ppt:
					continue
				var col := _colour(pc, now, me_col, recolor)
				col.a = a
				var tex: Texture2D = _art[pc.kind]
				if tex == null:
					continue
				for ty in th:
					for tx in tw:
						var dst := Rect2(tl + Vector2(tx, ty) * ppt, Vector2(ppt, ppt))
						ci.draw_texture_rect_region(tex, dst, Rect2(0, 0, ART_CELL * 4.0, ART_CELL * 4.0), col)
			continue
		for run in r.runs:
			var p0: Vector2 = g._screen_of(Vector2(run.x0 + 0.5, run.y0 + 0.5) * g.TS)
			var p1: Vector2 = g._screen_of(Vector2(run.x1 + 0.5, run.y1 + 0.5) * g.TS)
			var m := thick + 4.0
			if maxf(p0.x, p1.x) < -m or maxf(p0.y, p1.y) < -m or minf(p0.x, p1.x) > vp.x + m or minf(p0.y, p1.y) > vp.y + m:
				continue
			var col := _colour(run, now, me_col, recolor)
			col.a = line_a
			# (a run spans its end tiles' centres; half a thickness more each way closes the corners)
			var dir := p1 - p0
			var len := dir.length()
			if len > 0.0:
				dir /= len
			else:
				dir = Vector2.RIGHT
			ci.draw_line(p0 - dir * thick * 0.5, p1 + dir * thick * 0.5, col, thick, g._line_aa())
