# Port of RoWorld src/client/UI/UITheme.luau (itself a port of the original scripts/ui/ui_theme.gd).
# AIRFRONT design system: colour tokens, the 8 px spacing scale, Rubik weights, the icon cache, style
# factories and widget helpers. Everything is static so any component can use it.
#
# Godot notes:
#   * Upstream's RGBA {color, alpha} is a Godot Color again: UITheme.c(col, a) = Color(col, a).
#   * A Style is a StyleBoxFlat again (upstream's table was drawn by Widgets.StyleView).
#   * Upstream measured Rubik with glyph tables (Roblox has no synchronous text metrics). Godot has them,
#     so measure_text / text_width ask the font and the kerning tables (UITheme.luau 262-1085) are gone.
#   * Sizes are logical px on the 1600x900 design; the window's canvas_items stretch renders them, so
#     UITheme.scale stays 1.0 unless a screen scales itself.
class_name UITheme
extends RefCounted

# =============================================================================================
# Colours
# =============================================================================================

static func rgba(r: float, g: float, b: float, a: float = 1.0) -> Color:
	return Color(r, g, b, a)

# Godot's Color(col, a).
static func c(col: Color, alpha: float) -> Color:
	return Color(col.r, col.g, col.b, alpha)

static func luminance(x: Color) -> float:
	return 0.2126 * x.r + 0.7152 * x.g + 0.0722 * x.b

static func equal(a: Variant, b: Variant) -> bool:
	if a == null or b == null: return false
	var ca: Color = a; var cb: Color = b
	return absf(ca.r - cb.r) < 1e-4 and absf(ca.g - cb.g) < 1e-4 and absf(ca.b - cb.b) < 1e-4 and absf(ca.a - cb.a) < 1e-4

# --- colour tokens (same as ui_theme.gd) ------------------------------------------------------
const GLASS := Color(0.051, 0.075, 0.149, 0.84)  # #0d1326 @ 84 %
const GLASS_SOLID := Color(0.043, 0.062, 0.125, 0.96)
const GLASS_RAISED := Color(0.1, 0.13, 0.24, 0.94)
const LINE := Color(1.0, 1.0, 1.0, 0.1)
const LINE_2 := Color(1.0, 1.0, 1.0, 0.18)
const FILL := Color(1.0, 1.0, 1.0, 0.06)
const FILL_2 := Color(1.0, 1.0, 1.0, 0.11)
const TEXT := Color(0.94, 0.955, 1.0)
const TEXT_2 := Color(0.68, 0.73, 0.86)
const TEXT_3 := Color(0.48, 0.53, 0.67)
const AMBER := Color(1.0, 0.71, 0.278)  # #ffb547 primary actions
const AMBER_HI := Color(1.0, 0.8, 0.47)
const AMBER_LO := Color(0.8, 0.49, 0.13)
const CYAN := Color(0.31, 0.82, 1.0)  # info
const GREEN := Color(0.37, 0.89, 0.6)
const RED := Color(1.0, 0.33, 0.39)
# the solid SurrenderButton's fill, hover and lip
const SURRENDER_RED := Color8(222, 48, 60)
const SURRENDER_RED_HI := Color8(240, 72, 82)
const SURRENDER_RED_LO := Color8(140, 20, 32)
const ORANGE := Color(1.0, 0.58, 0.36)
const VIOLET := Color(0.72, 0.62, 1.0)
const GOLD := Color(1.0, 0.84, 0.4)
const INK := Color(0.1, 0.066, 0.02)  # text on amber
const WHITE := Color(1, 1, 1)
const BLACK := Color(0, 0, 0)
const CLEAR := Color(0, 0, 0, 0)

# --- spacing / radii (8 px scale with a 4 px half step) -----------------------------------------
const S1 := 4
const S2 := 8
const S3 := 12
const S4 := 16
const S5 := 24
const S6 := 32
const S7 := 48
const R_SM := 6
const R_MD := 10
const R_LG := 14

# Upstream (no backdrop blur in Roblox) takes the original's no-frost path: tint alpha + 0.08 plus the
# frost path's top sheen. Kept: the port draws glass the same way so the two builds match.
const GLASS_BOOST := 0.08
# Top sheen of the frosted glass (frost shader `sheen`, 0.045 when on).
const GLASS_SHEEN := 0.045

static var frost_enabled := false
# Minimum text size applied to new labels (12 on phones, 0 = off).
static var min_font_size := 0
# Current UI scale (render px per logical px).
static var scale := 1.0

# =============================================================================================
# Fonts & text metrics
# =============================================================================================

const FONT_PATH := "res://assets/fonts/Rubik-VariableFont_wght.ttf"
# Line height of Rubik in em (hhea ascender 935 + descender 250).
const LINE_EM := 1.185
# Baseline from the top of a line, in em.
const ASCENT_EM := 0.935

