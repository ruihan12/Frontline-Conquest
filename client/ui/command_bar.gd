# Port of src/client/UI/CommandBar.luau (scripts/ui/command_bar.gd, UICommandBar).
# Bottom command bar: nation chip, troops (with cap, growth and fill), the attack-ratio slider, gold
# (with income, next to the slots it buys) and the ten build / nuke slots. Re-flows between a single
# row (wide desktop), two rows (laptop / tablet) and a slim phone strip (icons + numbers, a short
# slider and a Build toggle; the slots live in a tray and the details in a tap-for-info card).
#
# The Arsenal: one gold SHOP slot closes the row and opens the Arsenal; a kind the player has
# unlocked gets a slot of its own before it, a locked one has none.
#
# Members read by UIRoot / UIInteract: panel, tray, buttons, _place_chip, _slider, _tray_btn, _flow.
# Per frame: update(dt).
class_name CommandBar
extends Control

signal build_chosen(kind: String)
signal cancel_placement
## The bar's footprint changed (tray opened/closed, placement chip shown/hidden).
signal footprint_changed
## Phone strip: the troops / gold numbers were tapped (show the details card).
signal stats_tapped
## The SHOP slot was pressed (key: the locked item whose card was, null for the slot itself).
signal arsenal_wanted(key, from)
## The row gained or lost a slot (an Arsenal kind was unlocked).
signal slots_changed

const WIDE := 0
const STACKED := 1
const COMPACT := 2
## Phone tray: a slot is never narrower than this (then the tray takes a second row).
const TRAY_SLOT_MIN := TrayFit.SLOT_MIN
## The SHOP slot outside the phone tray, with nothing locked to show.
const SHOP_W := 58.0
## Phones: the width of one stop of the Attack bar (a finger's target; the strip is 44 tall).
const STOP_TOUCH_W := 38.0

var ctx: UICtx
## the Arsenal kinds with a slot (the unlocked ones), as last arranged: "artillery,mega"
var _arsenal_sig := ""
var buttons := {}  # kind -> BuildButton
var _flow := -1
var _root_box: Control = null
var _tray_open := false
var _placing := ""
var _rate := 0.0
## Whether the troop rate is rising, and the last rate seen (see sample_growth).
var _rate_up := true
var _last_growth := NAN
var _poll := 0.0
var _buttons_dirty := true
## Port-only slots (not in upstream) that follow the nukes in the row: the ICBM toggle.
var port_slots: Array = []

var panel: GlassPanel
var tray: GlassPanel
var _nation: HBoxContainer
var _swatch: PanelContainer
var _name: Label
var _crown: TextureRect
var _land: Label
var _troops_box: VBoxContainer
var _growth: Label
var _troops: CountLabel
var _troops_cap: Label
var _troops_bar: FillBar
var _committed: Label
var _gold_box: VBoxContainer
var _income: Label
var _gold: CountLabel
var _ratio_box: VBoxContainer
var _ratio_pct: Label
var _ratio_head: HBoxContainer
var _slider: RatioSlider
var _ratio_inline: Label
var _ratio_inline_box: VBoxContainer
var _ratio_sends: Label
var _ratio_line: HBoxContainer
var _ratio_sub: Label
var _m_stats: Button
var _m_stats_box: HBoxContainer
var _m_troops: CountLabel
var _m_growth: Label
var _m_troops_bar: FillBar
var _m_gold: CountLabel
var _m_ratio: HBoxContainer
var _builds: HBoxContainer
var _builds2: HBoxContainer
var _tray_v: VBoxContainer
var _nuke_div: ColorRect
var _nuke_wrap: MarginContainer
var _shop: ShopSlot
var _arsenal_wrap: MarginContainer
var _tray_btn: Button
var _tray_caption: Label = null
var _place_chip: GlassPanel
var _place_text: Label


static func _spacer() -> Control:
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return sp


func _init(c: UICtx) -> void:
	ctx = c
	name = "CommandBar"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel = GlassPanel.new(18.0, 12.0, UITheme.R_LG, true, 22)
	add_child(panel)
	_build_sections()
	c.ratio_changed.connect(func(_r: float) -> void: _refresh_ratio())


