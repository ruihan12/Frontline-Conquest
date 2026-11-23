# The Crates window (port of the crate + Locker of src/client/UI, simplified): open a cosmetic crate for
# Stars (upstream: Robux), see your own odds first, and put the skins and flags you own on.
# A skin tiles over your territory on the map; a flag is collected (the map's name plates do not show
# flags in this port).
class_name Crates
extends Control

signal closed

const GOLD := Color8(255, 200, 61)
const MUTED := Color8(170, 182, 211)
const NIGHT := Color8(8, 12, 26)
const SKIN_PX := 46.0
const FLAG_W := 56.0

var ctx: UICtx
var g
var is_open := false
var _dim: ColorRect
var _panel: GlassPanel
var _v: VBoxContainer
var _balance: Label
var _body: VBoxContainer
var _note := ""
var _flash_id := ""


func _init(c: UICtx, main) -> void:
	ctx = c
	g = main
	name = "Crates"
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
	var icon := UITheme.icon_rect("crate", 26.0, UITheme.GOLD)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(icon)
	var tv := UITheme.vbox(0)
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tv.add_child(UITheme.label("CRATES", 20, 800, UITheme.TEXT, 3))
	tv.add_child(UITheme.label("Territory skins and country flags. Never a duplicate.", 12, 500, UITheme.TEXT_2))
	head.add_child(tv)
	_balance = UITheme.label("0", 16, 800, UITheme.GOLD)
	_balance.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(UITheme.icon_rect("star", 16.0, UITheme.GOLD))
	head.add_child(_balance)
	var x := UITheme.button("", "GhostButton", "close", 34.0)
	x.expand_icon = true
	x.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	x.custom_minimum_size = Vector2(34, 34)
	x.add_theme_constant_override("icon_max_width", 13)
	x.pressed.connect(close)
	head.add_child(x)
	_v.add_child(head)
	_body = UITheme.vbox(10)
	_v.add_child(_body)


func _session():
	return ctx.session


func open() -> void:
	move_to_front()
	if not is_open:
		is_open = true
		visible = true
		modulate.a = 1.0
		_panel.modulate.a = 1.0
		_dim.modulate.a = 0.0
		UIFx.fade(_dim, 1.0, 0.2)
		UIFx.pop_in(_panel, 0.0, 0.94, 0.3)
		ctx.sfx("open")
	_note = ""
	_flash_id = ""
	_refresh()


func close() -> void:
	if not is_open:
		return
	is_open = false
	ctx.sfx("close")
	var t := create_tween().set_parallel(true)
	t.tween_property(_dim, "modulate:a", 0.0, 0.15)
	t.tween_property(_panel, "modulate:a", 0.0, 0.15)
	t.chain().tween_callback(func() -> void:
		if not is_open:
			visible = false)
	closed.emit()


func apply_layout() -> void:
	if not is_open:
		return
	_refresh()


func _skin_chip(it: Dictionary, owned: bool, equipped: bool) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(SKIN_PX + 20.0, SKIN_PX + 24.0)
	b.focus_mode = Control.FOCUS_NONE
	var rc := CosmeticsRules.rarity(str(it.rarity))
	var col := Color.hex((int(rc.color) << 8) | 0xFF)
	b.add_theme_stylebox_override("normal", UITheme.flat(UITheme.rgba(0.1, 0.13, 0.22, 1.0) if owned else UITheme.rgba(0.06, 0.07, 0.12, 1.0), 8, GOLD if equipped else col.darkened(0.35), 2 if equipped else 1))
	b.add_theme_stylebox_override("hover", UITheme.flat(UITheme.rgba(0.14, 0.18, 0.3, 1.0), 8, col, 1))
	b.add_theme_stylebox_override("pressed", UITheme.flat(UITheme.rgba(0.14, 0.18, 0.3, 1.0), 8, col, 1))
	b.tooltip_text = "%s (%s)%s" % [it.name, rc.name, "" if owned else ", not owned"]
	var tr := TextureRect.new()
	tr.texture = _skin_tex(it)
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.position = Vector2(10, 8)
	tr.size = Vector2(SKIN_PX, SKIN_PX)
	tr.modulate.a = 1.0 if owned else 0.3
	b.add_child(tr)
	var l := UITheme.label(str(it.name), 9, 700, col if owned else MUTED)
	l.position = Vector2(2, SKIN_PX + 10.0)
	l.size = Vector2(SKIN_PX + 16.0, 12)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(l)
	if owned:
		var sid: String = it.id
		b.pressed.connect(func() -> void:
			var s = _session()
			if s != null:
				s.equip("skin", "" if str(g.save.cosmetics.skin) == sid else sid)
				ctx.sfx("click")
			_refresh())
	return b


## A skin's pattern as a small image: your colour (or the player colour) and the secondary over it.
func _skin_tex(it: Dictionary) -> Texture2D:
	var m := CosmeticsRules.mask_of(it)
	var base := Color(0.30, 0.55, 0.85)
	var sec := CosmeticsRules.secondary(it, base)
	var n := 16
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var sc := int(it.scale)
	for y in n:
		for x in n:
			var bit: int = m.bits[(((y >> sc) % int(m.h)) * int(m.w)) + ((x >> sc) % int(m.w))]
			img.set_pixel(x, y, sec if bit == 1 else base)
	return ImageTexture.create_from_image(img)


