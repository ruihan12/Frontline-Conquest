# Port of src/client/UI/TitleScreen.luau (scripts/ui/title_screen.gd, UITitleScreen): the solo parts.
# Backdrop shades over the map, the head (emblem, gradient wordmark, tag line), the bottom dock
# (greeting, PLAY SOLO, how to play), the PLAY SOLO panel (map, difficulty, START), the credits
# line and the Arsenal button, with the entrance animation and the wordmark's shine sweep.
# (GradientText, at the top of the Luau file, is client/ui/gradient_text.gd.)
#
# Not ported: public matches, the queue card, the party panel, the crate, shop, starter-pack and
# General buttons (this port is single player and has no purchases).
# Port's own: the name and the compass emblem, the tag line, the BOT PLAYERS row of the PLAY SOLO
# panel, and the wordmark's width (the name is longer than "ROWORLD").
class_name TitleScreen
extends Control

signal play_solo(difficulty: int)
signal pick_map
signal show_help
signal open_arsenal
signal open_crates

const NAME := "FRONTLINE CONQUEST"
const TAG := "CONQUER THE WORLD"
## The wordmark is at most this share of the screen's width (upstream 0.35 for "ROWORLD").
const WORD_MAX_W := 0.62
const CREDITS := "A port of RoWorld  ·  © OpenFront and Contributors  ·  Music by Rodrigo Flores  ·  GNU AGPL v3, no warranty: See Help & Credits"
const CREDITS_SHORT := "© OpenFront and Contributors  ·  Music: Rodrigo Flores  ·  GNU AGPL v3"
const DIFFS := ["Relaxed", "Standard", "Brutal"]
const DIFF_BLURB := [
	"Gentle AI: slower growth and a long early peace.",
	"A fair fight: nations respect a short early peace.",
	"Aggressive AI that grows fast and hunts you early.",
]
## (port) how many bot players join the match; 0 keeps it solo
const BOT_OPTS := [0, 4, 9, 19, 29]
const BOT_BLURB := "Bot players look and play like people: 2 play smart, the rest are novices. Any bot ends solo play, so everyone gets a 30 s spawn shield."
const INK := Color(0.01, 0.015, 0.05)
const SHAPES := "res://assets/rw/ui_shapes/"

var ctx: UICtx
var g
var difficulty := 1
var _sweep_t := -1.0
var _accum := 0.0
var _hide_tween: Tween = null
var _show_tween: Tween = null
var _slide_tween: Tween = null
var _chips: Array[Button] = []
var _bot_chips: Array[Button] = []
var _vignette: TextureRect
var _bottom_shade: TextureRect
var _top_shade: TextureRect
var _fade: ColorRect
var _head: VBoxContainer
var _emblem: Control
var _glow: TextureRect
var _word: GradientText
var _word_target_spacing := 0
var _tag_row: HBoxContainer
var _tag_l: Control
var _tag_r: Control
var _tag: Label
var _dock: GlassPanel
var _dock_v: VBoxContainer
var _greet: Label
var _solo: Button
var _help: Button
var _map_btn: Button
var _diff_row: HBoxContainer
var _diff_caption: Label
var _diff_desc: Label
const PLAYER_COLORS: Array[String] = ["#268cff", "#e53935", "#43a047", "#fdd835", "#8e24aa", "#fb8c00", "#00acc1", "#ec407a", "#7cb342", "#6d4c41", "#26c6da", "#ff7043"]
var _color_btns: Array[Button] = []
var _solo_panel: GlassPanel
var _solo_v: VBoxContainer
var _solo_open := false
var _start: Button
var _credits: Label
var _arsenal_btn: ArsenalButton
var _crates_btn: CrateButton
var _building := false
var _shown := false


static func _image_node(path: String, color: Color) -> TextureRect:
	var r := TextureRect.new()
	r.texture = load(path)
	r.modulate = color
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	return r