func _build_sections() -> void:
	# Nation chip
	_nation = UITheme.hbox(10)
	_swatch = UITheme.swatch(UITheme.AMBER, 14.0, 4)
	_nation.add_child(_swatch)
	var nv := UITheme.vbox(0)
	nv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var name_row := UITheme.hbox(6)
	_name = UITheme.label("Commander", 15, 700)
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name.custom_minimum_size = Vector2(96, 0)
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(_name)
	_crown = UITheme.icon_rect("crown", 14.0, UITheme.GOLD)
	_crown.modulate.a = 0.0
	name_row.add_child(_crown)
	nv.add_child(name_row)
	_land = UITheme.label("0.0% of the world", 12, 500, UITheme.TEXT_2)
	nv.add_child(_land)
	_nation.add_child(nv)
	_nation.custom_minimum_size = Vector2(150, 0)

	# Troops
	_troops_box = UITheme.vbox(3)
	var tr := UITheme.hbox(6)
	tr.add_child(UITheme.icon_rect("troops", 12.0, UITheme.TEXT_3))
	tr.add_child(UITheme.caption("Troops"))
	tr.add_child(_spacer())
	_growth = UITheme.label("+0/s", 11, 700, UITheme.GREEN)
	tr.add_child(_growth)
	_troops_box.add_child(tr)
	var tv := UITheme.hbox(5)
	_troops = CountLabel.new(20, 700, UITheme.TEXT, UITheme.fmt_troops)
	tv.add_child(_troops)
	_troops_cap = UITheme.label("/ 0", 13, 500, UITheme.TEXT_3)
	_troops_cap.size_flags_vertical = Control.SIZE_SHRINK_END
	tv.add_child(_troops_cap)
	_troops_box.add_child(tv)
	var brow := UITheme.hbox(6)
	_troops_bar = FillBar.new(4.0, UITheme.CYAN)
	_troops_bar.custom_minimum_size = Vector2(40, 8)
	_troops_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_troops_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	brow.add_child(_troops_bar)
	# Troops committed to attacks: space is always reserved, so showing it never moves anything.
	_committed = UITheme.label("", 11, 700, UITheme.ORANGE)
	_committed.modulate.a = 0.0
	brow.add_child(_committed)
	_troops_box.add_child(brow)
	_troops_box.custom_minimum_size = Vector2(158, 0)

	# Gold (same shape as troops: caption row carries the rate, the value sits below)
	_gold_box = UITheme.vbox(3)
	var gr := UITheme.hbox(6)
	gr.add_child(UITheme.icon_rect("gold", 12.0, UITheme.TEXT_3))
	gr.add_child(UITheme.caption("Gold"))
	gr.add_child(_spacer())
	_income = UITheme.label("+0/s", 11, 700, UITheme.GREEN)
	gr.add_child(_income)
	_gold_box.add_child(gr)
	var gv := UITheme.hbox(6)
	_gold = CountLabel.new(20, 700, UITheme.GOLD, UITheme.fmt_num)
	gv.add_child(_gold)
	_gold_box.add_child(gv)
	_gold_box.custom_minimum_size = Vector2(118, 0)

	# Attack ratio
	_ratio_box = UITheme.vbox(2)
	var rr := UITheme.hbox(6)
	rr.add_child(UITheme.icon_rect("attack", 12.0, UITheme.TEXT_3))
	rr.add_child(UITheme.caption("Attack"))
	rr.add_child(_spacer())
	_ratio_pct = UITheme.label("35%", 13, 800, UITheme.AMBER)
	rr.add_child(_ratio_pct)
	_ratio_head = rr
	_ratio_box.add_child(rr)
	var line := UITheme.hbox(8)
	_slider = RatioSlider.new(ctx)
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(_slider)
	# (the phone strip's readout: "Sends" over the troops an order sends now)
	_ratio_inline = UITheme.label("Sends", 12, 600, UITheme.TEXT_3)
	_ratio_inline.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_ratio_inline.custom_minimum_size = Vector2(40, 0)
	_ratio_inline.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_ratio_inline.visible = false
	_ratio_inline_box = UITheme.vbox(0)
	_ratio_inline_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_ratio_inline_box.add_child(_ratio_inline)
	_ratio_sends = UITheme.label("", 13, 700, UITheme.TEXT)
	_ratio_sends.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_ratio_inline_box.add_child(_ratio_sends)
	line.add_child(_ratio_inline_box)
	_ratio_line = line
	_ratio_box.add_child(line)
	_ratio_sub = UITheme.label("Sends 0 troops", 11, 500, UITheme.TEXT_3)
	_ratio_box.add_child(_ratio_sub)
	_ratio_box.custom_minimum_size = Vector2(176, 0)
	_ratio_box.mouse_filter = Control.MOUSE_FILTER_PASS

	# Phone strip: troops and gold as icon + number inside one flat button (tap = details card).
	_m_stats = Button.new()
	_m_stats.theme_type_variation = "GhostButton"
	_m_stats.flat = true
	_m_stats.focus_mode = Control.FOCUS_NONE
	for st in ["normal", "hover", "pressed", "disabled", "focus"]:
		_m_stats.add_theme_stylebox_override(st, UITheme.empty_box())
	_m_stats.pressed.connect(func() -> void: stats_tapped.emit())
	_m_stats.button_down.connect(func() -> void: _m_stats.modulate.a = 0.7)
	_m_stats.button_up.connect(func() -> void: _m_stats.modulate.a = 1.0)
	_m_stats_box = UITheme.hbox(10)
	_m_stats_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_m_stats_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_m_stats_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mt := UITheme.vbox(1)
	mt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var mth := UITheme.hbox(5)
	var ti := UITheme.icon_rect("troops", 14.0, UITheme.TEXT_2)
	ti.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mth.add_child(ti)
	_m_troops = CountLabel.new(15, 700, UITheme.TEXT, UITheme.fmt_troops)
	mth.add_child(_m_troops)
	# the troop rate, coloured like the desktop label (green while it isn't falling, orange once it
	# is): players time their attacks by it
	_m_growth = UITheme.label("+0/s", 12, 700, UITheme.GREEN)
	_m_growth.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mth.add_child(_m_growth)
	mt.add_child(mth)
	_m_troops_bar = FillBar.new(3.0, UITheme.CYAN)
	_m_troops_bar.glow = false
	_m_troops_bar.custom_minimum_size = Vector2(40, 3)
	mt.add_child(_m_troops_bar)
	_m_stats_box.add_child(mt)
	var mgh := UITheme.hbox(5)
	mgh.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var gi := UITheme.icon_rect("gold", 14.0, UITheme.GOLD)
	gi.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mgh.add_child(gi)
	_m_gold = CountLabel.new(15, 700, UITheme.GOLD, UITheme.fmt_num)
	mgh.add_child(_m_gold)
	_m_stats_box.add_child(mgh)
	_m_stats.add_child(_m_stats_box)
	_m_ratio = UITheme.hbox(6)
	_m_ratio.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	# Build slots
	_builds = UITheme.hbox(4)
	_builds2 = UITheme.hbox(8)
	_builds2.alignment = BoxContainer.ALIGNMENT_CENTER
	_tray_v = UITheme.vbox(8)
	for i in UIRules.ACTIONS.size():
		var k: String = UIRules.ACTIONS[i]
		if k == "atom":
			_nuke_div = UITheme.vdivider(40.0)
			var wrap := MarginContainer.new()
			wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			wrap.add_theme_constant_override("margin_left", 6)
			wrap.add_theme_constant_override("margin_right", 6)
			wrap.add_child(_nuke_div)
			_nuke_wrap = wrap
			_builds.add_child(wrap)
		var b := BuildButton.new(ctx, k, UIRules.HOTKEYS[i])
		b.chosen.connect(func(kind: String) -> void: build_chosen.emit(kind))
		buttons[k] = b
		_builds.add_child(b)
	# The Arsenal: a slot for each of its kinds (in the row only once unlocked, see _arrange_slots)
	# and the gold SHOP slot that closes the row
	for k in UIRules.ARSENAL:
		var b := BuildButton.new(ctx, k, "")
		b.chosen.connect(func(kind: String) -> void: build_chosen.emit(kind))
		buttons[k] = b
	_shop = ShopSlot.new(ctx)
	_shop.wanted.connect(func(key, from) -> void: arsenal_wanted.emit(key, from))
	_arsenal_wrap = MarginContainer.new()
	_arsenal_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_arsenal_wrap.add_theme_constant_override("margin_left", 6)
	_arsenal_wrap.add_child(_shop)
	_builds.add_child(_arsenal_wrap)

	# Phone tray + toggle, and the touch placement chip.
	tray = GlassPanel.new(10.0, 8.0, UITheme.R_LG, true, 18)
	tray.visible = false
	add_child(tray)
	var tb := Button.new()
	tb.text = "BUILD"
	tb.theme_type_variation = "GlassButton"
	tb.toggle_mode = true
	tb.focus_mode = Control.FOCUS_NONE
	tb.icon = UITheme.icon_texture("city")
	tb.add_theme_constant_override("icon_max_width", 18)
	tb.add_theme_font_size_override("font_size", 13)
	tb.custom_minimum_size = Vector2(88, 44)
	tb.add_theme_stylebox_override("pressed", UITheme.flat(UITheme.c(UITheme.AMBER, 0.22), UITheme.R_MD, UITheme.AMBER, 1, 12.0, 8.0))
	tb.add_theme_stylebox_override("hover_pressed", UITheme.flat(UITheme.c(UITheme.AMBER, 0.28), UITheme.R_MD, UITheme.AMBER, 1, 12.0, 8.0))
	tb.add_theme_color_override("font_pressed_color", UITheme.AMBER_HI)
	tb.add_theme_color_override("icon_pressed_color", UITheme.AMBER_HI)
	tb.toggled.connect(func(on: bool) -> void: set_tray(on))
	_tray_btn = tb
	_place_chip = GlassPanel.new(14.0, 6.0, 999, true, 16)
	_place_chip.visible = false
	var pc := UITheme.hbox(10)
	var pic := UITheme.icon_rect("target", 16.0, UITheme.AMBER)
	pic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pc.add_child(pic)
	_place_text = UITheme.label("", 13, 600)
	_place_text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pc.add_child(_place_text)
	var cancel := UITheme.button("Cancel", "GlassButton", "close", 44.0)
	cancel.add_theme_font_size_override("font_size", 13)
	cancel.add_theme_constant_override("icon_max_width", 12)
	cancel.pressed.connect(func() -> void: cancel_placement.emit())
	pc.add_child(cancel)
	_place_chip.add_child(pc)
	add_child(_place_chip)


