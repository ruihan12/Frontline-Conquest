# Port of src/client/UI/Arsenal.luau: the Arsenal window. A list of the items on the left (grouped
# NUKES / ARMY / BOOSTS, each with its price or OWNED), the selected item on the right: a preview,
# its name, tags, one plain sentence and the way to get it.
#
# Port: there are no purchases here, so the big green button is the Stars unlock (upstream: the
# Robux button, with "or unlock with Stars" under it); the two-press confirm is kept. Prices are
# this port's (game/state.gd ARSENAL). The preview shows the item's render; upstream's animated
# demo (UI/ArsenalDemo.luau) is not ported.
class_name Arsenal
extends Control

signal closed

const GROUPS := [["NUKES", ["nuke"]], ["ARMY", ["call", "structure"]], ["BOOSTS", ["boost"]]]
const KIND_TAGS := {"structure": "BUILDING", "nuke": "NUKE", "call": "ORDER", "boost": "BOOST"}
const SUBTITLE := "Unlock once, keep it forever. Earn Stars by playing matches."
const LIST_W := 236.0
const LIST_W_PHONE := 190.0
const ROW_H := 46.0
const ROW_H_PHONE := 38.0
const DETAIL_W := 470.0
const PREVIEW_H := 228.0
## A Stars unlock asks twice: the second press must come within this long.
const CONFIRM_S := 3.0
const NOTE_S := 4.0

const GOLD := Color8(255, 200, 61)
const GOLD_DARK := Color8(64, 40, 4)
const GREEN_TOP := Color8(86, 216, 130)
const GREEN_BOTTOM := Color8(34, 166, 90)
const GREEN_TOP_HI := Color8(108, 234, 150)
const GREEN_LIP := Color8(18, 108, 56)
const GREEN_INK := Color8(12, 82, 42)
const OWNED_GREEN := Color8(110, 230, 155)
const MUTED := Color8(170, 182, 211)
const ROW := Color8(24, 33, 58)
const ROW_ON := Color8(38, 53, 90)
const CHIP := Color8(38, 53, 90)
const BAR_OFF := Color8(44, 58, 94)
const NIGHT := Color8(8, 12, 26)

var ctx: UICtx
var g
var is_open := false
var _rows := {}  # key -> {button, name, icon, text}
var _sel := ""
var _confirm := ""
var _confirm_until := 0.0
var _note := ""
var _note_until := 0.0
var _note_color := GOLD
var _from := "title"
var _dim: ColorRect
var _panel: GlassPanel
var _v: VBoxContainer
var _sub: Label
var _balance: Label
var _list_host: Control
var _list: VBoxContainer
var _detail_host: Control
var _detail: Control = null
var _cta: VBoxContainer = null
var _flash: ColorRect = null
var _quiet := false


static func commas(n: float) -> String:
	return UICtx.commas(n)


static func short(n: int) -> String:
	if n >= 10000 and n % 1000 == 0:
		@warning_ignore("integer_division")
		return commas(n / 1000) + "K"
	return commas(n)