## A vertical alpha ramp of one colour; keys are [offset 0..1 top to bottom, alpha].
static func _vgrad_node(c: Color, keys: Array) -> TextureRect:
	var gr := Gradient.new()
	var offs := PackedFloat32Array()
	var cols := PackedColorArray()
	for k in keys:
		offs.append(float(k[0]))
		cols.append(Color(c.r, c.g, c.b, float(k[1])))
	gr.offsets = offs
	gr.colors = cols
	var tex := GradientTexture2D.new()
	tex.gradient = gr
	tex.width = 4
	tex.height = 128
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(0, 1)
	var r := TextureRect.new()
	r.texture = tex
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	return r


## An amber rule fading away from the tag text.
static func _tag_line(flip: bool) -> Control:
	var gr := Gradient.new()
	var a := Color(UITheme.AMBER, 0.85)
	var z := Color(UITheme.AMBER, 0.0)
	gr.offsets = PackedFloat32Array([0.0, 1.0])
	gr.colors = PackedColorArray([a, z] if flip else [z, a])
	var tex := GradientTexture2D.new()
	tex.gradient = gr
	tex.width = 64
	tex.height = 2
	var r := TextureRect.new()
	r.texture = tex
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.custom_minimum_size = Vector2(72, 2)
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return r


func _init(c: UICtx, main) -> void:
	ctx = c
	g = main
	name = "TitleScreen"
	theme = UITheme.theme()
	difficulty = clampi(int(g.diff_i), 0, 2)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_backdrop()
	_build_head()
	_build_dock()
	_build_solo_menu()
	_credits = UITheme.label(CREDITS, 11, 500, UITheme.c(UITheme.TEXT_3, 0.85), 1)
	_credits.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_credits.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_credits)
	_arsenal_btn = ArsenalButton.new(c)
	_arsenal_btn.pressed.connect(func() -> void: open_arsenal.emit())
	add_child(_arsenal_btn)
	_crates_btn = CrateButton.new(c)
	_crates_btn.pressed.connect(func() -> void: open_crates.emit())
	add_child(_crates_btn)
	visibility_changed.connect(_on_visibility)
	apply_layout()


## The game shows the title by `visible` alone (and fades it out when a match starts).
func _on_visibility() -> void:
	if is_visible_in_tree() and not _shown:
		_shown = true
		on_show()
	elif not visible:
		_shown = false
		close_solo_menu(true)


func _build_backdrop() -> void:
	_vignette = _image_node(SHAPES + "title_vignette.png", INK)
	_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_vignette)
	# readable dock at the bottom, deeper sky behind the wordmark at the top
	_bottom_shade = _vgrad_node(INK, [[0, 0.0], [1, 0.8]])
	_bottom_shade.anchor_left = 0.0
	_bottom_shade.anchor_top = 0.5
	_bottom_shade.anchor_right = 1.0
	_bottom_shade.anchor_bottom = 1.0
	add_child(_bottom_shade)
	_top_shade = _vgrad_node(Color(0.005, 0.01, 0.035), [[0, 0.92], [0.55, 0.6], [1, 0.0]])
	_top_shade.anchor_left = 0.0
	_top_shade.anchor_top = 0.0
	_top_shade.anchor_right = 1.0
	_top_shade.anchor_bottom = 0.5
	add_child(_top_shade)
	_fade = ColorRect.new()
	_fade.color = UITheme.rgba(0.005, 0.008, 0.03, 0.72)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade.modulate.a = 0.0
	add_child(_fade)


## (port) the compass badge this port has always worn, in place of RoWorld's app icon.
func _draw_emblem() -> void:
	var c := _emblem
	var s := c.size.x
	var k := s / 80.0
	c.draw_style_box(UITheme.flat(Color(0.10, 0.16, 0.32), 20.0 * k, Color(1, 1, 1, 0.25), 2), Rect2(Vector2.ZERO, c.size))
	var o := c.size * 0.5
	c.draw_arc(o, 26.0 * k, 0, TAU, 40, UITheme.AMBER, 3.0 * k, true)
	for i in 4:
		var d := Vector2.from_angle(i * PI / 2)
		var nn := Vector2(-d.y, d.x)
		c.draw_colored_polygon(PackedVector2Array([o + d * 30.0 * k, o + nn * 6.0 * k, o - nn * 6.0 * k]), Color.WHITE if i % 2 == 0 else Color(0.55, 0.75, 1.0))
	c.draw_circle(o, 5.0 * k, Color(0.95, 0.35, 0.3), true, -1.0, true)