# ---------------------------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------------------------
func apply_layout() -> void:
	var flow := WIDE
	if ctx.compact:
		flow = COMPACT
	elif not ctx.wide:
		flow = STACKED
	if flow != _flow:
		_flow = flow
		_reflow()
	var bottom := 12.0 + ctx.insets.w if not ctx.compact else maxf(6.0, ctx.insets.w)
	_anchor_bottom_center(panel, bottom)
	# Tray and placement chip sit just above the bar.
	var above := bottom + panel.get_combined_minimum_size().y + 8.0
	_anchor_bottom_center(tray, above)
	var chip := _place_chip
	if ctx.compact:
		# Phones: the placement hint sits top-left under the top bar, clear of the globe's centre.
		chip.anchor_left = 0
		chip.anchor_right = 0
		chip.anchor_top = 0
		chip.anchor_bottom = 0
		chip.grow_horizontal = Control.GROW_DIRECTION_END
		chip.grow_vertical = Control.GROW_DIRECTION_END
		chip.offset_left = ctx.insets.x + 12.0
		chip.offset_right = chip.offset_left
		chip.offset_top = ctx.reserved_top_left.end.y + 6.0
		chip.offset_bottom = chip.offset_top
		chip.set_padding(12.0, 0.0, 0.0, 0.0)
		chip.reset_size()
	else:
		chip.set_padding(14.0, 6.0, 14.0, 6.0)
		_anchor_bottom_center(chip, above)


