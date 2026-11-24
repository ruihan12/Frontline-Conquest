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
var _chest: ChestView
var _rev: Control
var _rt := 0.0
var _rids: Array = []
var _rchest: ChestView
var _rglow: TextureRect
var _rrays: TextureRect
var _rflash: ColorRect
var _rbox: Control
var _rcards: Array = []
var _rdone := false
var _rcol := Color.WHITE
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
	_chest = ChestView.new()
	_chest.size = Vector2(CRATE_W - 32.0, 150)
	var glow := TextureRect.new()
	glow.texture = load("res://assets/rw/crate/glow.svg")
	glow.modulate = Color(GOLD, 0.5)
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.size = Vector2(190, 150)
	glow.position = Vector2((CRATE_W - 32.0 - 190.0) * 0.5, 0)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.add_child(glow)
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
		var left := total - owned.size()
		var many := mini(mini(10, int(stars / CosmeticsRules.CRATE_COST)), left)
		var openb := UITheme.button("%s" % UICtx.commas(CosmeticsRules.CRATE_COST), "PrimaryButton", "star", 48.0)
		openb.custom_minimum_size = Vector2(CRATE_W - 32.0, 48)
		openb.disabled = stars < CosmeticsRules.CRATE_COST
		openb.pressed.connect(func() -> void: _start_open(1))
		v.add_child(openb)
		if left >= 2:
			var tenb := UITheme.button("Open ×%d  ·  %s" % [maxi(many, 10) if many < 2 else many, UICtx.commas(CosmeticsRules.CRATE_COST * (many if many >= 2 else mini(10, left)))], "GhostButton", "", 38.0)
			tenb.custom_minimum_size = Vector2(CRATE_W - 32.0, 38)
			tenb.disabled = many < 2
			tenb.pressed.connect(func() -> void: _start_open(many))
			v.add_child(tenb)
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


func _start_open(n: int) -> void:
	var se = _session()
	if se == null:
		return
	var ids: Array = se.open_crates(n)
	if ids.is_empty():
		_note = "Not enough Stars"
		_refresh()
		return
	var best := 9
	var rank := {"legendary": 0, "epic": 1, "rare": 2, "common": 3}
	for id in ids:
		var it = CosmeticsRules.item(id)
		best = mini(best, int(rank.get(str(it.rarity), 3)))
		_tab = 1 if it.kind == "flag" else 0
	_rcol = _rarity_col(CosmeticsRules.item(ids[0]))
	for id in ids:
		var it2 = CosmeticsRules.item(id)
		if int(rank.get(str(it2.rarity), 3)) == best:
			_rcol = _rarity_col(it2)
			break
	_rids = ids
	_note = ""
	_build_show()
	ctx.sfx("open")


## The opening: the chest rattles, bursts open, then the item (or all of them) comes out.
func _build_show() -> void:
	if _rev != null:
		_rev.queue_free()
	_rt = 0.0
	_rdone = false
	_rev = Control.new()
	_rev.name = "CrateShow"
	_rev.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rev.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = UITheme.rgba(0.0, 0.01, 0.03, 0.9)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rev.add_child(dim)
	var area := ctx.clear_rect()
	var cx := area.position.x + area.size.x * 0.5
	var cy := area.position.y + area.size.y * 0.5
	_rbox = Control.new()
	_rbox.position = Vector2(cx, cy)
	_rbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rev.add_child(_rbox)
	_rrays = TextureRect.new()
	_rrays.texture = load("res://assets/rw/crate/rays.svg")
	_rrays.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_rrays.size = Vector2(900, 900)
	_rrays.position = Vector2(-450, -450)
	_rrays.pivot_offset = Vector2(450, 450)
	_rrays.modulate = Color(_rcol, 0.0)
	_rrays.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rbox.add_child(_rrays)
	_rglow = TextureRect.new()
	_rglow.texture = load("res://assets/rw/crate/glow.svg")
	_rglow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_rglow.size = Vector2(520, 420)
	_rglow.position = Vector2(-260, -210)
	_rglow.modulate = Color(_rcol, 0.0)
	_rglow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rbox.add_child(_rglow)
	_rchest = ChestView.new()
	_rchest.running = false
	_rchest.size = Vector2(360, 330)
	_rchest.position = Vector2(-180, -175)
	_rchest.pivot_offset = Vector2(180, 175)
	_rbox.add_child(_rchest)
	_rflash = ColorRect.new()
	_rflash.color = Color(1, 1, 1, 0.0)
	_rflash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rflash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rev.add_child(_rflash)
	_rev.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			if _rdone:
				_end_show()
			elif _rt > 0.4:
				_rt = maxf(_rt, 2.6))  # skip ahead to the reveal
	add_child(_rev)
	_rcards.clear()
	set_process(true)