func _build_head() -> void:
	_head = UITheme.vbox(0)
	_head.alignment = BoxContainer.ALIGNMENT_CENTER
	_head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_head)
	_emblem = Control.new()
	_emblem.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_emblem.custom_minimum_size = Vector2(64, 64)
	_emblem.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_emblem.draw.connect(_draw_emblem)
	_head.add_child(_emblem)
	# soft light behind the wordmark
	_glow = _image_node(SHAPES + "title_glow.png", Color.WHITE)
	add_child(_glow)
	move_child(_glow, 3)
	var word := GradientText.new(NAME, 120, 900)
	word.spacing = 14
	word.shadow = {"color": Color(0.0, 0.02, 0.08), "alpha": 0.55, "offset_y": 6, "outline": 14}
	word.set_colors(Color(1, 1, 1), Color(1.0, 0.8, 0.52))
	word.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_word = word
	_head.add_child(word)
	_tag_row = UITheme.hbox(16)
	_tag_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_tag_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tag_l = _tag_line(false)
	_tag_r = _tag_line(true)
	_tag = UITheme.label(TAG, 15, 600, Color(0.86, 0.89, 0.97), 6)
	_tag_row.add_child(_tag_l)
	_tag_row.add_child(_tag)
	_tag_row.add_child(_tag_r)
	_head.add_child(_tag_row)


func _build_dock() -> void:
	_dock = GlassPanel.new(20.0, 18.0, 18, true, 28)
	add_child(_dock)
	var v := UITheme.vbox(12)
	_dock_v = v
	_dock.add_child(v)
	_greet = UITheme.label("", 13, 500, UITheme.TEXT_2)
	_greet.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_greet)
	var row := UITheme.hbox(10)
	v.add_child(row)
	_solo = UITheme.button("PLAY SOLO", "PrimaryButton", "play", 58.0)
	_solo.add_theme_constant_override("icon_max_width", 18)
	_solo.add_theme_font_size_override("font_size", 19)
	_solo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_solo.pressed.connect(open_solo_menu)
	row.add_child(_solo)
	_help = UITheme.button("", "GlassButton", "help", 62.0)
	_help.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_help.tooltip_text = "How to play"
	_help.pressed.connect(func() -> void: show_help.emit())
	row.add_child(_help)

	# (these three live in the PLAY SOLO panel)
	var mb := UITheme.button("", "GlassButton", "globe", 42.0)
	mb.alignment = HORIZONTAL_ALIGNMENT_LEFT
	mb.add_theme_font_size_override("font_size", 14)
	mb.pressed.connect(func() -> void: pick_map.emit())
	_map_btn = mb
	set_map_name(UIMaps.name_of(g))
	var dr := UITheme.hbox(8)
	_diff_row = dr
	_diff_caption = UITheme.caption("Difficulty")
	_diff_caption.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_diff_caption.custom_minimum_size = Vector2(84, 0)
	dr.add_child(_diff_caption)
	for i in 3:
		var chip := UITheme.button(DIFFS[i], "ChipButton", "", 34.0)
		chip.toggle_mode = true
		chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chip.set_pressed_no_signal(i == difficulty)
		chip.pressed.connect(func() -> void:
			difficulty = i
			g.diff_i = i
			for j in _chips.size():
				_chips[j].set_pressed_no_signal(j == i)
			ctx.set_setting("difficulty", i)
			_refresh_diff())
		_chips.append(chip)
		dr.add_child(chip)
	_diff_desc = UITheme.label("", 12, 500, UITheme.TEXT_2)
	_diff_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_diff_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_diff_desc.custom_minimum_size = Vector2(360, 0)
	_refresh_diff()


func set_map_name(n: String) -> void:
	_map_btn.text = "Map:  " + n


