# Port of src/client/Map/StructureLayer.luau: structure icons on the map.
#   * a plate per structure in its kind's shape (City squircle, Port disc, Factory cog, Defense
#     Post shield, SAM Launcher dome, Missile Silo bullet, Artillery diamond, Airfield runway,
#     Railgun hexagon), fill = the owner's territory colour at HSV value x0.65, rim = the border
#     colour (the territory colour for the local player) at value x0.1, a white glyph inside;
#     under construction: grey fill 198 / rim 127;
#   * size: ICON_SIZE * iconScale px, iconScale = DOT_SCALE (0.3, no glyph) when zoom <= DOTS_ZOOM,
#     zoom / GROW_ZOOM above GROW_ZOOM, else min(1, zoom / SCALE_FACTOR_OUT); per-kind shape scale;
#     zoom = device px per full-size tile (screen px per tile / k_lin * DEVICE_RATIO);
#   * level >= 2: the level number above the plate;
#   * a progress bar, 14 x 3 full-size tiles centred 6 tiles below the structure (1-tile black
#     border; fill red < 25 % < orange < 50 % < yellow < 75 % < green): construction progress, and a
#     SAM's / silo's missile readiness while missiles reload.
#
# Upstream pools GUI plates; here everything is drawn each frame onto the map overlay (main.gd
# calls draw() where its own structure loop was, so rails stay under the plates and ships over).
class_name StructureLayer
extends RefCounted

const ICON_SIZE := 30.0
const DEVICE_RATIO := 2.0
const DOTS_ZOOM := 1.2
const DOT_SCALE := 0.3
const SCALE_FACTOR_OUT := 3.0
const GROW_ZOOM := 7.0
## (Assets/MapSprites: per structure column)
const SHAPE_SCALE := [1.0, 1.0, 1.12, 1.1, 1.15, 1.3, 1.2, 1.35, 1.25]
const ICON_FILL := [0.78, 0.74, 0.74, 0.74, 0.8, 0.76, 0.82, 0.8, 0.86]
const FILL_V := 0.65
const BORDER_V := 0.1
const BORDER_DARKEN := 0.125
const CONSTRUCT_FILL := Color8(198, 198, 198)
const CONSTRUCT_BORDER := Color8(127, 127, 127)
const BAR_W := 14.0
const BAR_H := 3.0
const BAR_OFFSET_Y := 6.0
const BAR_BORDER := 1.0
const BAR_THRESHOLDS := [0.25, 0.5, 0.75]
const BAR_COLORS := [Color(0.91, 0.098, 0.098), Color(0.941, 0.478, 0.098), Color(0.792, 0.906, 0.059), Color(0.173, 0.937, 0.071)]
const BAR_MIN_PX := 10.0
const SHAPE_CELL := 112.0
const GLYPH_CELL := 64.0

var g  # main.gd
var _plates: Texture2D
var _glyphs: Texture2D
var _font: Font


func _init(main) -> void:
	g = main
	_plates = load("res://assets/rw/map_sprites/plates.png")
	_glyphs = load("res://assets/rw/map_sprites/glyphs.png")
	_font = UITheme.font(700.0)


static func value_scale(c: Color, k: float) -> Color:
	return Color.from_hsv(c.h, c.s, c.v * k, c.a)


## The border colour of a territory colour: its HSL lightness less BORDER_DARKEN.
static func border_color(c: Color) -> Color:
	var mx := maxf(c.r, maxf(c.g, c.b))
	var mn := minf(c.r, minf(c.g, c.b))
	var l := (mx + mn) / 2.0
	var s := 0.0
	var h := 0.0
	if mx != mn:
		var d := mx - mn
		s = d / (2.0 - mx - mn) if l > 0.5 else d / (mx + mn)
		if mx == c.r:
			h = (c.g - c.b) / d + (6.0 if c.g < c.b else 0.0)
		elif mx == c.g:
			h = (c.b - c.r) / d + 2.0
		else:
			h = (c.r - c.g) / d + 4.0
		h /= 6.0
	l = maxf(0.0, l - BORDER_DARKEN)
	if s == 0.0:
		return Color(l, l, l)
	var q := l * (1.0 + s) if l < 0.5 else l + s - l * s
	var p := 2.0 * l - q
	return Color(_hue(p, q, h + 1.0 / 3.0), _hue(p, q, h), _hue(p, q, h - 1.0 / 3.0))


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


