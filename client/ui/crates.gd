# The Locker (port of src/client/UI/Locker.luau): the crate card on the left (chest, odds, open button),
# Skins / Flags tabs with the item grid on the right. A crate costs Stars here (upstream: Robux); the
# opening show (CrateOpening, a 3D chest) is a plain reveal in the card.
# A skin tiles over your territory on the map; a flag is collected (the map's name plates do not show
# flags in this port).
class_name Crates
extends Control

signal closed

const GOLD := Color8(255, 200, 61)
const MUTED := Color8(170, 182, 211)
const NIGHT := Color8(8, 12, 26)
const CRATE_W := 250.0
const GRID := Vector2(560, 430)
const SKIN_CARD := Vector2(116, 128)
const FLAG_CARD := Vector2(104, 96)

var ctx: UICtx
var g
var is_open := false
var _dim: ColorRect
var _panel: GlassPanel
var _v: VBoxContainer
var _count: Label
var _body: HBoxContainer
var _tab := 0
var _chest_t := 0.0
var _chest: TextureRect
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
	_dim.color = UITheme.rgba(0.01, 0.015, 0.05, 0.78)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and not _panel.get_global_rect().has_point(e.global_position):
			close())
	add_child(_dim)
	_panel = GlassPanel.new(22.0, 20.0, 18, true, 34)
	_panel.set_tint(UITheme.rgba(0.045, 0.065, 0.13, 0.96))
	add_child(_panel)
	_v = UITheme.vbox(12)
	_panel.add_child(_v)
	var head := UITheme.hbox(12)
	var title := UITheme.label("LOCKER", 20, 800, UITheme.TEXT, 3)
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(title)
	_count = UITheme.label("", 13, 600, UITheme.TEXT_2)
	_count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_count)
	var x := UITheme.button("", "GhostButton", "", 34.0)
	x.custom_minimum_size = Vector2(34, 34)
	var xd := Control.new()
	xd.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	xd.mouse_filter = Control.MOUSE_FILTER_IGNORE
	xd.draw.connect(func() -> void:
		var mid := xd.size * 0.5
		var d := 6.5
		xd.draw_line(mid + Vector2(-d, -d), mid + Vector2(d, d), UITheme.TEXT_2, 2.0, true)
		xd.draw_line(mid + Vector2(-d, d), mid + Vector2(d, -d), UITheme.TEXT_2, 2.0, true))
	x.add_child(xd)
	x.pressed.connect(close)
	head.add_child(x)
	_v.add_child(head)
	_body = UITheme.hbox(16)
	_v.add_child(_body)
	_v.add_child(UITheme.label("Flags: Wikimedia Commons (public domain)", 11, 500, UITheme.TEXT_3))


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


func _process(dt: float) -> void:
	if not is_open or _chest == null:
		return
	_chest_t += dt
	_chest.position.y = sin(_chest_t * 2.0) * 3.0
	var w := fmod(_chest_t, 2.4)
	_chest.rotation_degrees = sin(w * 26.0) * (4.0 * (1.0 - w / 0.6)) if w < 0.6 else 0.0


func _rarity_col(it: Dictionary) -> Color:
	return Color.hex((int(CosmeticsRules.rarity(str(it.rarity)).color) << 8) | 0xFF)


func _flag_tex(it: Dictionary) -> Texture2D:
	return load("res://assets/rw/flags/%s.svg" % it.code)