func apply_layout() -> void:
	var vp := ctx.vp
	var compact := ctx.compact
	# The wordmark scales with the viewport, capped to WORD_MAX_W of its width. (Upstream also keeps
	# it clear of Roblox's top-left chat and party rows; nothing sits there in this port.)
	var word_px := clampf(minf(vp.x * 0.078, vp.y * 0.15), 44.0, 132.0)
	_size_word(word_px)
	var w_cap := vp.x * WORD_MAX_W
	if not compact:
		# stay clear of the Arsenal + Crates cluster in the top-right corner
		w_cap = minf(w_cap, 2.0 * (vp.x * 0.5 - _cluster_w() - 24.0))
	var w_now := _word.get_combined_minimum_size().x
	if w_now > w_cap:
		word_px = maxf(44.0, word_px * w_cap / w_now)
		_size_word(word_px)
	var col_x := vp.x * 0.5
	var dx := col_x - vp.x * 0.5
	var emblem_px := 0.0 if compact else clampf(word_px * 0.56, 44.0, 76.0)
	_emblem.visible = emblem_px > 0.0
	_emblem.custom_minimum_size = Vector2(emblem_px, emblem_px)
	_tag.add_theme_font_size_override("font_size", 11 if compact else 15)
	_tag_l.custom_minimum_size = Vector2(40 if compact else 72, 2)
	_tag_r.custom_minimum_size = _tag_l.custom_minimum_size
	var head_top := (56.0 if compact else maxf(vp.y * 0.07, 40.0)) + ctx.insets.y
	var head := _head
	head.anchor_left = 0.5
	head.anchor_right = 0.5
	head.anchor_top = 0.0
	head.anchor_bottom = 0.0
	head.grow_horizontal = Control.GROW_DIRECTION_BOTH
	head.grow_vertical = Control.GROW_DIRECTION_END
	head.offset_left = dx
	head.offset_right = dx
	head.offset_top = head_top
	head.offset_bottom = head_top
	head.reset_size()
	var wsize := _word.get_combined_minimum_size()
	_word.y0 = wsize.y * 0.18
	_word.span = wsize.y * 0.66
	_word.redraw()
	var gw := wsize.x * 1.5
	var gh := wsize.y * 2.4
	var gy := head_top + emblem_px + wsize.y * 0.5 - gh * 0.5
	_glow.position = Vector2(col_x - gw * 0.5, gy)
	_glow.size = Vector2(gw, gh)

	_diff_caption.visible = not compact
	var dock_w := 560.0 if not compact else minf(760.0, vp.x - ctx.insets.x - ctx.insets.z - 16.0)
	_dock.custom_minimum_size = Vector2(dock_w, 0)
	if compact:
		_dock.set_padding(10.0, 8.0, 10.0, 8.0)
	else:
		_dock.set_padding(20.0, 18.0, 20.0, 18.0)
	_solo.custom_minimum_size = Vector2(150 if compact else 0, 52 if compact else 50)
	_solo.add_theme_font_size_override("font_size", 15 if compact else 17)
	_solo_panel.custom_minimum_size = Vector2(dock_w, 0)
	if compact:
		_solo_panel.set_padding(12.0, 10.0, 12.0, 10.0)
		_solo_v.add_theme_constant_override("separation", 8)
	else:
		_solo_panel.set_padding(20.0, 18.0, 20.0, 18.0)
		_solo_v.add_theme_constant_override("separation", 12)
	_start.custom_minimum_size = Vector2(0, 48 if compact else 58)
	_start.add_theme_font_size_override("font_size", 16 if compact else 19)
	_help.custom_minimum_size = Vector2(56, 56) if compact else Vector2(62, 62)
	for ch in _chips:
		ch.custom_minimum_size = Vector2(64 if compact else 0, 44 if ctx.touch else 34)
		ch.add_theme_font_size_override("font_size", 12 if compact else 13)
	_diff_desc.add_theme_font_size_override("font_size", 11 if compact else 12)
	_diff_desc.custom_minimum_size = Vector2(0 if compact else 360, 0)
	_greet.visible = not compact
	var bottom := (40.0 if not compact else 20.0) + ctx.insets.w
	for cn: Control in [_dock, _solo_panel]:
		cn.anchor_left = 0.5
		cn.anchor_right = 0.5
		cn.anchor_top = 1.0
		cn.anchor_bottom = 1.0
		cn.grow_horizontal = Control.GROW_DIRECTION_BOTH
		cn.grow_vertical = Control.GROW_DIRECTION_BEGIN
		cn.offset_left = dx
		cn.offset_right = dx
		cn.offset_top = -bottom
		cn.offset_bottom = -bottom
		cn.reset_size()
	_credits.visible = true
	_credits.text = CREDITS_SHORT if compact else CREDITS
	_credits.add_theme_font_size_override("font_size", 10 if compact else 11)
	var cb := 2.0 if compact else 14.0
	_credits.anchor_left = 0.0
	_credits.anchor_top = 1.0
	_credits.anchor_right = 1.0
	_credits.anchor_bottom = 1.0
	_credits.offset_left = 0
	_credits.offset_right = 0
	_credits.offset_top = -(cb + ctx.insets.w + 14.0)
	_credits.offset_bottom = -(cb + ctx.insets.w)
	_place_arsenal_button(compact, head_top)