static var _base_font: FontFile = null
static var _fonts := {}

static func snap_weight(w: float = 500.0) -> int:
	return clampi(int(floor((w + 50.0) / 100.0)) * 100, 100, 900)

# Rubik at a weight (100..900), with letter spacing and tabular digits (the original's
# font(weight, spacing, tabular)).
static func font(weight: float = 500.0, spacing: int = 0, tabular: bool = false) -> Font:
	var w := snap_weight(weight)
	var key := "%d|%d|%d" % [w, spacing, 1 if tabular else 0]
	var f: Font = _fonts.get(key)
	if f == null:
		if _base_font == null:
			_base_font = load(FONT_PATH)
		var fv := FontVariation.new()
		fv.base_font = _base_font
		var ts := TextServerManager.get_primary_interface()
		fv.variation_opentype = {ts.name_to_tag("wght"): w}
		fv.spacing_glyph = spacing
		if tabular:
			fv.opentype_features = {ts.name_to_tag("tnum"): 1}
		f = fv
		_fonts[key] = f
	return f

# Line height in logical px of a label of font size `size` (Godot Label min height).
static func line_height(size: float) -> int:
	return ceili(size * ASCENT_EM - 1e-6) + ceili(size * (LINE_EM - ASCENT_EM) - 1e-6)

# Baseline offset in logical px from the top of a line (Godot: ceil(ascent)).
static func ascent(size: float) -> int:
	return ceili(size * ASCENT_EM - 1e-6)

static func init() -> void:
	font(500)

static func fonts_ready() -> bool:
	return true

# Width in logical px of `text` at font size `size`.
static func measure_text(text: String, size: float, weight: float = 500.0, spacing: int = 0, tabular: bool = false) -> float:
	return font(weight, spacing, tabular).get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, int(size)).x

# Width of a template string ("00:00", "100.0%"): what a fixed-width label reserves.
static func text_width(template: String, size: float, weight: float = 500.0, spacing: int = 0) -> float:
	return ceilf(measure_text(template, size, weight, spacing, true))

static func wrapped_height(text: String, size: float, weight: float, width: float) -> float:
	return font(weight).get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, width, int(size)).y

static func wrapped_lines(text: String, size: float, weight: float, width: float) -> int:
	return maxi(1, roundi(wrapped_height(text, size, weight, width) / maxf(1.0, font(weight).get_height(int(size)))))

# =============================================================================================
# Scale
# =============================================================================================

const DESIGN_W := 1600
const DESIGN_H := 900

# UI scale for a viewport (render px). The HUD is laid out in logical px on a 1600x900 design; desktop
# screens scale that design to fit (1920x1080 -> 1.2, 1366x768 -> 0.853, clamped to [0.75, 2.5]). Touch
# devices keep 1:1 points (so the phone layout rules apply) and only scale up on very large screens.
static func ui_scale(viewport: Vector2, touch_device: bool = false) -> float:
	var s := minf(viewport.x / DESIGN_W, viewport.y / DESIGN_H)
	if touch_device:
		return clampf(s, 1.0, 2.0)
	return clampf(s, 0.75, 2.5)

static func set_scale(s: float) -> void:
	scale = s

# =============================================================================================
# Icons
# =============================================================================================

# Where the white 128 px glyph masks live. Later folders win, as upstream: Assets/UiIcons, then
# ArsenalArt.ui (artillery, mega, star, lock...) for names UiIcons lacks, then MapSprites.ui (city, port,
# warship, atom...) over both, so the build bar and the menus show what the map shows (2026-10-25).
const ICON_DIRS := ["res://assets/rw/ui_icons/", "res://assets/rw/arsenal/ui/", "res://assets/rw/map_sprites/ui/"]
const CRATE_ICON := "res://assets/rw/crate/crate_icon.svg"

static var _icons: Dictionary = {}
static var _icons_built := false
static var _tex := {}

static func _build_icons() -> void:
	_icons_built = true
	for k in ICON_DIRS.size():
		var d := DirAccess.open(ICON_DIRS[k])
		if d == null: continue
		for fn in d.get_files():
			# exported builds list "<name>.png.import" instead of the source file
			var base := fn.trim_suffix(".import")
			if not base.ends_with(".png"): continue
			var name := base.trim_suffix(".png")
			if k == 1 and _icons.has(name): continue  # ArsenalArt.ui only fills gaps
			_icons[name] = ICON_DIRS[k] + base

# Path of a white UI glyph ("hud_*", "app_icon" included), or "" when the assets do not have it
# (callers degrade gracefully: no icon).
static func icon(icon_name: String) -> String:
	if icon_name == "crate":
		return CRATE_ICON
	if not _icons_built:
		_build_icons()
	return _icons.get(icon_name, "")