static func c3(hex: int) -> Color:
	return Color8((hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF)


func _init(c: UICtx, main) -> void:
	ctx = c
	g = main
	name = "Arsenal"
	theme = UITheme.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_dim = ColorRect.new()
	_dim.color = UITheme.rgba(0.01, 0.015, 0.05, 0.8)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and not _panel.get_global_rect().has_point(e.global_position):
			close())
	add_child(_dim)
	_panel = GlassPanel.new(20.0, 16.0, 18, true, 34)
	_panel.set_tint(UITheme.rgba(0.045, 0.065, 0.13, 0.97))
	add_child(_panel)
	_v = UITheme.vbox(12)
	_panel.add_child(_v)

	var head := UITheme.hbox(12)
	var icon := UITheme.icon_rect("arsenal", 26.0, UITheme.GOLD)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(icon)
	var tv := UITheme.vbox(0)
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tv.add_child(UITheme.label("ARSENAL", 20, 800, UITheme.TEXT, 3))
	_sub = UITheme.label(SUBTITLE, 12, 500, UITheme.TEXT_2)
	tv.add_child(_sub)
	head.add_child(tv)
	var bal := GlassPanel.new(12.0, 6.0, 999, false, 0)
	bal.set_tint(UITheme.rgba(1.0, 0.78, 0.24, 0.12))
	bal.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var bh := UITheme.hbox(6)
	var star := UITheme.icon_rect("star", 16.0, UITheme.GOLD)
	star.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bh.add_child(star)
	_balance = UITheme.label("0", 16, 800, UITheme.GOLD)
	_balance.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bh.add_child(_balance)
	bal.add_child(bh)
	head.add_child(bal)
	var x := UITheme.button("", "GhostButton", "close", 34.0)
	x.expand_icon = true
	x.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	x.custom_minimum_size = Vector2(34, 34)
	x.add_theme_constant_override("icon_max_width", 13)
	x.add_theme_stylebox_override("normal", UITheme.empty_box(8, 8))
	x.add_theme_stylebox_override("hover", UITheme.flat(UITheme.FILL, 8, UITheme.CLEAR, 0, 8, 8))
	x.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	x.pressed.connect(close)
	head.add_child(x)
	_v.add_child(head)

	var body := UITheme.hbox(14)
	_v.add_child(body)
	_list_host = Control.new()
	_list_host.mouse_filter = Control.MOUSE_FILTER_PASS
	body.add_child(_list_host)
	var scroll := ScrollContainer.new()
	scroll.name = "ArsenalList"
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list_host.add_child(scroll)
	_list = UITheme.vbox(4)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	_detail_host = Control.new()
	_detail_host.mouse_filter = Control.MOUSE_FILTER_PASS
	body.add_child(_detail_host)
	visibility_changed.connect(_on_visibility)
	set_process(false)


## The game (and its screenshot runs) also shows and hides this window by `visible` alone.
func _on_visibility() -> void:
	if _quiet:
		return
	if visible and not is_open:
		_quiet = true
		open()
		modulate.a = 1.0
		_quiet = false
	elif not visible and is_open:
		is_open = false
		set_process(false)


# --- the port's inventory -------------------------------------------------------------------
func _stars() -> int:
	return int(g.save.get("stars", 0))


func _owned(key: String) -> bool:
	return ctx.session.has_unlock(key)


func _cost(key: String) -> int:
	return ctx.session.unlock_cost(key)


## What to show first: the asked-for item, else the first one the Stars can buy, else the first
## still locked.
func pick(focus = null) -> String:
	if focus is String and ArsenalData.item(focus) != null:
		return focus
	for it in ArsenalData.ITEMS:
		if not _owned(it.key) and _stars() >= _cost(it.key):
			return it.key
	for it in ArsenalData.ITEMS:
		if not _owned(it.key):
			return it.key
	return ArsenalData.ITEMS[0].key


# --- the list ---------------------------------------------------------------------------------
func _build_list() -> void:
	for ch in _list.get_children():
		ch.queue_free()
	_rows.clear()
	var compact := ctx.compact
	var rh := ROW_H_PHONE if compact else ROW_H
	for grp in GROUPS:
		var gl := UITheme.label(grp[0], 10, 700, MUTED, 1)
		gl.custom_minimum_size = Vector2(0, 18)
		gl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_list.add_child(gl)
		for it in ArsenalData.ITEMS:
			if it.kind in grp[1]:
				_rows[it.key] = _row(it, rh)