## Top right, level with the head. (Upstream's _place_crate_button: the crate takes this corner and
## the Arsenal sits left of it; with no crate the Arsenal takes the corner.)
## Width the Arsenal + Crates cluster takes from the right edge (desktop).
func _cluster_w() -> float:
	var a := _arsenal_btn
	a.set_scale_k(1.0)
	_crates_btn.set_scale_k(1.0)
	return ctx.insets.z + 28.0 + _crates_btn.size_px().x + 6.0 + a.size_px().x + a.overhang()


func _place_arsenal_button(compact: bool, head_top: float) -> void:
	var vp := ctx.vp
	var ins := ctx.insets
	var a := _arsenal_btn
	a.set_scale_k(ArsenalButton.PHONE_K if compact else 1.0)
	var asz := a.size_px()
	var right := vp.x - maxf(14.0, ins.z * 0.45) if compact else vp.x - ins.z - 28.0
	var top := maxf(6.0, ins.y * 0.5) if compact else head_top
	var gap := 10.0 if compact else 6.0
	var csz := Vector2.ZERO
	if _crates_btn != null:
		_crates_btn.set_scale_k(CrateButton.PHONE_K if compact else 1.0)
		csz = _crates_btn.size_px()
		_crates_btn.size = csz
		_crates_btn.position = Vector2(right - csz.x, top)
		right -= csz.x + gap
	a.position = Vector2(right - asz.x - a.overhang(), top)
	a.size = asz


func _refresh_greeting() -> void:
	var n := ctx.username()
	_greet.text = ("Welcome, Commander " + n) if (n != "Commander" and n != "") else "Welcome, Commander"