# The glyph as a texture (null when missing).
static func icon_texture(icon_name: String) -> Texture2D:
	if _tex.has(icon_name):
		return _tex[icon_name]
	var p := icon(icon_name)
	var t: Texture2D = load(p) if p != "" and ResourceLoader.exists(p) else null
	_tex[icon_name] = t
	return t

# =============================================================================================
# Colours by meaning
# =============================================================================================

# Core/Defs.MSG_*
const MSG_INFO := 0
const MSG_GOOD := 1
const MSG_BAD := 2
const MSG_ALERT := 3
const MSG_ALLIANCE := 4

static func msg_color(category: int) -> Color:
	match category:
		MSG_GOOD: return GREEN
		MSG_BAD: return ORANGE
		MSG_ALERT: return RED
		MSG_ALLIANCE: return VIOLET
	return CYAN

static func msg_icon(category: int) -> String:
	match category:
		MSG_GOOD: return "crown"
		MSG_BAD: return "attack"
		MSG_ALERT: return "target"
		MSG_ALLIANCE: return "alliance"
	return "info"

# A readable UI variant of a nation colour (lifted when very dark).
static func owner_ui_color(col: Color) -> Color:
	var l := luminance(col)
	if l < 0.32:
		return col.lerp(WHITE, 0.32 - l + 0.1)
	return col

# =============================================================================================
# Style factories (StyleBoxFlat)
# =============================================================================================

# --- Smooth rounded corners -------------------------------------------------------------------
# StyleBoxFlat's anti-aliasing feather (anti_aliasing_size) is in logical px, and the window's
# canvas_items stretch scales it with everything else: the old 1.2 was 1.4 render px at 1080p and
# 1.9 at 1440p, wider than a 1 px border. The feathers of the border's inner edge and of the fill's
# edge then overlap, and in the translucent colours of the HUD the overlap shows as dots and a dashed
# rim at every corner, with uneven edges. smooth() gives every box a feather of one render pixel and
# enough corner segments for the radius at the current scale, and keeps them so when the window size
# changes (on_resize).

static var _smooth_boxes: Array = []  # WeakRef(StyleBoxFlat)
static var _smooth_adds := 0
static var _smooth_hooked := false
static var _render_scale := -1.0

## Render px per logical px (the window's canvas_items stretch), 1.0 without a window.
static func render_scale() -> float:
	if _render_scale > 0.0:
		return _render_scale
	var ml = Engine.get_main_loop()
	var w: Window = ml.root if ml is SceneTree else null
	var s := 1.0
	if w != null:
		var cs := w.content_scale_size
		if cs.x > 0 and cs.y > 0 and w.size.x > 0 and w.size.y > 0:
			s = minf(float(w.size.x) / cs.x, float(w.size.y) / cs.y)
		s *= w.content_scale_factor
		if not _smooth_hooked:
			_smooth_hooked = true
			w.size_changed.connect(on_resize)
	_render_scale = maxf(0.25, s)
	return _render_scale

## The anti-aliasing feather for one render pixel (logical px).
static func aa_size() -> float:
	return clampf(1.0 / render_scale(), 0.25, 1.0)

static func _apply_smooth(s: StyleBoxFlat) -> void:
	s.anti_aliasing = true
	s.anti_aliasing_size = aa_size()
	var r := maxi(maxi(s.corner_radius_top_left, s.corner_radius_top_right), maxi(s.corner_radius_bottom_left, s.corner_radius_bottom_right))
	# (a radius past half the box is cut down when drawn: segments for a 40 px corner at most)
	s.corner_detail = clampi(int(ceil(minf(float(r), 40.0) * render_scale() * 0.75)), 8, 32)

## Anti-aliased corners one render pixel wide (see above); returns `s`.
static func smooth(s: StyleBoxFlat) -> StyleBoxFlat:
	_apply_smooth(s)
	_smooth_adds += 1
	if _smooth_adds % 512 == 0:
		_smooth_boxes = _smooth_boxes.filter(func(w: WeakRef) -> bool: return w.get_ref() != null)
	_smooth_boxes.append(weakref(s))
	return s

## The window was resized: every live box gets the feather for the new scale.
static func on_resize() -> void:
	var old := _render_scale
	_render_scale = -1.0
	if absf(render_scale() - old) < 1e-4:
		return
	var live: Array = []
	for w: WeakRef in _smooth_boxes:
		var s = w.get_ref()
		if s != null:
			_apply_smooth(s)
			live.append(w)
	_smooth_boxes = live

static var _draw_boxes := {}

## A flat() box for a _draw() that runs every frame: one box per look, not a new one each frame.
static func flat_draw(bg: Color, radius: float = R_MD, border: Variant = null, bw: int = 0) -> StyleBoxFlat:
	var key := "%s|%s|%s|%d" % [bg.to_html(), radius, (border as Color).to_html() if border != null else "-", bw]
	var s = _draw_boxes.get(key)
	if s == null:
		if _draw_boxes.size() > 2048:
			_draw_boxes.clear()
		s = flat(bg, radius, border, bw)
		_draw_boxes[key] = s
	return s