func _flag_chip(it: Dictionary, owned: bool, equipped: bool) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(FLAG_W + 10.0, 40.0)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_stylebox_override("normal", UITheme.flat(UITheme.rgba(0.1, 0.13, 0.22, 1.0), 6, GOLD if equipped else UITheme.rgba(1, 1, 1, 0.08), 2 if equipped else 1))
	b.add_theme_stylebox_override("hover", UITheme.flat(UITheme.rgba(0.14, 0.18, 0.3, 1.0), 6, UITheme.rgba(1, 1, 1, 0.3), 1))
	b.add_theme_stylebox_override("pressed", UITheme.flat(UITheme.rgba(0.14, 0.18, 0.3, 1.0), 6, UITheme.rgba(1, 1, 1, 0.3), 1))
	b.tooltip_text = str(it.name)
	var tex = load("res://assets/rw/flags/%s.svg" % it.code)
	var tr := TextureRect.new()
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.position = Vector2(5, 5)
	tr.size = Vector2(FLAG_W, 30)
	tr.modulate.a = 1.0 if owned else 0.25
	b.add_child(tr)
	if owned:
		var fid: String = it.id
		b.pressed.connect(func() -> void:
			var s = _session()
			if s != null:
				s.equip("flag", "" if str(g.save.cosmetics.flag) == fid else fid)
			_refresh())
	return b


func _refresh() -> void:
	for ch in _body.get_children():
		ch.queue_free()
		_body.remove_child(ch)
	var s = _session()
	if s == null:
		return
	var co: Dictionary = g.save.cosmetics
	var stars := int(g.save.stars)
	_balance.text = UICtx.commas(stars)
	var owned: Dictionary = co.owned
	# the crate row
	var row := UITheme.hbox(14)
	var ic := UITheme.icon_rect("crate", 54.0, UITheme.GOLD)
	row.add_child(ic)
	var info := UITheme.vbox(2)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var odds := CosmeticsRules.odds(owned)
	var parts := []
	for e: Dictionary in odds:
		if float(e.odds) > 0.0:
			parts.append("%s %d%%" % [e.rarity.name, int(round(float(e.odds) * 100.0))])
	info.add_child(UITheme.label("Cosmetic crate", 16, 800, UITheme.TEXT))
	info.add_child(UITheme.label("Your odds: " + (", ".join(parts) if not parts.is_empty() else "you own everything"), 12, 500, UITheme.TEXT_2))
	var total := CosmeticsRules.all().size()
	info.add_child(UITheme.label("%d of %d collected" % [owned.size(), total], 12, 500, UITheme.TEXT_2))
	row.add_child(info)
	var can := stars >= CosmeticsRules.CRATE_COST and not parts.is_empty()
	var openb := UITheme.button("OPEN  ·  %s ★" % UICtx.commas(CosmeticsRules.CRATE_COST), "PrimaryButton", "", 44.0)
	openb.disabled = not can
	openb.pressed.connect(func() -> void:
		if s.open_crate():
			_flash_id = s.last_crate_item
			ctx.sfx("unlock")
			_note = ""
		else:
			_note = "Not enough Stars"
		_refresh())
	row.add_child(openb)
	_body.add_child(row)
	if _flash_id != "":
		var it = CosmeticsRules.item(_flash_id)
		var rc := CosmeticsRules.rarity(str(it.rarity))
		var col := Color.hex((int(rc.color) << 8) | 0xFF)
		var l := UITheme.label("You got  %s  ·  %s" % [it.name, rc.name], 18, 800, col)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_body.add_child(l)
	elif _note != "":
		_body.add_child(UITheme.label(_note, 13, 700, UITheme.TEXT_2))
	# the locker
	_body.add_child(UITheme.label("SKINS  (tap to wear, tap again to take off)", 11, 800, MUTED, 2))
	var sk := HFlowContainer.new()
	sk.add_theme_constant_override("h_separation", 8)
	sk.add_theme_constant_override("v_separation", 8)
	for it: Dictionary in RWCosmetics.SKINS:
		sk.add_child(_skin_chip(it, owned.has(it.id), str(co.skin) == it.id))
	_body.add_child(sk)
	_body.add_child(UITheme.label("FLAGS", 11, 800, MUTED, 2))
	var fs := ScrollContainer.new()
	fs.custom_minimum_size = Vector2(0, 150)
	fs.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var fl := HFlowContainer.new()
	fl.add_theme_constant_override("h_separation", 6)
	fl.add_theme_constant_override("v_separation", 6)
	fl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var shown := 0
	for f: Array in RWCosmetics.FLAGS:
		var it = CosmeticsRules.item("flag_" + str(f[0]))
		if owned.has(it.id):
			fl.add_child(_flag_chip(it, true, str(co.flag) == it.id))
			shown += 1
	if shown == 0:
		fl.add_child(UITheme.label("None yet. Open a crate.", 12, 500, UITheme.TEXT_2))
	fs.add_child(fl)
	_body.add_child(fs)
	await get_tree().process_frame
	if not is_open:
		return
	var area := ctx.clear_rect()
	_panel.custom_minimum_size = Vector2(minf(area.size.x - 24.0, 720.0), 0)
	_panel.reset_size()
	var sz := _panel.get_combined_minimum_size()
	sz.y = minf(sz.y, area.size.y - 16.0)
	var p := area.position + (area.size - sz) * 0.5
	_panel.position = Vector2(floorf(p.x + 0.5), floorf(maxf(p.y, area.position.y + 4.0) + 0.5))
	_panel.size = sz