func _anchor_bottom_center(c: Control, bottom: float) -> void:
	c.anchor_left = 0.5
	c.anchor_right = 0.5
	c.anchor_top = 1.0
	c.anchor_bottom = 1.0
	c.grow_horizontal = Control.GROW_DIRECTION_BOTH
	c.grow_vertical = Control.GROW_DIRECTION_BEGIN
	c.offset_left = 0.0
	c.offset_right = 0.0
	c.offset_top = -bottom
	c.offset_bottom = -bottom
	c.reset_size()


## Every value in the bar sits in a box sized for its widest possible text (tabular digits), and
## labels clip rather than grow, so the bar never changes size or shifts as numbers change.
func _apply_fixed_widths(compact: bool) -> void:
	var T := UITheme
	var small := 11
	var vf := 17 if compact else 20
	var cf := 12 if compact else 13
	for l in [_growth, _income, _committed, _ratio_sub]:
		l.add_theme_font_size_override("font_size", small)
	_troops_cap.add_theme_font_size_override("font_size", cf)
	var w_val := T.text_width("888.8M", vf, 700) + 2.0
	var w_gold := T.text_width("8888.8M", vf, 700) + 2.0
	var w_cap := T.text_width("/ 888.8M", cf, 500) + 2.0
	var w_rate := T.text_width("+888.8K/s", small, 700) + 2.0
	var w_war := T.text_width("888.8M at war", small, 700) + 2.0
	T.fix_width(_troops, w_val, HORIZONTAL_ALIGNMENT_RIGHT)
	T.fix_width(_troops_cap, w_cap)
	T.fix_width(_growth, w_rate, HORIZONTAL_ALIGNMENT_RIGHT)
	T.fix_width(_committed, w_war, HORIZONTAL_ALIGNMENT_RIGHT)
	T.fix_width(_gold, w_gold)
	T.fix_width(_income, w_rate, HORIZONTAL_ALIGNMENT_RIGHT)
	var cap_troops := T.text_width("TROOPS", small, 700) + 6.0
	var cap_gold := T.text_width("GOLD", small, 700) + 4.0
	var troops_w := maxf(w_val + 5.0 + w_cap, 12.0 + 6.0 + cap_troops + 8.0 + w_rate)
	troops_w = maxf(troops_w, 40.0 + 6.0 + w_war)
	_troops_box.custom_minimum_size = Vector2(troops_w, 0)
	_gold_box.custom_minimum_size = Vector2(maxf(w_gold, 12.0 + 6.0 + cap_gold + 8.0 + w_rate), 0)
	var pct_w := T.text_width("100%", 13, 800) + 2.0
	T.fix_width(_ratio_pct, pct_w, HORIZONTAL_ALIGNMENT_RIGHT)
	var inline_w := maxf(T.text_width("Sends", 12, 600), T.text_width("888.8K", 13, 700)) + 2.0
	T.fix_width(_ratio_inline, inline_w, HORIZONTAL_ALIGNMENT_RIGHT)
	T.fix_width(_ratio_sends, inline_w, HORIZONTAL_ALIGNMENT_RIGHT)
	var ratio_w := 188.0 if compact else 180.0
	_ratio_box.custom_minimum_size = Vector2(ratio_w, 0)
	T.fix_width(_ratio_sub, ratio_w, HORIZONTAL_ALIGNMENT_LEFT, false)
	# Phone strip numbers: fixed boxes too.
	T.fix_width(_m_troops, T.text_width("888.8M", 15, 700) + 2.0, HORIZONTAL_ALIGNMENT_LEFT)
	T.fix_width(_m_growth, T.text_width("+888.8K/s", 12, 700) + 2.0, HORIZONTAL_ALIGNMENT_LEFT)
	T.fix_width(_m_gold, T.text_width("888.8M", 15, 700) + 2.0, HORIZONTAL_ALIGNMENT_LEFT)
	var name_w := 84.0 if compact else 118.0
	T.fix_width(_name, name_w, HORIZONTAL_ALIGNMENT_LEFT, false)
	T.fix_width(_land, name_w + 20.0, HORIZONTAL_ALIGNMENT_LEFT, false)
	_nation.custom_minimum_size = Vector2(name_w + 20.0 + 24.0, 0)