func _build_solo_menu() -> void:
	var T := UITheme
	var p := GlassPanel.new(20.0, 18.0, 18, true, 28)
	_solo_panel = p
	add_child(p)
	var v := T.vbox(12)
	_solo_v = v
	p.add_child(v)
	var head := T.hbox(10)
	var ic := T.icon_rect("play", 18.0, T.AMBER)
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(ic)
	var title := T.label("PLAY SOLO", 17, 800, T.TEXT, 2)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(title)
	var x := T.button("", "GhostButton", "close", 44.0)
	x.expand_icon = true
	x.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	x.add_theme_constant_override("icon_max_width", 16)
	x.custom_minimum_size = Vector2(44, 44)
	x.pressed.connect(func() -> void: close_solo_menu())
	head.add_child(x)
	v.add_child(head)
	_map_btn.size_flags_horizontal = Control.SIZE_FILL
	v.add_child(_map_btn)
	_diff_row.size_flags_horizontal = Control.SIZE_FILL
	v.add_child(_diff_row)
	v.add_child(_diff_desc)

	# (port) bot players, as in upstream's public matches: 0 keeps the match solo
	var br := T.hbox(8)
	var bcap := T.caption("Bot players")
	bcap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bcap.custom_minimum_size = Vector2(84, 0)
	br.add_child(bcap)
	for i in BOT_OPTS.size():
		var chip := T.button("Off" if BOT_OPTS[i] == 0 else str(BOT_OPTS[i]), "ChipButton", "", 34.0)
		chip.toggle_mode = true
		chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chip.pressed.connect(func() -> void:
			g.bot_players = BOT_OPTS[i]
			_refresh_bots())
		_bot_chips.append(chip)
		br.add_child(chip)
	v.add_child(br)
	var bdesc := T.label(BOT_BLURB, 12, 500, T.TEXT_3)
	bdesc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bdesc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bdesc.custom_minimum_size = Vector2(360, 0)
	v.add_child(bdesc)
	_refresh_bots()

	# (port, owner request 2026-11-24) your colour for this match; stored as save.settings.player_color
	var cr := T.hbox(8)
	var ccap := T.caption("Your colour")
	ccap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ccap.custom_minimum_size = Vector2(84, 0)
	cr.add_child(ccap)
	var grid := GridContainer.new()
	grid.columns = 6
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for hx: String in PLAYER_COLORS:
		var sw := Button.new()
		sw.custom_minimum_size = Vector2(34, 34)
		sw.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sw.focus_mode = Control.FOCUS_NONE
		sw.set_meta("hex", hx)
		var col := Color.html(hx)
		for st: String in ["normal", "hover", "pressed", "focus"]:
			var sb := StyleBoxFlat.new()
			sb.bg_color = col.lightened(0.12) if st == "hover" else col
			sb.set_corner_radius_all(8)
			sw.add_theme_stylebox_override(st, sb)
		sw.pressed.connect(func() -> void:
			if not g.save.has("settings"): g.save["settings"] = {}
			g.save["settings"]["player_color"] = hx
			g.write_save()
			_refresh_color())
		_color_btns.append(sw)
		grid.add_child(sw)
	cr.add_child(grid)
	v.add_child(cr)
	_refresh_color()

	var start := T.button("START", "PrimaryButton", "play", 58.0)
	start.add_theme_constant_override("icon_max_width", 18)
	start.add_theme_font_size_override("font_size", 19)
	start.pressed.connect(func() -> void: play_solo.emit(difficulty))
	_start = start
	v.add_child(start)
	p.visible = false


func _refresh_color() -> void:
	var cur := str(g.save.get("settings", {}).get("player_color", PLAYER_COLORS[0])).to_lower()
	for b: Button in _color_btns:
		var on := str(b.get_meta("hex")).to_lower() == cur
		for st: String in ["normal", "hover", "pressed", "focus"]:
			var sb := b.get_theme_stylebox(st) as StyleBoxFlat
			sb.set_border_width_all(3 if on else 0)
			sb.border_color = Color.WHITE


func _refresh_bots() -> void:
	var at := maxi(0, BOT_OPTS.find(int(g.bot_players)))
	for j in _bot_chips.size():
		_bot_chips[j].set_pressed_no_signal(j == at)


func open_solo_menu() -> void:
	if _solo_open:
		return
	_solo_open = true
	_dock.visible = false
	_solo_panel.visible = true
	_solo_panel.reset_size()
	# (the wrapped lines only know their height once the panel has its width)
	get_tree().process_frame.connect(apply_layout, CONNECT_ONE_SHOT)
	UIFx.pop_in(_solo_panel, 0.0, 0.96, 0.25)
	ctx.sfx("open", -6.0)


func close_solo_menu(quiet: bool = false) -> void:
	if not _solo_open:
		return
	_solo_open = false
	_solo_panel.visible = false
	_dock.visible = true
	if not quiet:
		ctx.sfx("close", -6.0)


func solo_menu_open() -> bool:
	return _solo_open


func _refresh_diff() -> void:
	var txt: String = DIFF_BLURB[difficulty]
	var secs: float = float(g.sim_rules.human_grace_ticks(difficulty)) / 10.0 if g.sim_rules != null else float(g.DIFFS[difficulty][1])
	if secs > 0.0:
		txt += "\nNations leave you alone for " + UITheme.fmt_time(secs) + "."
	_diff_desc.text = txt


func _size_word(px: float) -> void:
	_word.set_px(px)
	_word.spacing = int(floor(px * 0.12))
	_word_target_spacing = _word.spacing
	_word.shadow.outline = int(floor(px * 0.1))
	_word._restyle()