## iconScale for a zoom (device px per full-size tile).
static func icon_scale(zoom: float) -> float:
	if zoom <= DOTS_ZOOM:
		return DOT_SCALE
	if zoom >= GROW_ZOOM:
		return zoom / GROW_ZOOM
	return minf(1.0, zoom / SCALE_FACTOR_OUT)


## Construction progress, or missile readiness while reloading; -1 when there is nothing to show.
## (The game keeps construction as seconds left `bt` of `bmax`; reloads as shot ticks, or as the
## cooldown `cd` of `cmax` for the port's own launchers.)
func progress(st: Dictionary, tick: int) -> float:
	var bt := float(st.get("bt", 0.0))
	if bt > 0.0:
		return clampf(1.0 - bt / maxf(0.01, float(st.get("bmax", 2.0))), 0.0, 1.0)
	var col: int = g.ST_COL.get(int(st.k), -1)
	var shots: Array = st.get("shots", [])
	var reload: int = SimRules.RELOAD_TICKS[col] if col >= 0 and col < SimRules.RELOAD_TICKS.size() else 0
	if reload > 0 and not shots.is_empty():
		var slots := maxi(1, int(st.get("level", 1)))
		var reloading := 0
		var done := 0.0
		for t in shots:
			var e := tick - int(t)
			if e < reload:
				reloading += 1
				done += maxf(0.0, e) / reload
		if reloading > 0:
			var r := clampf(float(slots - reloading) / slots + done / slots, 0.0, 1.0)
			if r < 1.0:
				return r
		return -1.0
	var cd := float(st.get("cd", 0.0))
	if cd > 0.0:
		return clampf(1.0 - cd / maxf(0.1, float(st.get("cmax", 9.0))), 0.0, 1.0)
	return -1.0


## The placement preview: structure kind `k`'s current plate and glyph at screen point `sp`, in the
## player's colours (translucent), or red when it can't be built there.
func draw_ghost(ci: CanvasItem, k: int, sp: Vector2, ok: bool) -> bool:
	if _plates == null or _glyphs == null:
		return false
	var col: int = g.ST_COL.get(k, -1)
	if col < 0:
		return false
	var scale_px: float = g.cam.zoom.x * g.TS
	var kl: float = maxf(0.01, float(g.sim_rules.k_lin))
	var base := ICON_SIZE * icon_scale(scale_px / kl * DEVICE_RATIO)
	var px := roundf(base * SHAPE_SCALE[col])
	var c := Vector2(roundf(sp.x), roundf(sp.y))
	var oc: Color = g.nations[g.PLAYER].color
	var fill_col := value_scale(oc, FILL_V) if ok else Color(0.85, 0.2, 0.2)
	var rim_col := value_scale(oc, BORDER_V) if ok else Color(0.35, 0.05, 0.05)
	fill_col.a = 0.75
	rim_col.a = 0.75
	var dst := Rect2(c - Vector2(px, px) * 0.5, Vector2(px, px))
	ci.draw_texture_rect_region(_plates, dst, Rect2(col * SHAPE_CELL, 0, SHAPE_CELL, SHAPE_CELL), rim_col)
	ci.draw_texture_rect_region(_plates, dst, Rect2(col * SHAPE_CELL, SHAPE_CELL, SHAPE_CELL, SHAPE_CELL), fill_col)
	var gs: float = px * ICON_FILL[col] / SHAPE_SCALE[col]
	ci.draw_texture_rect_region(_glyphs, Rect2(c - Vector2(gs, gs) * 0.5, Vector2(gs, gs)), Rect2(col * GLYPH_CELL, 0, GLYPH_CELL, GLYPH_CELL), Color(1, 1, 1, 0.85))
	return true