## Screen y of the bar's top edge (for stacking the event feed above it).
func top_edge() -> float:
	if not (panel.visible and visible):
		return ctx.vp.y - ctx.insets.w
	var y := panel.position.y
	if tray.visible:
		y = minf(y, tray.position.y)
	if _place_chip.visible and not ctx.compact:
		y = minf(y, _place_chip.position.y)
	return y


## The bar's own top edge, without the build tray or the placement chip.
func base_edge() -> float:
	if not (panel.visible and visible):
		return ctx.vp.y - ctx.insets.w
	return panel.position.y


## Phone: show / hide the build tray.
func set_tray(on: bool) -> void:
	if _flow != COMPACT:
		on = false
	_tray_open = on
	_tray_btn.set_pressed_no_signal(on)
	if _tray_caption != null:
		UITheme.set_font_color(_tray_caption, UITheme.AMBER_HI if on else UITheme.TEXT)
	if on == tray.visible:
		return
	if on:
		tray.visible = true
		refresh_buttons()
		UIFx.pop_in(tray, 0.0, 0.94, 0.25)
		ctx.sfx("open", -8.0)
		if ctx.coach != null and ctx.touch:
			ctx.coach.offer("tray", func() -> Vector2:
				var b: BuildButton = buttons["city"]
				if b.is_visible_in_tree():
					return b.get_global_rect().get_center()
				return Vector2(-1, -1))
	else:
		tray.visible = false
	footprint_changed.emit()


## The Arsenal kinds the player has unlocked, in slot order.
func _unlocked_arsenal() -> Array[String]:
	var out: Array[String] = []
	var rules: UIRules = ctx.rules
	for k in UIRules.ARSENAL:
		if rules != null and not rules.arsenal_locked(k):
			out.append(k)
	return out


## What the single-row bar holds beyond its ten slots, in px: SHOP (wider while there is anything
## to get) and a slot per unlocked Arsenal kind. UIRoot: how wide the screen must be for the wide
## flow.
func extra_width() -> float:
	var shop := maxf(SHOP_W, TrayFit.shop_width(_shop.locked().size()))
	return 62.0 * _unlocked_arsenal().size() + shop + 4.0


## Placement feedback: highlights the slot and, on touch, shows "Tap your land… · Cancel".
func set_placing(kind: String) -> void:
	_placing = kind
	set_active(kind)
	if kind != "":
		set_tray(false)
	var show := kind != "" and ctx.touch
	if show:
		var t: String = UIRules.SHORT.get(kind, kind)
		var txt := "Tap a target, then confirm to launch" if UIRules.is_nuke(kind) else "Tap your land, then confirm to build the %s" % t
		if kind == "warship":
			txt = "Tap water near your port, then confirm"
		_place_text.text = txt
	var was := _place_chip.visible
	_place_chip.visible = show
	if show and not was:
		_place_chip.reset_size()
		UIFx.pop_in(_place_chip, 0.0, 0.94, 0.25)