## flat(), or for a radius of 999 and up (a pill / circle) a PillBox: its radius stays just under half
## of the box it is drawn in, whatever that box's size.
static func box(bg: Color, radius: float = R_MD, border: Variant = null, bw: int = 0, mh: float = 0.0, mv: float = 0.0) -> StyleBox:
	var f := flat(bg, radius, border, bw, mh, mv)
	if radius < 999.0:
		return f
	return PillBox.new(f)

## An icon drawn from a control's _draw() pixel for pixel (CrispIcon's way): the glyph resampled to the
## device pixels `rect` covers and placed on the device pixel grid, so the canvas' nearest filter shows
## every texel once. (Drawn straight from the 128 px art, a 24 px icon was nearest-sampled at 1.2x:
## jagged, with missing strokes.) Falls back to a plain draw for a rotated / skewed canvas.
static func draw_icon(ci: CanvasItem, tex: Texture2D, rect: Rect2, modulate: Color = Color.WHITE) -> void:
	if tex == null:
		return
	var vp := ci.get_viewport()
	if vp == null:
		ci.draw_texture_rect(tex, rect, false, modulate)
		return
	var xf := vp.get_final_transform() * ci.get_global_transform_with_canvas()
	var sc := xf.get_scale()
	if absf(xf.get_rotation()) > 1e-4 or absf(sc.x - sc.y) > 1e-4 or sc.x <= 0.0:
		ci.draw_texture_rect(tex, rect, false, modulate)
		return
	var n := maxi(1, roundi(maxf(rect.size.x, rect.size.y) * sc.x))
	var t := CrispIcon._resampled(tex, n)
	if t == null:
		ci.draw_texture_rect(tex, rect, false, modulate)
		return
	var tsz := Vector2(t.get_width(), t.get_height())
	var dc := xf * rect.get_center()  # device px
	var d0 := (dc - tsz * 0.5).round()
	var inv := xf.affine_inverse()
	var p0 := inv * d0
	ci.draw_texture_rect(t, Rect2(p0, tsz / sc.x), false, modulate)

## A radius that stays under half of `extent` (a pill / circle): a StyleBoxFlat whose radii fill the
## whole side draws its two halves with overlapping feathers, a seam down the middle.
static func pill_radius(extent: float) -> int:
	return maxi(0, int(floor(extent * 0.5)) - 1)