func _row(it: Dictionary, rh: float) -> Dictionary:
	var compact := ctx.compact
	var b := Button.new()
	b.name = "Row_" + str(it.key)
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, rh)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_list.add_child(b)
	var th := rh - 10.0
	var tile := Panel.new()
	tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_theme_stylebox_override("panel", UITheme.flat(c3(it.color[1]).lerp(NIGHT, 0.35), 8))
	tile.position = Vector2(5, 5)
	tile.size = Vector2(th, th)
	b.add_child(tile)
	var img := TextureRect.new()
	img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shot := ArsenalData.render(it.key)
	img.texture = shot if shot != null else UITheme.icon_texture(it.icon)
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	img.position = Vector2(th * 0.07, th * 0.07)
	img.size = Vector2(th * 0.86, th * 0.86)
	tile.add_child(img)
	var price_w := 52.0 if compact else 60.0
	var nm := UITheme.label(it.title, 12 if compact else 14, 700, Color.WHITE)
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nm.clip_text = true
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	nm.anchor_right = 1.0
	nm.anchor_bottom = 1.0
	nm.offset_left = th + 13.0
	nm.offset_right = -(price_w + 10.0)
	b.add_child(nm)
	var right := UITheme.hbox(3)
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.alignment = BoxContainer.ALIGNMENT_END
	right.anchor_left = 1.0
	right.anchor_right = 1.0
	right.anchor_bottom = 1.0
	right.offset_left = -(price_w + 8.0)
	right.offset_right = -8.0
	b.add_child(right)
	var pic := UITheme.icon_rect("star", 13.0, GOLD)
	pic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	right.add_child(pic)
	var tx := UITheme.label("", 11 if compact else 12, 900, GOLD)
	tx.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	right.add_child(tx)
	b.pressed.connect(func() -> void: _select(it.key, true))
	return {"button": b, "name": nm, "icon": pic, "text": tx}


func _refresh_list() -> void:
	var stars := _stars()
	for key in _rows:
		var r: Dictionary = _rows[key]
		var on: bool = _sel == key
		var b: Button = r.button
		b.add_theme_stylebox_override("normal", UITheme.flat(ROW_ON if on else ROW, 10, GOLD if on else UITheme.CLEAR, 2 if on else 0))
		b.add_theme_stylebox_override("hover", UITheme.flat(ROW_ON if on else ROW.lerp(ROW_ON, 0.5), 10, GOLD if on else UITheme.CLEAR, 2 if on else 0))
		b.add_theme_stylebox_override("pressed", UITheme.flat(ROW_ON, 10, GOLD if on else UITheme.CLEAR, 2 if on else 0))
		var cost := _cost(key)
		if _owned(key):
			r.icon.visible = false
			r.text.text = "OWNED"
			UITheme.set_font_color(r.text, OWNED_GREEN)
		else:
			r.icon.visible = true
			var can := stars >= cost
			r.icon.modulate = GOLD if can else MUTED
			r.text.text = short(cost)
			UITheme.set_font_color(r.text, GOLD if can else MUTED)


# --- the selected item --------------------------------------------------------------------------
func _detail_size() -> Vector2:
	return _detail_host.custom_minimum_size


func _chip(text: String, color: Color) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", UITheme.flat(CHIP, 6, UITheme.CLEAR, 0, 8.0, 3.0))
	p.add_child(UITheme.label(text, 10, 700, color))
	return p