## Nuke slots live either at the end of the build row or on their own second row. The unlocked
## Arsenal kinds follow them, and the SHOP slot closes whichever row they are in.
func _arrange_slots(two_rows: bool) -> void:
	var nukes := [buttons["atom"], buttons["hydrogen"], buttons["mirv"]]
	for n in nukes:
		_detach(n)
	_detach(_nuke_wrap)
	_detach(_arsenal_wrap)
	for k in UIRules.ARSENAL:
		_detach(buttons[k])
	var unlocked := _unlocked_arsenal()
	_arsenal_sig = ",".join(unlocked)
	var row := _builds
	if two_rows:
		row = _builds2
	else:
		_builds.add_child(_nuke_wrap)
	for n in nukes:
		row.add_child(n)
	for ps in port_slots:
		_detach(ps)
		row.add_child(ps)
	for k in unlocked:
		row.add_child(buttons[k])
	row.add_child(_arsenal_wrap)


func _detach(c: Node) -> void:
	if c != null and c.get_parent() != null:
		c.get_parent().remove_child(c)


func _reflow() -> void:
	var T := UITheme
	for c in [_nation, _troops_box, _gold_box, _ratio_box, _builds, _builds2, _tray_btn, _tray_v, _m_stats, _m_ratio]:
		_detach(c)
	# The slider and its % / sends readout live in the ratio box, or in the phone strip.
	_detach(_slider)
	_detach(_ratio_inline_box)
	var strip_host: HBoxContainer = _m_ratio if _flow == COMPACT else _ratio_line
	strip_host.add_child(_slider)
	strip_host.add_child(_ratio_inline_box)
	_arrange_slots(false)
	_shop.refresh()
	var shop_want := TrayFit.shop_width(_shop.locked().size())
	if _root_box != null:
		panel.remove_child(_root_box)
		_root_box.queue_free()
		_root_box = null
	var compact := _flow == COMPACT
	for b in buttons.values():
		b.set_compact(compact, ctx.touch)
	_builds.add_theme_constant_override("separation", 8 if ctx.touch else 4)
	_troops.add_theme_font_size_override("font_size", 17 if compact else 20)
	_gold.add_theme_font_size_override("font_size", 17 if compact else 20)
	_name.add_theme_font_size_override("font_size", 13 if compact else 15)
	_apply_fixed_widths(compact)
	var ratio_w := _ratio_box.custom_minimum_size.x
	# The Attack bar: five stops. Under a finger each is a target STOP_TOUCH_W wide and the strip's
	# height tall.
	var stop_fs := 12
	var stop_w := maxf(STOP_TOUCH_W, T.text_width("75%", stop_fs, 800) + 10.0)
	_slider.custom_minimum_size = Vector2(stop_w * UICtx.RATIO_STOPS.size() if compact else ratio_w, 44 if ctx.touch else 26)
	_slider.track_height = 36.0 if ctx.touch else 26.0
	_slider.font_size = stop_fs
	_slider.queue_redraw()
	_ratio_sub.visible = not compact
	_ratio_head.visible = not compact
	_ratio_inline.visible = compact
	_ratio_inline_box.visible = compact
	_ratio_sends.visible = compact
	_nation.visible = not compact
	_nuke_div.custom_minimum_size = Vector2(1, 32 if compact else 40)
	# Phones: a slim strip exactly one touch target tall.
	panel.set_padding(8.0 if compact else 18.0, 0.0 if compact else 12.0, 4.0 if compact else 18.0, 0.0 if compact else 12.0)
	# Icon on top, "Build" underneath, exactly one touch target tall (the caption is a child label
	# so it does not add to the button's minimum height).
	var tb := _tray_btn
	tb.text = ""
	tb.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tb.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	tb.expand_icon = false
	tb.add_theme_constant_override("icon_max_width", 16)
	tb.custom_minimum_size = Vector2(52, 44)
	for st in ["normal", "hover", "disabled"]:
		tb.add_theme_stylebox_override(st, T.flat(Color(1, 1, 1, 0.05), T.R_MD, Color(1, 1, 1, 0.08), 1, 0.0, 5.0))
	tb.add_theme_stylebox_override("pressed", T.flat(T.c(T.AMBER, 0.22), T.R_MD, T.AMBER, 1, 0.0, 5.0))
	tb.add_theme_stylebox_override("hover_pressed", T.flat(T.c(T.AMBER, 0.28), T.R_MD, T.AMBER, 1, 0.0, 5.0))
	if _tray_caption == null:
		var cap := T.label("Build", 12, 700, T.TEXT)
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cap.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		cap.offset_top = -19.0
		cap.offset_bottom = -3.0
		cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tb.add_child(cap)
		_tray_caption = cap
	# (gold last, next to the slots it buys)
	var stats_order: Array[Control] = [_nation, _troops_box, _ratio_box, _gold_box]
	if _flow == WIDE:
		var row := T.hbox(16)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		_root_box = row
		for c in stats_order:
			row.add_child(c)
			c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(T.vdivider(44.0))
		row.add_child(_builds)
		_builds.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	elif compact:
		# Phone: one slim strip (numbers, short slider, Build); the slots live in a tray.
		var one := T.hbox(8)
		one.alignment = BoxContainer.ALIGNMENT_CENTER
		_root_box = one
		# Width from the fixed number boxes (icon + gap + number + gap + rate, then gold, plus the gap
		# between).
		var w_stats := 14.0 + 5.0 + _m_troops.custom_minimum_size.x + 5.0 + _m_growth.custom_minimum_size.x + 10.0 + 14.0 + 5.0 + _m_gold.custom_minimum_size.x
		_m_stats.custom_minimum_size = Vector2(w_stats + 4.0, 44.0)
		one.add_child(_m_stats)
		one.add_child(_m_ratio)
		one.add_child(tb)
		tb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_builds.alignment = BoxContainer.ALIGNMENT_CENTER
		# One row when it fits between the safe edges (the ten slots, the unlocked Arsenal kinds and
		# the SHOP button: the slots narrow a little first, then SHOP), else builds over nukes.
		var avail := ctx.vp.x - ctx.insets.x - ctx.insets.z - 16.0
		var fit := TrayFit.fit(avail, 10 + _unlocked_arsenal().size(), _shop.locked().size())
		for b in buttons.values():
			b.set_slot_width(fit.slot_w)
		_shop.set_block(fit.shop_w, 64.0)
		_builds.add_theme_constant_override("separation", int(fit.sep))
		_builds2.add_theme_constant_override("separation", int(fit.sep))
		_arrange_slots(fit.two_rows)
		_tray_v.add_child(_builds)
		if fit.two_rows:
			_tray_v.add_child(_builds2)
		if _tray_v.get_parent() == null:
			tray.add_child(_tray_v)
	else:
		var col := T.vbox(10)
		_root_box = col
		var stats := T.hbox(16)
		stats.alignment = BoxContainer.ALIGNMENT_CENTER
		for c in stats_order:
			stats.add_child(c)
			c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			if c != _gold_box:
				stats.add_child(T.vdivider(40.0))
		col.add_child(stats)
		_builds.alignment = BoxContainer.ALIGNMENT_CENTER
		_builds.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		col.add_child(_builds)
	if not compact:
		set_tray(false)
		for b in buttons.values():
			b.set_slot_width(0.0)
		_shop.set_block(maxf(SHOP_W, shop_want), 62.0 if ctx.touch else 60.0)
	_root_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(_root_box)