func _end_show() -> void:
	if _rev != null:
		_rev.queue_free()
		_rev = null
	_rchest = null
	_rcards.clear()
	_refresh()


func _reveal_cards() -> void:
	var n := _rids.size()
	var area := ctx.clear_rect()
	var per_row := 1 if n == 1 else (5 if n > 6 else 3)
	var cw := 190.0 if n == 1 else 112.0
	var chh := 230.0 if n == 1 else 138.0
	var gap := 12.0
	var rows := int(ceil(float(n) / per_row))
	var total_h := rows * chh + (rows - 1) * gap
	for i in n:
		var it = CosmeticsRules.item(_rids[i])
		var rc := _rarity_col(it)
		var r := i / per_row
		var cols_in_row := mini(per_row, n - r * per_row)
		var c := i % per_row
		var row_w := cols_in_row * cw + (cols_in_row - 1) * gap
		var card := Control.new()
		card.size = Vector2(cw, chh)
		card.pivot_offset = card.size * 0.5
		card.position = Vector2(c * (cw + gap) - row_w * 0.5, r * (chh + gap) - total_h * 0.5 - 20.0)
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var bg := Panel.new()
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bg.add_theme_stylebox_override("panel", UITheme.flat(UITheme.c(rc, 0.16), 14, rc, 2))
		card.add_child(bg)
		var tr := TextureRect.new()
		tr.texture = _skin_tex(it) if it.kind == "skin" else _flag_tex(it)
		tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST if it.kind == "skin" else CanvasItem.TEXTURE_FILTER_LINEAR
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.position = Vector2(12, 12)
		tr.size = Vector2(cw - 24.0, chh - (70.0 if n == 1 else 52.0))
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(tr)
		var nm := UITheme.label(str(it.name), 18 if n == 1 else 12, 800, UITheme.TEXT)
		nm.position = Vector2(6, chh - (54.0 if n == 1 else 38.0))
		nm.size = Vector2(cw - 12.0, 22 if n == 1 else 16)
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nm.clip_text = true
		nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(nm)
		var rl := UITheme.label(str(CosmeticsRules.rarity(str(it.rarity)).name).to_upper(), 12 if n == 1 else 10, 700, rc)
		rl.position = Vector2(6, chh - (28.0 if n == 1 else 20.0))
		rl.size = Vector2(cw - 12.0, 16)
		rl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		rl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(rl)
		card.modulate.a = 0.0
		card.scale = Vector2(0.4, 0.4)
		_rbox.add_child(card)
		_rcards.append(card)
	var hint := UITheme.label("Click to continue", 12, 600, UITheme.TEXT_3)
	hint.position = Vector2(-80, total_h * 0.5 + 10.0)
	hint.size = Vector2(160, 16)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.name = "Hint"
	hint.modulate.a = 0.0
	_rbox.add_child(hint)


func _process(dt: float) -> void:
	if _rev == null:
		return
	_rt += dt
	var t := _rt
	var shake := clampf(t / 1.5, 0.0, 1.0)
	var lid := 0.0
	if t > 1.5:
		shake = maxf(0.0, 1.0 - (t - 1.5) / 0.15)
		var k := clampf((t - 1.5) / 0.45, 0.0, 1.0)
		lid = 1.0 - pow(1.0 - k, 3.0)
	if _rchest != null:
		_rchest.pose(shake, lid, t)
	_rglow.modulate.a = clampf(shake * 0.5 + lid * 0.5, 0.0, 1.0)
	_rrays.modulate.a = lid * 0.4
	_rrays.rotation_degrees += dt * 14.0
	# the burst
	if t > 1.5 and t < 2.1:
		_rflash.color.a = (1.0 - (t - 1.5) / 0.6) * 0.55 if t > 1.55 else (t - 1.5) / 0.05 * 0.55
	else:
		_rflash.color.a = 0.0
	if t >= 1.95 and _rcards.is_empty() and not _rids.is_empty():
		_reveal_cards()
		ctx.sfx("unlock")
	if not _rcards.is_empty():
		var n := _rcards.size()
		for i in n:
			var q := clampf((t - 1.95 - i * 0.09) / 0.35, 0.0, 1.0)
			var e := 1.0 - pow(1.0 - q, 3.0)
			var cd: Control = _rcards[i]
			cd.modulate.a = e
			cd.scale = Vector2.ONE * (0.4 + 0.6 * e + sin(q * PI) * 0.08)
		if _rchest != null:
			_rchest.modulate.a = clampf(1.0 - (t - 2.0) / 0.4, 0.0, 1.0)
		var h = _rbox.get_node_or_null("Hint")
		if h != null:
			h.modulate.a = clampf((t - 1.95 - n * 0.09 - 0.5) / 0.4, 0.0, 1.0)
		if t > 1.95 + n * 0.09 + 0.35:
			_rdone = true