## One grid card (it == null: "None").
func _card(it, slot: String, owned_map: Dictionary, wearing: String) -> Control:
	var owned: bool = it == null or owned_map.has(it.id)
	var equipped: bool = (wearing == "") if it == null else (wearing == str(it.id))
	var cell := SKIN_CARD if slot == "skin" else FLAG_CARD
	var b := Button.new()
	b.custom_minimum_size = cell
	b.focus_mode = Control.FOCUS_NONE
	var bg := Color(1, 1, 1, 0.06)
	var st := UITheme.flat(bg, 10, GOLD if equipped else Color(1, 1, 1, 0.12), 2 if equipped else 1)
	b.add_theme_stylebox_override("normal", st)
	b.add_theme_stylebox_override("hover", UITheme.flat(Color(1, 1, 1, 0.12), 10, GOLD if equipped else Color(1, 1, 1, 0.2), 2 if equipped else 1))
	b.add_theme_stylebox_override("pressed", UITheme.flat(Color(1, 1, 1, 0.12), 10, GOLD, 2))
	var tr := TextureRect.new()
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.position = Vector2(10, 10)
	tr.size = Vector2(cell.x - 20.0, cell.y - 46.0)
	if it != null:
		if slot == "skin":
			tr.texture = _skin_tex(it)
			tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		else:
			tr.texture = _flag_tex(it)
		tr.modulate.a = 1.0 if owned else 0.3
	b.add_child(tr)
	var nm := UITheme.label("None" if it == null else str(it.name), 12, 700, UITheme.TEXT if owned else Color(1, 1, 1, 0.55))
	nm.position = Vector2(8, cell.y - 34.0)
	nm.size = Vector2(cell.x - 16.0, 16)
	nm.clip_text = true
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(nm)
	var sub_col := Color8(150, 158, 180)
	var sub := ""
	if equipped:
		sub = "WEARING"
		sub_col = UITheme.AMBER
	elif not owned:
		sub = "LOCKED"
	elif it != null:
		sub = str(CosmeticsRules.rarity(str(it.rarity)).name).to_upper()
		sub_col = _rarity_col(it)
	var sl := UITheme.label(sub, 10, 500, sub_col)
	sl.position = Vector2(8, cell.y - 18.0)
	sl.size = Vector2(cell.x - 16.0, 12)
	sl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(sl)
	b.pressed.connect(func() -> void:
		var se = _session()
		if not owned or se == null:
			ctx.sfx("deny", -6.0)
			return
		ctx.sfx("click")
		se.equip(slot, "" if it == null else it.id)
		_refresh())
	return b


