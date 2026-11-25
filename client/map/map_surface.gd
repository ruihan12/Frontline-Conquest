# Port of src/client/Map/MapSurface.luau: the rules that paint territory over the terrain.
#   terrain    the game's own terrain colours (g.base_col, generated per map);
#   territory  owned tiles blend the owner's colour at 150/255 (saturation 0.85) over the terrain,
#              border tiles are opaque in the border colour (HSL lightness - 0.125), fallout ground
#              is opaque green noise (FalloutGlow lays the glow of fresh fallout over it).
# The rules:
#   * border tile = a 4-neighbour has another owner (off the map counts as another owner);
#   * hovered owner: fill contrast x1.25 about mid-grey, border mixed 25% to white, border thickened
#     by one tile (Chebyshev 1). The fill only for an owner of HOVER_FILL_MAX tiles or fewer: it
#     means repainting every tile;
#   * a border next to an ally is mixed 35% toward green.
# (Upstream's "defended tile" checkerboard is never switched on there either: its `defended` buffer is
# not written by anything, so it is left out. Terrain bytes, image tiles, upload bands and the paint
# queue are the game's own: game/map.gd's chunks and _pend_paint. The sweeps below feed that queue the
# way upstream's _sweep / repaint_between feed theirs.)
class_name MapSurface
extends RefCounted

const TERRITORY_ALPHA := 150
const SATURATION := 0.85
const BORDER_DARKEN := 0.125
const HIGHLIGHT_BRIGHTEN := 0.25
const FRIENDLY_TINT := 0.35
const HOVER_FILL_MAX := 30000
const SWEEP_SCAN_PER_STEP := 20000
## the most waiting for a repaint while a sweep looks for more
const PENDING_ROOM := 40000

var g  # main.gd
var hover := 0
var _hover_fill := false
## owner -> {col, fill, fill_hi, border, border_hi, border_ally, border_ally_hi}
var _pal := {}
## [{owner, fill, y, other}]
var _sweeps: Array = []


func _init(main) -> void:
	g = main


# ---------------------------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------------------------

static func rgb_to_hsl(c: Color) -> Vector3:
	var mx := maxf(c.r, maxf(c.g, c.b))
	var mn := minf(c.r, minf(c.g, c.b))
	var l := (mx + mn) / 2.0
	if mx == mn:
		return Vector3(0.0, 0.0, l)
	var d := mx - mn
	var s := d / (2.0 - mx - mn) if l > 0.5 else d / (mx + mn)
	var h: float
	if mx == c.r:
		h = (c.g - c.b) / d + (6.0 if c.g < c.b else 0.0)
	elif mx == c.g:
		h = (c.b - c.r) / d + 2.0
	else:
		h = (c.r - c.g) / d + 4.0
	return Vector3(h / 6.0, s, l)


static func _hue(p: float, q: float, t: float) -> float:
	if t < 0.0:
		t += 1.0
	elif t > 1.0:
		t -= 1.0
	if t < 1.0 / 6.0:
		return p + (q - p) * 6.0 * t
	if t < 0.5:
		return q
	if t < 2.0 / 3.0:
		return p + (q - p) * (2.0 / 3.0 - t) * 6.0
	return p


static func hsl_to_rgb(h: float, s: float, l: float) -> Color:
	if s == 0.0:
		return Color(l, l, l)
	var q := l * (1.0 + s) if l < 0.5 else l + s - l * s
	var p := 2.0 * l - q
	return Color(_hue(p, q, h + 1.0 / 3.0), _hue(p, q, h), _hue(p, q, h - 1.0 / 3.0))


## Darkened by `amount`: HSL lightness - amount.
static func darken(c: Color, amount: float) -> Color:
	var v := rgb_to_hsl(c)
	return hsl_to_rgb(v.x, v.y, maxf(0.0, v.z - amount))


static func saturate(c: Color, k: float) -> Color:
	var luma := c.r * 0.299 + c.g * 0.587 + c.b * 0.114
	return Color(luma + (c.r - luma) * k, luma + (c.g - luma) * k, luma + (c.b - luma) * k)


static func contrast(v: float, k: float) -> float:
	return clampf((v - 0.5) * k + 0.5, 0.0, 1.0)


# ---------------------------------------------------------------------------------------------
# Palette
# ---------------------------------------------------------------------------------------------