func _build_detail() -> void:
	if _detail != null:
		_detail.queue_free()
		_detail = null
	var it = ArsenalData.item(_sel)
	if it == null:
		return
	var compact := ctx.compact
	var size_d := _detail_size()
	var side := compact
	var pv := Vector2(floorf(minf(size_d.x * 0.42, size_d.y * 1.25)), size_d.y) if side else Vector2(size_d.x, PREVIEW_H)
	var root := Control.new()
	root.name = "ArsenalItem"
	root.mouse_filter = Control.MOUSE_FILTER_PASS
	root.size = size_d
	_detail_host.add_child(root)
	_detail = root
	# the preview: a ground in the item's colours, deepening to night, with its render on it
	var top := c3(it.color[0])
	var bottom := c3(it.color[1])
	var ground := Panel.new()
	ground.name = "Preview"
	ground.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ground.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	ground.add_theme_stylebox_override("panel", UITheme.flat(Color.WHITE, 12))
	ground.size = pv
	root.add_child(ground)
	var gr := Gradient.new()
	gr.offsets = PackedFloat32Array([0.0, 1.0])
	gr.colors = PackedColorArray([top.lerp(NIGHT, 0.42), bottom.lerp(NIGHT, 0.8)])
	var gt := GradientTexture2D.new()
	gt.gradient = gr
	gt.width = 4
	gt.height = 64
	gt.fill_to = Vector2(0, 1)
	var fill := TextureRect.new()
	fill.texture = gt
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fill.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	fill.stretch_mode = TextureRect.STRETCH_SCALE
	fill.size = pv
	ground.add_child(fill)
	var shot := ArsenalData.render(it.key)
	var sticker := TextureRect.new()
	sticker.name = "Render"
	sticker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sticker.texture = shot if shot != null else UITheme.icon_texture(it.icon)
	sticker.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sticker.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var sh := 0.8 * pv.y
	var sw := sh * float(shot.get_width()) / float(shot.get_height()) if shot != null else sh * 0.6
	var max_w := pv.x * 0.8
	if sw > max_w:
		sh *= max_w / sw
		sw = max_w
	sticker.size = Vector2(sw, sh)
	sticker.position = (pv - sticker.size) * 0.5
	ground.add_child(sticker)
	_flash = ColorRect.new()
	_flash.name = "Flash"
	_flash.color = Color(top, 0.0)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash.size = pv
	ground.add_child(_flash)

	var x0 := pv.x + 14.0 if side else 0.0
	var y0 := 0.0 if side else pv.y + 12.0
	var col := UITheme.vbox(6 if compact else 8)
	col.name = "Words"
	col.position = Vector2(x0, y0)
	col.size = Vector2(size_d.x - x0, size_d.y - y0)
	root.add_child(col)
	var title := UITheme.label(str(it.title).to_upper(), 18 if compact else 24, 900, Color.WHITE)
	title.clip_text = true
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(title)
	var chips := UITheme.hbox(6)
	if not compact:
		chips.add_child(_chip(KIND_TAGS.get(it.kind, ""), Color.WHITE))
		chips.add_child(_chip("FOREVER", OWNED_GREEN))
	for f in it.get("facts", []):
		chips.add_child(_chip(str(f).to_upper(), GOLD))
	col.add_child(chips)
	var plain := UITheme.label(str(it.get("plain", it.get("tagline", ""))), 12 if compact else 14, 500, Color8(214, 222, 240))
	plain.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	plain.custom_minimum_size = Vector2(0, ((12 if compact else 14) + 4) * 2)
	col.add_child(plain)
	_cta = UITheme.vbox(8)
	_cta.name = "Get"
	col.add_child(_cta)
	_build_cta()


func _line(text: String, color: Color) -> void:
	var l := UITheme.label(text, 11 if ctx.compact else 12, 500, color)
	l.name = "Line"
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_cta.add_child(l)


## A wide button with a row of words and pictures in it.
func _wide_button(h: float, fill_col: Color, border: Color, bw: int, lip: Color = UITheme.CLEAR) -> Array:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, h)
	var sb := UITheme.flat(fill_col, 12, border, bw)
	if lip.a > 0.0:
		sb.border_width_bottom = 4
		sb.border_color = lip
	var hot: StyleBoxFlat = sb.duplicate()
	hot.bg_color = fill_col.lightened(0.08)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("disabled", sb)
	b.add_theme_stylebox_override("hover", hot)
	b.add_theme_stylebox_override("pressed", hot)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var row := UITheme.hbox(6)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	b.add_child(row)
	_cta.add_child(b)
	return [b, row]


static func _words(row: HBoxContainer, text: String, fs: int, color: Color) -> void:
	var l := UITheme.label(text, fs, 900, color, 1)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(l)