func _crate_card(s, owned: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(CRATE_W, 0)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_theme_stylebox_override("panel", UITheme.flat(UITheme.c(UITheme.GOLD, 0.07), 16, UITheme.c(UITheme.GOLD, 0.45), 1, 16.0, 14.0))
	var v := UITheme.vbox(8)
	card.add_child(v)
	var art := Control.new()
	art.custom_minimum_size = Vector2(CRATE_W - 32.0, 150)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.clip_contents = false
	v.add_child(art)
	var won = CosmeticsRules.item(_flash_id) if _flash_id != "" else null
	_chest = null
	if won != null:
		# the reveal: the item in its rarity's colour
		var rc := _rarity_col(won)
		var pic := TextureRect.new()
		pic.texture = _skin_tex(won) if won.kind == "skin" else _flag_tex(won)
		pic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST if won.kind == "skin" else CanvasItem.TEXTURE_FILTER_LINEAR
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.size = Vector2(CRATE_W - 32.0, 110)
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		art.add_child(pic)
		var nl := UITheme.label("NEW!  " + str(won.name), 15, 800, rc)
		nl.position = Vector2(0, 118)
		nl.size = Vector2(CRATE_W - 32.0, 20)
		nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		art.add_child(nl)
		var rl := UITheme.label(str(CosmeticsRules.rarity(str(won.rarity)).name).to_upper(), 11, 700, rc)
		rl.position = Vector2(0, 136)
		rl.size = Vector2(CRATE_W - 32.0, 14)
		rl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		art.add_child(rl)
	else:
		var glow := TextureRect.new()
		glow.texture = load("res://assets/rw/crate/glow.svg")
		glow.modulate = Color(GOLD, 0.5)
		glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		glow.size = Vector2(190, 150)
		glow.position = Vector2((CRATE_W - 32.0 - 190.0) * 0.5, 0)
		glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		art.add_child(glow)
		_chest = TextureRect.new()
		_chest.texture = load("res://assets/rw/crate/crate_icon.svg")
		_chest.modulate = Color8(150, 104, 62)
		_chest.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_chest.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_chest.size = Vector2(120, 120)
		_chest.pivot_offset = Vector2(60, 60)
		_chest.position = Vector2((CRATE_W - 32.0 - 120.0) * 0.5, 15)
		_chest.mouse_filter = Control.MOUSE_FILTER_IGNORE
		art.add_child(_chest)
	var t := UITheme.label("COSMETIC CRATE", 16, 800, UITheme.TEXT, 2)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var sub := UITheme.label("A territory skin or a flag you don't own yet", 12, 500, UITheme.TEXT_2)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.custom_minimum_size = Vector2(CRATE_W - 32.0, 0)
	v.add_child(sub)
	var total := CosmeticsRules.all().size()
	var all_owned := owned.size() >= total
	var odds := CosmeticsRules.odds(owned)
	if not all_owned:
		var ob := UITheme.vbox(3)
		for e: Dictionary in odds:
			var row := UITheme.hbox(8)
			var sw := UITheme.swatch(Color.hex((int(e.rarity.color) << 8) | 0xFF), 10.0, 3)
			sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(sw)
			var nm := UITheme.label(str(e.rarity.name), 12, 600, UITheme.TEXT)
			nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(nm)
			row.add_child(UITheme.label("%d%%" % int(round(float(e.odds) * 100.0)) if int(e.left) > 0 else "all owned", 12, 700, UITheme.TEXT))
			ob.add_child(row)
		v.add_child(ob)
		var stars := int(g.save.stars)
		var openb := UITheme.button("%s" % UICtx.commas(CosmeticsRules.CRATE_COST), "PrimaryButton", "star", 48.0)
		openb.custom_minimum_size = Vector2(CRATE_W - 32.0, 48)
		openb.disabled = stars < CosmeticsRules.CRATE_COST
		openb.pressed.connect(func() -> void:
			if s.open_crate():
				_flash_id = s.last_crate_item
				var it = CosmeticsRules.item(_flash_id)
				_tab = 1 if it.kind == "flag" else 0
				ctx.sfx("unlock")
				_note = ""
			else:
				_note = "Not enough Stars"
			_refresh())
		v.add_child(openb)
		_note_line(v, _note if _note != "" else "You have %s Stars  ·  Never a duplicate" % UICtx.commas(stars))
	else:
		_note_line(v, "You own every skin and flag.")
	return card


func _note_line(v: VBoxContainer, text: String) -> void:
	var n := UITheme.label(text, 11, 500, UITheme.TEXT_3)
	n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	n.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	n.custom_minimum_size = Vector2(CRATE_W - 32.0, 0)
	v.add_child(n)


func _refresh() -> void:
	for ch in _body.get_children():
		ch.queue_free()
		_body.remove_child(ch)
	var s = _session()
	if s == null:
		return
	var co: Dictionary = g.save.cosmetics
	var owned: Dictionary = co.owned
	_count.text = "%d of %d unlocked" % [owned.size(), CosmeticsRules.all().size()]
	_body.add_child(_crate_card(s, owned))
	var right := UITheme.vbox(10)
	_body.add_child(right)
	var tabs := UITheme.hbox(6)
	var names := ["Skins", "Flags"]
	for i in 2:
		var chip := UITheme.button(names[i], "ChipButton", "", 32.0)
		chip.toggle_mode = true
		chip.set_pressed_no_signal(i == _tab)
		chip.add_theme_font_size_override("font_size", 12)
		chip.pressed.connect(func() -> void:
			_tab = i
			_refresh())
		tabs.add_child(chip)
	right.add_child(tabs)
	var slot := "skin" if _tab == 0 else "flag"
	var area := ctx.clear_rect()
	var gw := clampf(area.size.x - CRATE_W - 110.0, 300.0, GRID.x)
	var gh := clampf(area.size.y - 170.0, 120.0, GRID.y)
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(gw, gh)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var fl := HFlowContainer.new()
	fl.add_theme_constant_override("h_separation", 8)
	fl.add_theme_constant_override("v_separation", 8)
	fl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(fl)
	right.add_child(sc)
	# None first, then owned (rarest first), then the rest
	var list: Array = []
	for it: Dictionary in CosmeticsRules.all():
		if it.kind == slot:
			list.append(it)
	var rank := {"legendary": 1, "epic": 2, "rare": 3, "common": 4}
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var oa := owned.has(a.id)
		var ob := owned.has(b.id)
		if oa != ob:
			return oa
		var ra: int = rank.get(str(a.rarity), 9)
		var rb: int = rank.get(str(b.rarity), 9)
		if ra != rb:
			return ra < rb
		return str(a.name) < str(b.name))
	var wearing := str(co[slot])
	fl.add_child(_card(null, slot, owned, wearing))
	for it: Dictionary in list:
		fl.add_child(_card(it, slot, owned, wearing))
	await get_tree().process_frame
	if not is_open:
		return
	_panel.reset_size()
	var sz := _panel.get_combined_minimum_size()
	sz.y = minf(sz.y, area.size.y - 8.0)
	var p := area.position + (area.size - sz) * 0.5
	_panel.position = Vector2(floorf(p.x + 0.5), floorf(maxf(p.y, area.position.y + 4.0) + 0.5))
	_panel.size = sz