func _palette(o: int) -> Dictionary:
	var c: Color = g.nations[o].color
	var p = _pal.get(o)
	var sk = g.skin_of(o)
	var sid: String = "" if sk == null else str(sk.id)
	if p != null and p.col == c and p.sid == sid:
		return p
	var f := saturate(c, SATURATION)
	var hi_k := 1.0 + HIGHLIGHT_BRIGHTEN
	var b := darken(c, BORDER_DARKEN)
	var t := HIGHLIGHT_BRIGHTEN
	var bh := Color(b.r + (1.0 - b.r) * t, b.g + (1.0 - b.g) * t, b.b + (1.0 - b.b) * t)
	var ft := FRIENDLY_TINT
	p = {
		"col": c,
		"fill": f,
		"fill_hi": Color(contrast(f.r, hi_k), contrast(f.g, hi_k), contrast(f.b, hi_k)),
		"border": b,
		"border_hi": bh,
		"border_ally": Color(b.r * (1.0 - ft), b.g + (1.0 - b.g) * ft, b.b * (1.0 - ft)),
		"border_ally_hi": Color(bh.r * (1.0 - ft), bh.g + (1.0 - bh.g) * ft, bh.b * (1.0 - ft)),
		"sid": sid,
	}
	if sk != null:
		# an equipped skin (cosmetic crates): its secondary tiles over the territory
		var sm := CosmeticsRules.mask_of(sk)
		p["mw"] = int(sm.w)
		p["mh"] = int(sm.h)
		p["bits"] = sm.bits
		p["sc"] = int(sk.scale)
		p["fill2"] = CosmeticsRules.secondary(sk, f)
		var f2: Color = p.fill2
		p["fill2_hi"] = Color(contrast(f2.r, hi_k), contrast(f2.g, hi_k), contrast(f2.b, hi_k))
	_pal[o] = p
	return p


# Painting is synchronous: neither owner colours nor skins change during a flush.
# Resolve each owner's palette once per flush rather than once per tile.
var _flush_palettes := {}
var _painting := false

func begin_paint() -> void:
	_painting = true

func end_paint() -> void:
	_painting = false
	_flush_palettes.clear()

## The colour of tile i (terrain under its territory), opaque.
func tile_color(i: int) -> Color:
	var W: int = g.W
	var H: int = g.H
	var own: PackedInt32Array = g.owner_map
	var o: int = own[i]
	var x := i % W
	if g.fallout.size() > i and g.fallout[i] == 1 and o != g.WATER:
		# stale-nuke ground: (0.05, 0.55, 0.07) + hash noise * 0.05, opaque (the glow of fresh fallout
		# is FalloutGlow's overlay, not the ground's)
		var y := i / W
		var hash := sin(x * 12.9898 + y * 78.233) * 43758.5453
		var h := (hash - floorf(hash)) * 0.05
		return Color(0.05 + h, 0.55 + h, 0.07 + h)
	var tc: Color = g.base_col[i]
	if o <= 0:
		return tc
	var nw := own[i - 1] if x > 0 else -1
	var ne := own[i + 1] if x < W - 1 else -1
	var nn := own[i - W] if i >= W else -1
	var ns := own[i + W] if i < W * H - W else -1
	var hl := o == hover
	var border := nw != o or ne != o or nn != o or ns != o
	if not border and hl:
		# highlight thicken: Chebyshev distance 1 (the diagonals; never off the map here)
		border = own[i - W - 1] != o or own[i - W + 1] != o or own[i + W - 1] != o or own[i + W + 1] != o
	var p: Dictionary
	if _painting:
		if not _flush_palettes.has(o):
			_flush_palettes[o] = _palette(o)
		p = _flush_palettes[o]
	else:
		p = _palette(o)
	if border:
		var ally: bool = (nw > 0 and nw != o and g.allied(o, nw)) or (ne > 0 and ne != o and g.allied(o, ne)) \
			or (nn > 0 and nn != o and g.allied(o, nn)) or (ns > 0 and ns != o and g.allied(o, ns))
		if ally:
			return p.border_ally_hi if hl else p.border_ally
		return p.border_hi if hl else p.border
	var fc: Color = p.fill_hi if (hl and _hover_fill) else p.fill
	if p.has("bits"):
		var sc: int = p.sc
		var mi := (((i / W) >> sc) % int(p.mh)) * int(p.mw) + ((x >> sc) % int(p.mw))
		if p.bits[mi] == 1:
			return tc.lerp(p.fill2_hi if (hl and _hover_fill) else p.fill2, float(RWCosmetics.SECONDARY_ALPHA) / 255.0)
	return tc.lerp(fc, float(TERRITORY_ALPHA) / 255.0)