static func flat(bg: Color, radius: float = R_MD, border: Variant = null, bw: int = 0, mh: float = 0.0, mv: float = 0.0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(int(radius))
	s.border_color = border if border != null else CLEAR
	s.set_border_width_all(bw)
	s.content_margin_left = mh
	s.content_margin_right = mh
	s.content_margin_top = mv
	s.content_margin_bottom = mv
	return smooth(s)

## A round badge behind an icon (upstream: a Frame with a full UICorner and a UIStroke). Drawn as a real
## circle: a StyleBoxFlat whose radius is half its size, in translucent colours, shows its seams (a
## dashed rim and a line down the middle where the anti-aliased pieces overlap).
static func set_disc(p: Control, fill: Color, border: Color, bw: float = 1.0) -> void:
	p.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	p.set_meta("disc", [fill, border, bw])
	if not p.has_meta("disc_hooked"):
		p.set_meta("disc_hooked", true)
		p.draw.connect(func() -> void:
			var d: Array = p.get_meta("disc")
			var c := p.size * 0.5
			var r := minf(p.size.x, p.size.y) * 0.5
			var w: float = d[2]
			p.draw_circle(c, r - w * 0.5, d[0], true, -1.0, true)
			if w > 0.0:
				p.draw_circle(c, r - w * 0.5, d[1], false, w, true))
	p.queue_redraw()

static func empty_box(mh: float = 0.0, mv: float = 0.0) -> StyleBoxEmpty:
	var s := StyleBoxEmpty.new()
	s.content_margin_left = mh
	s.content_margin_right = mh
	s.content_margin_top = mv
	s.content_margin_bottom = mv
	return s

# A soft drop shadow under a rounded box (upstream: a 9-slice blurred image, solid under the box). Draw it
# with draw_shadow(), which moves it down by `offset_y`: a StyleBoxFlat cannot offset its own centre.
static func shadow_box(radius: float, size: int = 18, alpha: float = 0.45, offset_y: float = 6.0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0, 0, 0, alpha)
	s.set_corner_radius_all(int(radius))
	s.shadow_color = Color(0, 0, 0, alpha)
	s.shadow_size = size
	s.set_meta("offset_y", offset_y)
	return smooth(s)

static func draw_shadow(ci: CanvasItem, rect: Rect2, s: StyleBoxFlat) -> void:
	# (the solid core stays under the panel: only the soft falloff shows past its edges)
	var inset := minf(float(s.shadow_size) * 0.5, minf(rect.size.x, rect.size.y) * 0.25)
	ci.draw_style_box(s, Rect2(rect.position + Vector2(0, float(s.get_meta("offset_y", 0.0))), rect.size).grow(-inset))

# Copy of a style (StyleBoxFlat.duplicate()).
static func dup(s: StyleBox) -> StyleBox:
	var d := s.duplicate()
	if d is StyleBoxFlat:
		smooth(d)
	return d

# Content margins of a style: [left, top, right, bottom].
static func margins(s: StyleBox) -> Array:
	if s == null:
		return [0.0, 0.0, 0.0, 0.0]
	return [s.get_margin(SIDE_LEFT), s.get_margin(SIDE_TOP), s.get_margin(SIDE_RIGHT), s.get_margin(SIDE_BOTTOM)]

# =============================================================================================
# Theme (button variations: normal / hover / pressed / hover_pressed / disabled styles + colours)
# =============================================================================================

static var _theme: Theme = null

static func _set_button(t: Theme, typ: String, styles: Dictionary, colors: Dictionary, weight: int, spacing: int, size: int, h_sep: int) -> void:
	if typ != "Button":
		t.set_type_variation(typ, "Button")
	for k in styles:
		t.set_stylebox(k, typ, styles[k])
	t.set_stylebox("focus", typ, StyleBoxEmpty.new())
	for k in colors:
		t.set_color(k, typ, colors[k])
	t.set_font("font", typ, font(weight, spacing))
	t.set_font_size("font_size", typ, size)
	t.set_constant("h_separation", typ, h_sep)

static func _button_styles(t: Theme, typ: String, n: Color, h: Color, p: Color, border: Color, border_h: Color, fg: Color, weight: int, radius: float = R_MD, mh: float = 16.0) -> Dictionary:
	var nbw := 1 if border.a > 0 else 0
	var hbw := 1 if border_h.a > 0 else 0
	var v := {
		"styles": {
			"normal": box(n, radius, border, nbw, mh, 8.0),
			"hover": box(h, radius, border_h, hbw, mh, 8.0),
			"pressed": box(p, radius, border_h, hbw, mh, 8.0),
			"hover_pressed": box(p, radius, border_h, hbw, mh, 8.0),
			"disabled": box(c(n, n.a * 0.5), radius, c(border, border.a * 0.5), nbw, mh, 8.0),
		},
		"colors": {
			"font_color": fg,
			"font_hover_color": TEXT,
			"font_pressed_color": TEXT,
			"font_hover_pressed_color": TEXT,
			"font_disabled_color": c(fg, 0.35),
			"icon_normal_color": fg,
			"icon_hover_color": TEXT,
			"icon_pressed_color": TEXT,
			"icon_hover_pressed_color": TEXT,
			"icon_disabled_color": c(fg, 0.35),
		},
		"font_weight": weight, "font_spacing": 1, "font_size": 15, "h_separation": 10,
	}
	return v

static func _apply(t: Theme, typ: String, v: Dictionary) -> void:
	_set_button(t, typ, v.styles, v.colors, v.font_weight, v.font_spacing, v.font_size, v.h_separation)

# A lipped solid button (Primary, Surrender): fill with a darker 3 px bottom border, pressed sinks 2 px.
static func _lipped(fill: Color, hi: Color, lo: Color) -> Dictionary:
	var pn := flat(fill, R_MD, lo, 0, 22.0, 10.0)
	pn.border_width_bottom = 3
	var ph: StyleBoxFlat = smooth(pn.duplicate())
	ph.bg_color = hi
	var pp := flat(lo.lerp(fill, 0.5), R_MD, CLEAR, 0, 22.0, 10.0)
	pp.content_margin_top = 12.0
	pp.content_margin_bottom = 8.0
	var pd := flat(Color(1, 1, 1, 0.08), R_MD, LINE, 1, 22.0, 10.0)
	return {"normal": pn, "hover": ph, "pressed": pp, "hover_pressed": pp, "disabled": pd}

# Button variations (the original's theme(): PrimaryButton, GlassButton, GhostButton, DangerButton,
# ChipButton, plus upstream's PublicButton and SurrenderButton; "Button" = glass look).
static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font = font(500)
	t.default_font_size = 15
	_apply(t, "Button", _button_styles(t, "Button", FILL, FILL_2, Color(1, 1, 1, 0.03), LINE, LINE_2, TEXT, 600))
	_apply(t, "GlassButton", _button_styles(t, "GlassButton", FILL, FILL_2, Color(1, 1, 1, 0.03), LINE, LINE_2, TEXT, 600))
	# the next public match (title): glass with a cyan accent so it stands out next to Play Solo
	_apply(t, "PublicButton", _button_styles(t, "PublicButton", c(CYAN, 0.1), c(CYAN, 0.18), c(CYAN, 0.06), c(CYAN, 0.55), c(CYAN, 0.9), TEXT, 600))
	var ghost := _button_styles(t, "GhostButton", Color(1, 1, 1, 0.0), FILL, Color(1, 1, 1, 0.03), CLEAR, CLEAR, TEXT_2, 600)
	ghost.colors.font_hover_color = TEXT
	ghost.colors.icon_hover_color = TEXT
	_apply(t, "GhostButton", ghost)
	_apply(t, "DangerButton", _button_styles(t, "DangerButton", c(RED, 0.14), c(RED, 0.26), c(RED, 0.08), c(RED, 0.45), c(RED, 0.8), Color(1.0, 0.78, 0.8), 700))
	var chip := _button_styles(t, "ChipButton", Color(1, 1, 1, 0.04), FILL_2, c(AMBER, 0.2), LINE, LINE_2, TEXT_2, 600, 999, 14.0)
	chip.styles.hover_pressed = box(c(AMBER, 0.26), 999, AMBER, 1, 14.0, 6.0)
	chip.styles.pressed = box(c(AMBER, 0.2), 999, c(AMBER, 0.9), 1, 14.0, 6.0)
	chip.colors.font_pressed_color = AMBER_HI
	chip.colors.font_hover_pressed_color = AMBER_HI
	chip.font_size = 13
	_apply(t, "ChipButton", chip)

	# Primary: warm amber with a darker lip.
	_set_button(t, "PrimaryButton", _lipped(AMBER, AMBER_HI, AMBER_LO), {
		"font_color": INK, "font_hover_color": INK, "font_pressed_color": INK, "font_hover_pressed_color": INK,
		"font_disabled_color": TEXT_3,
		"icon_normal_color": INK, "icon_hover_color": INK, "icon_pressed_color": INK, "icon_hover_pressed_color": INK,
		"icon_disabled_color": INK,
	}, 800, 2, 17, 10)
	# Surrender: solid red with a darker lip, shaped like Primary (the game menu's SURRENDER, made big and
	# red on 2026-10-19). DangerButton is only a red tint.
	_set_button(t, "SurrenderButton", _lipped(SURRENDER_RED, SURRENDER_RED_HI, SURRENDER_RED_LO), {
		"font_color": WHITE, "font_hover_color": WHITE, "font_pressed_color": WHITE, "font_hover_pressed_color": WHITE,
		"font_disabled_color": TEXT_3,
		"icon_normal_color": WHITE, "icon_hover_color": WHITE, "icon_pressed_color": WHITE, "icon_hover_pressed_color": WHITE,
		"icon_disabled_color": TEXT_3,
	}, 800, 2, 17, 10)
	_theme = t
	return t

# =============================================================================================
# Widget helpers
# =============================================================================================

static func label(text: String, size: float = 15.0, weight: float = 500.0, color: Variant = null, spacing: int = 0) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	style_label(l, size, weight, color if color != null else TEXT, spacing)
	return l

static func style_label(l: Label, size: float, weight: float = 500.0, color: Variant = null, spacing: int = 0) -> void:
	l.add_theme_font_override("font", font(weight, spacing))
	l.set_meta("base_fs", size)
	l.set_meta("weight", weight)
	l.set_meta("spacing", spacing)
	l.add_theme_font_size_override("font_size", int(maxf(size, min_font_size)))
	l.add_theme_color_override("font_color", color if color != null else TEXT)

# Small upper-case caption ("TROOPS", "GOLD"...).
static func caption(text: String, size: float = 11.0, color: Variant = null) -> Label:
	return label(text.to_upper(), size, 700, color if color != null else TEXT_3, 1)

# Only re-applies a colour that really changed.
static func set_font_color(ctl: Control, col: Color, prop: String = "font_color") -> void:
	if not ctl.has_theme_color_override(prop) or ctl.get_theme_color(prop) != col:
		ctl.add_theme_color_override(prop, col)

# Lock a label to a fixed width: it clips instead of growing its container and (tabular) draws digits
# in equal-width cells so animated numbers do not jitter.
static func fix_width(l: Label, w: float, align: int = HORIZONTAL_ALIGNMENT_LEFT, tabular: bool = true, clip: bool = true) -> void:
	l.clip_text = clip
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING if (tabular or not clip) else TextServer.OVERRUN_TRIM_ELLIPSIS
	l.custom_minimum_size.x = w
	l.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	l.horizontal_alignment = align
	if tabular:
		# the original swaps in font(weight, 0, tabular): tabular labels lose their letter spacing
		l.add_theme_font_override("font", font(float(l.get_meta("weight", 500.0)), 0, true))

static func icon_rect(icon_name: String, px: float, color: Variant = null) -> TextureRect:
	# (CrispIcon: the glyph resampled to the device pixels it covers, drawn 1:1)
	var r := CrispIcon.new()
	r.setup(icon_texture(icon_name), px)
	r.modulate = color if color != null else TEXT
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r

static func hbox(sep: int = S2) -> HBoxContainer:
	var b := HBoxContainer.new()
	b.add_theme_constant_override("separation", sep)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return b

static func vbox(sep: int = S1) -> VBoxContainer:
	var b := VBoxContainer.new()
	b.add_theme_constant_override("separation", sep)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return b

# Button in one of the theme variations: PrimaryButton, GlassButton, GhostButton, DangerButton,
# ChipButton, PublicButton, SurrenderButton.
static func button(text: String, variation: String = "GlassButton", icon_name: String = "", min_h: float = 44.0) -> Button:
	var b := Button.new()
	b.theme = theme()
	b.theme_type_variation = variation
	b.text = text
	b.custom_minimum_size = Vector2(0, min_h)
	b.focus_mode = Control.FOCUS_NONE
	if icon_name != "":
		b.icon = icon_texture(icon_name)
		b.expand_icon = false
		b.add_theme_constant_override("icon_max_width", 20)
	return b

# A thin vertical divider line.
static func vdivider(h: float = 36.0) -> ColorRect:
	var d := ColorRect.new()
	d.color = LINE
	d.custom_minimum_size = Vector2(1.0, h)
	d.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return d

static func hdivider() -> ColorRect:
	var d := ColorRect.new()
	d.color = LINE
	d.custom_minimum_size = Vector2(0.0, 1.0)
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return d

# Rounded colour swatch (nation colour chip).
static func swatch(col: Color, px: float = 12.0, radius: float = 3.0) -> PanelContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(px, px)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", flat(col, radius, Color(1, 1, 1, 0.35), 1))
	return p

static func set_swatch_color(p: PanelContainer, col: Color) -> void:
	var sb := p.get_theme_stylebox("panel") as StyleBoxFlat
	if sb != null and not equal(sb.bg_color, col):
		var n: StyleBoxFlat = smooth(sb.duplicate())
		n.bg_color = col
		p.add_theme_stylebox_override("panel", n)

# =============================================================================================
# Formatting
# =============================================================================================

static func _round(x: float) -> int:
	return int(floor(x + 0.5)) if x >= 0 else -int(floor(-x + 0.5))

# Core/Defs.format_troops: 1.2K / 123K / 1.25M / 12.5M, sign kept.
static func _format_troops(value: float) -> String:
	var v := absf(value)
	var s: String
	if is_nan(v): return "0"
	if v >= 1000000.0:
		s = ("%.2fM" % (v / 1000000.0)) if v < 10000000.0 else ("%.1fM" % (v / 1000000.0))
	elif v >= 1000.0:
		s = ("%.1fK" % (v / 1000.0)) if v < 100000.0 else ("%dK" % int(floor(v / 1000.0)))
	else:
		s = str(int(floor(v)))
	return ("-" if value < 0 else "") + s

static func fmt_num(v: float) -> String:
	return _format_troops(v)

## Suffixes: K (1e3), M (1e6), B (1e9), T (1e12), Qd (1e15). At 1e18 and above (past Qd) we use scientific notation.
const BIG_SUFFIX := ["", "K", "M", "B", "T", "Qd"]

## 1.343452e23 (GDScript's format has no %e). Exactly 6 digits after the decimal.
static func sci(a: float, decimals: int = 6) -> String:
	decimals = clampi(decimals, 0, 12)
	var ex := int(floorf(log(a) / log(10.0)))
	var m := a / pow(10.0, float(ex))
	if m >= 10.0:
		m /= 10.0
		ex += 1
	# %.Nf rounds; keep the mantissa in [1, 10) so we never print 10.000...eN.
	var step := pow(10.0, -float(decimals))
	var rounded := snappedf(m, step)
	if rounded >= 10.0:
		rounded = 1.0
		ex += 1
	return ("%." + str(decimals) + "fe%d") % [rounded, ex]


## Compact scientific notation for tight HUD labels (3 decimals: "2.345e23").
static func sci_hud(a: float) -> String:
	return sci(a, 3)


## v scaled by powers of 1000 to a suffix: "1.25B", "12.5T", "159.3Qd"; floored, never rounded. Past Qd
## (1e18 and above) it uses scientific notation with 6 decimal digits ("1.343452e23"), or `decimals` digits.
## NaN reads 0 and infinity "∞".
static func big(v: float, decimals: int = 6) -> String:
	if is_nan(v): return "0"
	if is_inf(v): return "∞" if v > 0 else "-∞"
	var a := absf(v)
	var neg := "-" if v < 0 else ""
	if a < 1000.0: return neg + str(int(floorf(a)))
	var e := 0
	var x := a
	while x >= 1000.0 and e < BIG_SUFFIX.size() - 1:
		x /= 1000.0
		e += 1
	if x >= 1000.0: return neg + sci(a, decimals)
	var t := ("%.2f" % (floorf(x * 100.0) / 100.0)) if x < 10.0 else ("%.1f" % (floorf(x * 10.0) / 10.0))
	if x >= 100.0 and e <= 1: t = "%d" % int(floorf(x))
	return neg + t + BIG_SUFFIX[e]

# Core/NumberFormat.render_number: floored, never rounded; negatives show as 0.
static func render_number(num: float) -> String:
	if is_nan(num): num = 0.0
	num = maxf(num, 0.0)
	if num >= 10_000_000_000.0: return "%.1fB" % (floorf(num / 100000000.0) / 10.0)
	if num >= 1_000_000_000.0: return "%.2fB" % (floorf(num / 10000000.0) / 100.0)
	if num >= 10_000_000.0: return "%.1fM" % (floorf(num / 100000.0) / 10.0)
	if num >= 1_000_000.0: return "%.2fM" % (floorf(num / 10000.0) / 100.0)
	if num >= 100000.0: return "%d" % int(floorf(num / 1000.0)) + "K"
	if num >= 10000.0: return "%.1fK" % (floorf(num / 100.0) / 10.0)
	if num >= 1000.0: return "%.2fK" % (floorf(num / 10.0) / 100.0)
	return str(int(floorf(num)))

# Troops as players see them (render_troops = the internal count / 10, floored, so a 25,000-troop start
# reads "2.50K"). Gold and other numbers use fmt_num.
## (kept for old callers; the display divisor is upstream's 10 whatever this says)
static var troop_div := 10.0
static func fmt_troops(v: float) -> String:
	return render_number(v / 10.0)

# Compact price: 50K, 125K, 1M, 1.5M, 25M.
static func fmt_cost(v: float) -> String:
	if v >= 1000000.0:
		var m := v / 1000000.0
		return ("%dM" % _round(m)) if absf(m - _round(m)) < 0.05 else ("%.1fM" % m)
	if v >= 1000.0:
		var k := v / 1000.0
		return ("%dK" % _round(k)) if (k >= 10 or absf(k - _round(k)) < 0.05) else ("%.1fK" % k)
	return str(int(floor(v)))

static func fmt_pct(share: float) -> String:
	var p := share * 100.0
	if p >= 10:
		return "%.1f%%" % p
	return ("%.2f%%" % p) if (p > 0 and p < 1) else ("%.1f%%" % p)

static func fmt_time(seconds: float) -> String:
	var s := maxi(0, int(floor(seconds)))
	if s >= 3600:
		return "%d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]
	return "%d:%02d" % [s / 60, s % 60]

static func fmt_rate(v: float) -> String:
	if absf(v) < 0.5:
		return "±0/s"
	return ("+" if v > 0 else "−") + _format_troops(absf(v)) + "/s"

## Old names some port code still calls: upstream's formatters (no scientific notation, no extra suffixes).
static func hud_rate(v: float) -> String:
	return fmt_rate(v)

static func hud_num(v: float) -> String:
	return fmt_num(v)

static func hud_troops(v: float) -> String:
	return fmt_troops(v)

static func render_number_hud(num: float) -> String:
	return render_number(num)

## Drawn width of `text` on `l` at font size `fs` (the font actually used to draw, plus outline, stylebox pad, slack).
static func label_need_width(l: Label, text: String, fs: int) -> float:
	var f: Font = l.get_theme_font("font")
	if f == null:
		f = ThemeDB.fallback_font
	var outline := 0
	if l.has_theme_constant("outline_size"):
		outline = l.get_theme_constant("outline_size")
	var pad := 0.0
	var sb: StyleBox = l.get_theme_stylebox("normal") if l.has_theme_stylebox("normal") else null
	if sb:
		pad += sb.get_margin(SIDE_LEFT) + sb.get_margin(SIDE_RIGHT)
	return ceilf(f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + float(outline) * 2.0) + 4.0 + pad

## Shrink a label's font until the measured string is <= `max_w`. clip_text stays off.
## If the string is still wider at min_size, the label's custom_minimum_size grows rather than clipping.
## An already-reserved min width is kept when the string is shorter, so the bar does not jiggle.
static func fit_label(l: Label, text: String, max_w: float, max_size: int, min_size := 9) -> float:
	l.text = text
	l.clip_text = false
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	var fs := max_size
	var need := label_need_width(l, text, fs)
	while fs > min_size and need > max_w:
		fs -= 1
		need = label_need_width(l, text, fs)
	l.add_theme_font_size_override("font_size", fs)
	if need > maxf(max_w, l.custom_minimum_size.x):
		l.custom_minimum_size.x = need
	return need