static func _pic(row: HBoxContainer, icon_name: String, px: float, color: Color) -> void:
	var r := UITheme.icon_rect(icon_name, px, color)
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(r)


func _build_cta() -> void:
	if _cta == null:
		return
	for ch in _cta.get_children():
		ch.queue_free()
	var it = ArsenalData.item(_sel)
	if it == null:
		return
	var compact := ctx.compact
	var stars := _stars()
	var cost := _cost(it.key)
	var bh := 38.0 if compact else 48.0
	if _owned(it.key):
		var own := _wide_button(bh, Color(OWNED_GREEN, 0.08), OWNED_GREEN, 2)
		_pic(own[1], "check", 18.0, OWNED_GREEN)
		_words(own[1], "OWNED", 15 if compact else 17, OWNED_GREEN)
		own[0].disabled = true
		_line("It's always on, in every match." if it.kind == "boost" else "It's in your build bar in every match.", MUTED)
	elif stars >= cost:
		var confirm: bool = _confirm == it.key and UICtx.msec() < _confirm_until
		var buy := _wide_button(bh, GOLD if confirm else GREEN_BOTTOM.lerp(GREEN_TOP, 0.5), UITheme.CLEAR, 0, GOLD_DARK if confirm else GREEN_LIP)
		var ink := GOLD_DARK if confirm else Color.WHITE
		_words(buy[1], "PRESS AGAIN TO SPEND" if confirm else "UNLOCK", 15 if compact else 18, ink)
		_pic(buy[1], "star", 16.0, ink if confirm else GOLD)
		_words(buy[1], commas(cost), 15 if compact else 18, ink)
		buy[0].pressed.connect(func() -> void: _stars_pressed(it))
		_line("You have %s Stars." % commas(stars), MUTED)
	else:
		var row := UITheme.hbox(4)
		row.add_child(UITheme.label("Earn it by playing:", 11 if compact else 12, 500, MUTED))
		_pic(row, "star", 12.0, GOLD)
		row.add_child(UITheme.label("%s of %s" % [commas(stars), commas(cost)], 11 if compact else 12, 700, GOLD))
		_cta.add_child(row)
		var bar := FillBar.new(4.0, GOLD)
		bar.glow = false
		bar.custom_minimum_size = Vector2(0, 8)
		bar.set_target(clampf(float(stars) / maxf(1.0, float(cost)), 0.02, 1.0), true)
		_cta.add_child(bar)
	if _note != "" and UICtx.msec() < _note_until:
		_line(_note, _note_color)


func _select(key: String, by_player: bool = false) -> void:
	if ArsenalData.item(key) == null:
		return
	var changed := key != _sel
	_sel = key
	_confirm = ""
	if changed:
		_note = ""
	if by_player:
		ctx.sfx("click", -6.0)
	_refresh_list()
	_build_detail()


func _refresh() -> void:
	_balance.text = commas(_stars())
	_refresh_list()
	_build_cta()


func _say(text: String, color: Color = GOLD) -> void:
	_note = text
	_note_color = color
	_note_until = UICtx.msec() + NOTE_S * 1000.0
	_build_cta()
	set_process(true)


## Unlock with Stars: the first press arms it, the second (within CONFIRM_S) spends.
func _stars_pressed(it: Dictionary) -> void:
	if _owned(it.key):
		return
	if _stars() < _cost(it.key):
		ctx.sfx("deny")
		_say("Not enough Stars yet.", UITheme.RED)
		return
	if _confirm != it.key or UICtx.msec() >= _confirm_until:
		_confirm = it.key
		_confirm_until = UICtx.msec() + CONFIRM_S * 1000.0
		ctx.sfx("click")
		_build_cta()
		set_process(true)
		return
	_confirm = ""
	if g.unlock_arsenal_item(str(it.local_id)):
		_on_unlocked(it.key)
	else:
		ctx.sfx("deny")
		_say("That did not go through.", UITheme.RED)