# ---------------------------------------------------------------------------------------------
# Hover and alliance repaints (the sweeps)
# ---------------------------------------------------------------------------------------------

## The pointer is over `owner`'s land (0: none): its border brightens, and its fill for a small owner.
func set_hover(owner: int) -> void:
	if owner == hover:
		return
	var old := hover
	var old_fill := _hover_fill
	hover = owner
	_hover_fill = owner > 0 and owner < g.nations.size() and int(g.nations[owner].land) <= HOVER_FILL_MAX
	if old > 0:
		_sweep(old, old_fill)
	if owner > 0:
		_sweep(owner, _hover_fill)


## `owner`'s tiles are to be repainted (all of them with `fill`, else its border and what is next to it).
func _sweep(owner: int, fill: bool, other := 0) -> void:
	if owner <= 0 or owner >= g.nations.size() or int(g.nations[owner].land) <= 0:
		return
	for job in _sweeps:
		if job.owner == owner and job.other == other:
			job.fill = job.fill or fill
			job.y = -1
			return
	_sweeps.append({"owner": owner, "fill": fill, "y": -1, "other": other})


## An alliance between a and b formed or ended: the border tiles of each where the two boxes overlap.
func repaint_between(a: int, b: int) -> void:
	if a <= 0 or b <= 0 or a == b:
		return
	_sweep(mini(a, b), false, maxi(a, b))


func pending_sweeps() -> int:
	return _sweeps.size()


## Per frame: looks for the sweeps' tiles (SWEEP_SCAN_PER_STEP a frame) and hands them to the game's
## repaint queue.
func step() -> void:
	if _sweeps.is_empty():
		return
	var W: int = g.W
	var H: int = g.H
	var own: PackedInt32Array = g.owner_map
	var scan := SWEEP_SCAN_PER_STEP
	while not _sweeps.is_empty() and scan > 0 and g._pend_paint.size() < PENDING_ROOM:
		var job: Dictionary = _sweeps[0]
		var owner: int = job.owner
		var other: int = job.other
		if owner >= g.nations.size() or (other > 0 and other >= g.nations.size()):
			_sweeps.pop_front()
			continue
		var b: Rect2i = g.nations[owner].bb
		if b.size == Vector2i.ZERO:
			_sweeps.pop_front()
			continue
		var y0 := maxi(b.position.y - 1, 0)
		var y1 := mini(b.end.y, H - 1)
		var x0 := maxi(b.position.x - 1, 0)
		var x1 := mini(b.end.x, W - 1)
		if other > 0:
			var ob: Rect2i = g.nations[other].bb
			if ob.size == Vector2i.ZERO:
				_sweeps.pop_front()
				continue
			y0 = maxi(y0, ob.position.y - 1)
			y1 = mini(y1, ob.end.y)
			x0 = maxi(x0, ob.position.x - 1)
			x1 = mini(x1, ob.end.x)
		var y := maxi(int(job.y), y0)
		var fill: bool = job.fill
		while y <= y1 and x0 <= x1 and scan > 0:
			var row := y * W
			for xx in range(x0, x1 + 1):
				var t := row + xx
				var o := own[t]
				if other > 0:
					# a border tile of either (a 4-neighbour not its own)
					if (o == owner or o == other) and ((xx > 0 and own[t - 1] != o) or (xx < W - 1 and own[t + 1] != o) or (y > 0 and own[t - W] != o) or (y < H - 1 and own[t + W] != o)):
						g._pend_paint[t] = true
				elif o == owner:
					if fill:
						g._pend_paint[t] = true
					elif _near_other(own, t, xx, y, W, H, owner):
						g._pend_paint[t] = true
			scan -= x1 - x0 + 1
			y += 1
		job.y = y
		if y > y1 or x0 > x1:
			_sweeps.pop_front()
	if not g._pend_paint.is_empty():
		g.dirty = true


## A tile of `owner` that is a border or next to one: a neighbour of the 8 that is somebody else's
## or off the map.
static func _near_other(own: PackedInt32Array, t: int, x: int, y: int, W: int, H: int, owner: int) -> bool:
	if x == 0 or y == 0 or x == W - 1 or y == H - 1:
		return true
	return own[t - 1] != owner or own[t + 1] != owner or own[t - W] != owner or own[t + W] != owner \
		or own[t - W - 1] != owner or own[t - W + 1] != owner or own[t + W - 1] != owner or own[t + W + 1] != owner


func clear() -> void:
	_sweeps.clear()
	_pal.clear()
	hover = 0
	_hover_fill = false