## The entrance: the map shows through as the dark fades, then the wordmark settles in, then the
## tag line, the dock and the credits.
func on_show() -> void:
	_refresh_greeting()
	if _hide_tween != null:
		_hide_tween.kill()
		_hide_tween = null
	if _show_tween != null:
		_show_tween.kill()
	modulate.a = 1.0
	difficulty = clampi(int(g.diff_i), 0, 2)
	for j in _chips.size():
		_chips[j].set_pressed_no_signal(j == difficulty)
	_refresh_diff()
	_refresh_bots()
	set_map_name(UIMaps.name_of(g))
	apply_layout()
	var word := _word
	var target_sp := _word_target_spacing
	word.modulate.a = 0.0
	word.pivot_offset = word.size * 0.5
	word.scale = Vector2(1.18, 1.18)
	var t := create_tween().set_parallel(true)
	_show_tween = t
	_fade.modulate.a = 1.0
	t.tween_property(_fade, "modulate:a", 0.0, 1.8).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_emblem.modulate.a = 0.0
	t.tween_property(_emblem, "modulate:a", 1.0, 0.7).set_delay(0.5)
	t.tween_property(word, "modulate:a", 1.0, 0.8).set_delay(1.0).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.tween_property(word, "scale", Vector2.ONE, 1.2).set_delay(1.0).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	word.spacing = target_sp + 30
	t.tween_method(func(v: float) -> void: word.spacing = int(v), float(target_sp + 30), float(target_sp), 1.5).set_delay(1.0).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	_glow.modulate.a = 0.0
	t.tween_property(_glow, "modulate:a", 1.0, 1.6).set_delay(1.4)
	_tag_row.modulate.a = 0.0
	t.tween_property(_tag_row, "modulate:a", 1.0, 0.7).set_delay(2.1)
	if _slide_tween != null:
		_slide_tween.kill()
	_slide_tween = UIFx.slide_in(_dock, Vector2(0, 40), 1.7, 0.7)
	_credits.modulate.a = 0.0
	t.tween_property(_credits, "modulate:a", 1.0, 0.8).set_delay(2.6)
	_arsenal_btn.modulate.a = 0.0
	_crates_btn.modulate.a = 0.0
	t.tween_property(_arsenal_btn, "modulate:a", 1.0, 0.7).set_delay(2.1)
	t.tween_property(_crates_btn, "modulate:a", 1.0, 0.7).set_delay(2.1)
	_sweep_t = 0.0


## Skips the entrance (screenshot runs).
func finish_show() -> void:
	if _show_tween != null:
		_show_tween.kill()
		_show_tween = null
	if _slide_tween != null:
		_slide_tween.kill()
		_slide_tween = null
	for n: CanvasItem in [_emblem, _word, _glow, _tag_row, _credits, _dock, _arsenal_btn, _crates_btn]:
		n.modulate.a = 1.0
	_fade.modulate.a = 0.0
	_word.scale = Vector2.ONE
	_word.spacing = _word_target_spacing
	UIFx._set_shift(_dock, Vector2.ZERO)
	_sweep_t = -1.0
	_word.sweep = -10000.0
	_word.redraw()


func set_building(on: bool) -> void:
	if on == _building:
		return
	_building = on
	_solo.disabled = on
	_start.disabled = on
	_start.text = "DEPLOYING…" if on else "START"
	for ch in _chips:
		ch.disabled = on


func hide_animated() -> void:
	if not visible or (_hide_tween != null and _hide_tween.is_running()):
		return
	_hide_tween = create_tween()
	_hide_tween.tween_property(self, "modulate:a", 0.0, 0.3).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_hide_tween.tween_callback(func() -> void:
		visible = false
		modulate.a = 1.0
		close_solo_menu(true))


func _process(delta: float) -> void:
	if not visible:
		return
	if _sweep_t >= 0.0:
		_sweep_t += delta
		var w := _word.size.x
		var x := -240.0 + (w + 480.0) * clampf((_sweep_t - 3.6) / 1.2, 0.0, 1.0)
		_word.sweep = x
		_word.redraw()
		if _sweep_t > 4.9:
			_sweep_t = -1.0
			_word.sweep = -10000.0
			_word.redraw()
	_accum += delta
	if _accum >= 0.25:
		_accum = 0.0
		_refresh_greeting()
		set_building(bool(g._loading))
		set_map_name(UIMaps.name_of(g))