# ---------------------------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------------------------
func refresh(animate: bool = true) -> void:
	var T := UITheme
	var s = ctx.state
	var o = ctx.my()
	if s == null or o == null:
		return
	var col := T.owner_ui_color(o.color)
	T.set_swatch_color(_swatch, o.color)
	_name.text = o.name
	var share: float = s.land_share(o.id)
	_land.text = "%s of the world" % T.fmt_pct(share)
	# (the leader from one pass, not the whole ranking sorted)
	var leader = ctx.leader()
	_crown.modulate.a = 1.0 if (leader != null and leader.id == o.id) else 0.0
	_troops.set_value(o.troops, animate)
	_troops_cap.text = "/ " + T.fmt_troops(o.max_troops)
	var bar_col := col.lerp(T.CYAN, 0.35)
	_troops_bar.fill_color = bar_col
	_troops_bar.set_target(o.troops / maxf(o.max_troops, 1.0), not animate)
	_gold.set_value(o.gold, animate)
	_m_troops.set_value(o.troops, animate)
	_m_gold.set_value(o.gold, animate)
	_m_troops_bar.fill_color = bar_col
	_m_troops_bar.set_target(o.troops / maxf(o.max_troops, 1.0), not animate)
	var income: float = s.income(o.id)
	_income.text = T.fmt_rate(income)
	T.set_font_color(_income, T.GREEN if income > 0 else T.TEXT_3)
	# Growth: the troop-rate label, "+{troops gained per second}/s", green while the rate is not
	# falling and orange once it is (sample_growth). Attacks spend troops but do not slow it.
	var per_tick: float = s.troop_growth(o.id)
	_rate = per_tick * Defs.TICK_RATE
	_growth.text = UIRules.troop_rate_text(_rate)
	T.set_font_color(_growth, T.GREEN if _rate_up else T.ORANGE)
	_m_growth.text = _growth.text
	T.set_font_color(_m_growth, T.GREEN if _rate_up else T.ORANGE)
	var at_war := _committed_troops()
	_committed.modulate.a = 1.0 if at_war > 0 else 0.0
	_committed.text = "%s at war" % T.fmt_troops(at_war) if at_war > 0 else ""
	_refresh_ratio()
	refresh_buttons()