func _on_unlocked(key: String) -> void:
	ctx.sfx("unlock")
	_note = ""
	_refresh()
	if key == _sel and _flash != null and is_instance_valid(_flash):
		_flash.color.a = 0.85
		var t := _flash.create_tween()
		t.tween_property(_flash, "color:a", 0.0, 0.6).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if ctx.rules != null:
		ctx.rules.recount()


## Called by the game when the save changed under the window.
func refresh() -> void:
	if is_open:
		_refresh()


func _process(_dt: float) -> void:
	var now := UICtx.msec()
	var dirty := false
	if _confirm != "" and now >= _confirm_until:
		_confirm = ""
		dirty = true
	if _note != "" and now >= _note_until:
		_note = ""
		dirty = true
	if dirty:
		_build_cta()
	if _confirm == "" and _note == "":
		set_process(false)


func open(focus = null, from: String = "title") -> void:
	_from = from
	_confirm = ""
	_note = ""
	if not is_open:
		is_open = true
		_quiet = true
		visible = true
		_quiet = false
		modulate.a = 1.0
		_panel.modulate.a = 1.0
		_dim.modulate.a = 0.0
		UIFx.fade(_dim, 1.0, 0.2)
		UIFx.pop_in(_panel, 0.0, 0.94, 0.3)
		ctx.sfx("open")
	_sel = pick(focus)
	apply_layout()


func close() -> void:
	if not is_open:
		return
	is_open = false
	set_process(false)
	ctx.sfx("close")
	var t := create_tween().set_parallel(true)
	t.tween_property(_dim, "modulate:a", 0.0, 0.15)
	t.tween_property(_panel, "modulate:a", 0.0, 0.15)
	t.chain().tween_callback(func() -> void:
		if not is_open:
			_quiet = true
			visible = false
			_quiet = false)
	closed.emit()


func apply_layout() -> void:
	if not is_open:
		return
	var area := ctx.clear_rect()
	var compact := ctx.compact
	# (phones: slimmer edges, the preview beside the words)
	_panel.set_padding(14.0 if compact else 20.0, 10.0 if compact else 16.0, 14.0 if compact else 20.0, 10.0 if compact else 16.0)
	_v.add_theme_constant_override("separation", 8 if compact else 12)
	_sub.add_theme_font_size_override("font_size", 10 if compact else 12)
	var list_w := LIST_W_PHONE if compact else LIST_W
	var chrome_h := (34.0 + 8.0 + 20.0) if compact else (40.0 + 12.0 + 32.0)
	var body_h := floorf(area.size.y - chrome_h - 8.0)
	# (the list's own height: its headings and rows, with their gaps)
	var rows := GROUPS.size() + ArsenalData.ITEMS.size()
	var list_h := GROUPS.size() * 18.0 + ArsenalData.ITEMS.size() * (ROW_H_PHONE if compact else ROW_H) + (rows - 1) * 4.0 + 6.0
	var dw: float
	var dh: float
	if compact:
		dw = clampf(area.size.x - list_w - 14.0 - 40.0, 300.0, 560.0)
		dh = clampf(body_h, 180.0, 300.0)
	else:
		dw = DETAIL_W
		dh = clampf(maxf(list_h, PREVIEW_H + 250.0), 320.0, maxf(320.0, body_h))
	_list_host.custom_minimum_size = Vector2(list_w, minf(dh, maxf(list_h, 120.0)) if compact else dh)
	_detail_host.custom_minimum_size = Vector2(dw, dh)
	_balance.text = commas(_stars())
	_build_list()
	_refresh_list()
	_build_detail()
	_panel.reset_size()
	var sz := _panel.get_combined_minimum_size()
	var p := area.position + (area.size - sz) * 0.5
	_panel.position = Vector2(floorf(p.x + 0.5), floorf(maxf(p.y, area.position.y + 4.0) + 0.5))
	_panel.size = sz