func draw(ci: CanvasItem) -> void:
	if _plates == null or _glyphs == null:
		return
	var prev_f := ci.texture_filter
	ci.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_draw_inner(ci)
	ci.texture_filter = prev_f

func _draw_inner(ci: CanvasItem) -> void:
	var k: float = maxf(0.01, float(g.sim_rules.k_lin))
	var scale_px: float = g.cam.zoom.x * g.TS
	var zoom := scale_px / k * DEVICE_RATIO
	var base := ICON_SIZE * icon_scale(zoom)
	var dots := zoom <= DOTS_ZOOM
	var ppt := scale_px / k
	var vp: Vector2 = g.get_viewport_rect().size
	var W: int = g.W
	var me: int = g.PLAYER
	var tick := int(g.ticks_done)
	for st: Dictionary in g.structs:
		var col: int = g.ST_COL.get(int(st.k), -1)
		if col < 0:
			continue
		var tile: int = st.tile
		@warning_ignore("integer_division")
		var sp: Vector2 = g._screen_of(Vector2(tile % W + 0.5, tile / W + 0.5) * g.TS)
		var size: float = base * SHAPE_SCALE[col]
		if sp.x < -size or sp.y < -size or sp.x > vp.x + size or sp.y > vp.y + size:
			continue
		var px := roundf(size)
		var c := Vector2(roundf(sp.x), roundf(sp.y))
		var building := float(st.get("bt", 0.0)) > 0.0
		var fill_col: Color
		var rim_col: Color
		if building:
			fill_col = CONSTRUCT_FILL
			rim_col = CONSTRUCT_BORDER
		else:
			var oc: Color = g.nations[int(st.o)].color
			fill_col = value_scale(oc, FILL_V)
			rim_col = value_scale(oc if int(st.o) == me else border_color(oc), BORDER_V)
		var dst := Rect2(c - Vector2(px, px) * 0.5, Vector2(px, px))
		ci.draw_texture_rect_region(_plates, dst, Rect2(col * SHAPE_CELL, 0, SHAPE_CELL, SHAPE_CELL), rim_col)
		ci.draw_texture_rect_region(_plates, dst, Rect2(col * SHAPE_CELL, SHAPE_CELL, SHAPE_CELL, SHAPE_CELL), fill_col)
		if not dots:
			var gs: float = px * ICON_FILL[col] / SHAPE_SCALE[col]
			ci.draw_texture_rect_region(_glyphs, Rect2(c - Vector2(gs, gs) * 0.5, Vector2(gs, gs)), Rect2(col * GLYPH_CELL, 0, GLYPH_CELL, GLYPH_CELL))
			var lv := int(st.get("level", 1))
			if lv >= 2:
				# a label box 0.6 plate sizes tall whose bottom sits 0.1 plate sizes below the plate's top
				var fs := maxi(6, int(px * 0.6 * 0.8))
				var txt: String = g._fmt_hud(float(lv))
				var tw := _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
				var bottom := c.y - px * 0.5 + px * 0.1
				var pos := Vector2(c.x - tw * 0.5, bottom - _font.get_descent(fs))
				ci.draw_string_outline(_font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3, Color.BLACK)
				ci.draw_string(_font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)
		var pr := progress(st, tick)
		var w := BAR_W * ppt
		if pr >= 0.0 and w >= BAR_MIN_PX:
			var h := maxf(3.0, roundf(BAR_H * ppt))
			var bw := maxf(1.0, roundf(BAR_BORDER * ppt))
			var wr := roundf(w)
			var bx := roundf(sp.x - wr / 2.0)
			var by := roundf(sp.y + BAR_OFFSET_Y * ppt)
			ci.draw_rect(Rect2(bx, by, wr, h), Color.BLACK)
			var inner := maxf(0.0, wr - 2.0 * bw)
			var ci_i := 0 if pr < BAR_THRESHOLDS[0] else (1 if pr < BAR_THRESHOLDS[1] else (2 if pr < BAR_THRESHOLDS[2] else 3))
			ci.draw_rect(Rect2(bx + bw, by + bw, roundf(pr * inner), maxf(1.0, h - 2.0 * bw)), BAR_COLORS[ci_i])