## Coalesced: the slots refresh at most once per frame, however many events ask for it.
func refresh_buttons() -> void:
	_buttons_dirty = true


func _refresh_buttons_now() -> void:
	_buttons_dirty = false
	# an Arsenal kind was unlocked (or the inventory arrived): its slot joins the row, SHOP stops
	# showing it
	var cards_changed := _shop.refresh()
	var sig := ",".join(_unlocked_arsenal())
	if sig != _arsenal_sig or cards_changed:
		_arsenal_sig = sig
		slots_changed.emit()  # (UIRoot lays the HUD out again: the row may need another flow)
		_reflow()
		footprint_changed.emit()
	for b in buttons.values():
		b.refresh()


## Phone details card (the strip shows only numbers): troops, cap, growth, at war, gold, income.
func stats_spec() -> Dictionary:
	var T := UITheme
	var s = ctx.state
	var o = ctx.my()
	if s == null or o == null:
		return {}
	var rows: Array = [
		["Troops", "%s / %s" % [T.fmt_troops(o.troops), T.fmt_troops(o.max_troops)]],
		["Growth", _growth.text, T.GREEN if _rate_up else T.ORANGE],
	]
	var at_war := _committed_troops()
	if at_war > 0:
		rows.append(["At war", T.fmt_troops(at_war), T.ORANGE])
	rows.append(["Gold", T.fmt_num(o.gold), T.GOLD])
	var income: float = s.income(o.id)
	rows.append(["Income", T.fmt_rate(income), T.GREEN if income > 0 else T.TEXT_3])
	rows.append(["Land", T.fmt_pct(s.land_share(o.id))])
	var pct := ctx.ratio * 100
	rows.append(["Each order sends", "%d%% · %s" % [int(floor(pct + 0.5)) if pct >= 0 else 0, T.fmt_troops(ctx.troops_for_ratio())], T.AMBER])
	return {"title": o.name, "swatch": o.color, "rows": rows, "footer": "Cities raise your troop cap. More land, more gold."}


## Rect of the phone strip's numbers (anchor for the details card).
func stats_rect() -> Rect2:
	if _m_stats.is_visible_in_tree():
		return _m_stats.get_global_rect()
	return panel.get_global_rect()


func reset_rate() -> void:
	_rate = 0.0
	_rate_up = true
	_last_growth = NAN


## Whether the troops/s label shows a rising rate (UIRules.troop_rate_rising), run once per stats
## update. Only new stats count: re-rendering the same numbers must not turn an orange label green.
func sample_growth() -> void:
	var o = ctx.my()
	if ctx.state == null or o == null:
		return
	var rate: float = ctx.state.troop_growth(o.id)
	_rate_up = UIRules.troop_rate_rising(rate, _last_growth)
	_last_growth = rate


func _committed_troops() -> float:
	var s = ctx.state
	var n := 0.0
	if s == null:
		return 0.0
	var mine := ctx.me()
	if mine == 0:
		return 0.0
	for a in s.attacks():
		if a.attacker == mine:
			n += a.troops
	return n


func set_active(kind: String) -> void:
	for k in buttons:
		buttons[k].set_active(k == kind)


func button(kind: String) -> BuildButton:
	return buttons.get(kind)


func _refresh_ratio() -> void:
	var pct := int(floor(ctx.ratio * 100 + 0.5))
	_ratio_pct.text = "%d%%" % pct
	_ratio_sends.text = UITheme.fmt_troops(ctx.troops_for_ratio())
	_ratio_sub.text = "Sends %s troops" % UITheme.fmt_troops(ctx.troops_for_ratio())


## Per frame.
func update(delta: float) -> void:
	_poll += delta
	if _poll >= 0.5:
		_poll = 0.0
		_buttons_dirty = true
	if _buttons_dirty and is_visible_in_tree():
		_refresh_buttons_now()


## Sections the current flow does not use are detached (not in the tree): free them with the bar.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for c in [_nation, _troops_box, _gold_box, _ratio_box, _builds, _builds2, _tray_btn, _tray_v, _m_stats, _m_ratio, _nuke_wrap, _arsenal_wrap, _slider, _ratio_inline_box]:
			if is_instance_valid(c) and c.get_parent() == null:
				c.free()
		for b in buttons.values():
			if is_instance_valid(b) and b.get_parent() == null:
				b.free()
