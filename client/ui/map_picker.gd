# Port of src/client/UI/MapPicker.luau (scripts/ui/map_picker.gd, UIMapPicker).
# "CHOOSE A MAP": tabs, a scrolling grid of map cards (thumbnail, name, second line), a foot line.
#
# Upstream's tabs are regions of one map list. This port keeps its three map tables as the tabs
# (real-world, random, RoWorld maps); turning a tab is the game's _set_map_tab, and the Random tab
# has the port's REROLL chip. A card's second line says who is on the map (upstream: its size).
class_name MapPicker
extends Control

signal picked(id: String)
signal closed

const CARD := Vector2(168, 132)
const GRID_SIZE := Vector2(740, 420)
const ATTRIBUTION := "Made with Natural Earth and NOAA ETOPO1 data (public domain)"
const RANDOM_FOOT := "Random maps are drawn from a seed: REROLL makes twelve new ones"

var ctx: UICtx
var g
var is_open := false
var selected := ""
var _tab := 0
var _dim: ColorRect
var _panel: GlassPanel
var _tabs: Array[Button] = []
var _reroll: Button
var _host: Control
var _scroll: ScrollContainer
var _grid: GridContainer
var _foot: Label
var _cards := {}  # id -> Button
var _pending := {}  # id -> TextureRect still waiting for its preview
var _quiet := false


func _init(c: UICtx, main) -> void:
	ctx = c
	g = main
	name = "MapPicker"
	theme = UITheme.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

	_dim = ColorRect.new()
	_dim.color = UITheme.rgba(0.01, 0.015, 0.05, 0.6)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and not _panel.get_global_rect().has_point(e.global_position):
			close())
	add_child(_dim)

	_panel = GlassPanel.new(22.0, 20.0, 18, true, 34)
	_panel.set_tint(UITheme.rgba(0.045, 0.065, 0.13, 0.95))
	add_child(_panel)
	var v := UITheme.vbox(12)
	_panel.add_child(v)

	var head := UITheme.hbox(10)
	var title := UITheme.label("CHOOSE A MAP", 20, 800, UITheme.TEXT, 3)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(title)
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
	v.add_child(head)

	var tabs := UITheme.hbox(6)
	for i in UIMaps.TAB_NAMES.size():
		var chip := UITheme.button("", "ChipButton", "", 32.0)
		chip.toggle_mode = true
		chip.add_theme_font_size_override("font_size", 12)
		chip.pressed.connect(func() -> void: g._set_map_tab(i))
		_tabs.append(chip)
		tabs.add_child(chip)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.add_child(gap)
	# (port) new seeds for the twelve random maps
	_reroll = UITheme.button("REROLL", "GlassButton", "", 32.0)
	_reroll.add_theme_font_size_override("font_size", 12)
	_reroll.add_theme_color_override("font_color", UITheme.GOLD)
	_reroll.pressed.connect(func() -> void:
		g.rand_seed_off = g.rng.randi_range(100, 999999)
		g._refresh_map_tab_cards())
	tabs.add_child(_reroll)
	v.add_child(tabs)

	_host = Control.new()
	_host.custom_minimum_size = GRID_SIZE
	_host.mouse_filter = Control.MOUSE_FILTER_PASS
	v.add_child(_host)
	_scroll = ScrollContainer.new()
	_scroll.name = "MapGrid"
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_host.add_child(_scroll)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_top", 2)
	pad.add_theme_constant_override("margin_left", 2)
	_scroll.add_child(pad)
	_grid = GridContainer.new()
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	pad.add_child(_grid)

	_foot = UITheme.label(ATTRIBUTION, 11, 500, UITheme.TEXT_3)
	v.add_child(_foot)
	visibility_changed.connect(_on_visibility)
	set_process(false)


## The game (and its screenshot runs) also shows and hides this window by `visible` alone.
func _on_visibility() -> void:
	if _quiet:
		return
	if visible and not is_open:
		_quiet = true
		open("", true)
		_quiet = false
	elif not visible and is_open:
		is_open = false
		set_process(false)


func _tab_label(i: int) -> String:
	return "%s (%d)" % [UIMaps.TAB_NAMES[i], UIMaps.count(g, i)]


func _card(e: Dictionary) -> Button:
	var b := Button.new()
	b.name = str(e.id).replace(":", "_")
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = CARD
	var on: bool = e.id == selected
	var border := UITheme.AMBER if on else Color(1, 1, 1, 0.12)
	var bw := 2 if on else 1
	b.add_theme_stylebox_override("normal", UITheme.flat(Color(1, 1, 1, 0.06), 10, border, bw))
	b.add_theme_stylebox_override("hover", UITheme.flat(Color(1, 1, 1, 0.12), 10, border, bw))
	b.add_theme_stylebox_override("pressed", UITheme.flat(Color(1, 1, 1, 0.12), 10, border, bw))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var img := TextureRect.new()
	img.name = "Thumb"
	img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	img.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	img.position = Vector2(8, 8)
	img.size = Vector2(CARD.x - 16, CARD.y - 46)
	var tex := UIMaps.thumb(g, e.tab, e.index)
	if tex != null:
		img.texture = tex
	else:
		img.texture = g._blank_preview()
		_pending[e.id] = img
	b.add_child(img)
	var nm := UITheme.label(e.name, 14, 700, Color.WHITE)
	nm.name = "MapName"
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nm.clip_text = true
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.position = Vector2(8, CARD.y - 36)
	nm.size = Vector2(CARD.x - 16, 18)
	b.add_child(nm)
	var sub := UITheme.label(e.sub, 11, 500, Color8(170, 180, 205))
	sub.name = "Size"
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sub.clip_text = true
	sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sub.position = Vector2(8, CARD.y - 18)
	sub.size = Vector2(CARD.x - 16, 14)
	b.add_child(sub)
	b.pressed.connect(func() -> void:
		selected = e.id
		g.map_i = int(e.index)
		ctx.sfx("click")
		picked.emit(e.id)
		close())
	_grid.add_child(b)
	return b


## Rebuilds the grid for the game's current tab (the game calls this when the tab or the seeds change).
func rebuild() -> void:
	_tab = clampi(int(g.map_tab), 0, 1)
	selected = UIMaps.selected(g)
	for j in _tabs.size():
		_tabs[j].text = _tab_label(j)
		_tabs[j].set_pressed_no_signal(j == _tab)
	_reroll.visible = _tab == 1
	_foot.text = RANDOM_FOOT if _tab == 1 else ATTRIBUTION
	for b in _cards.values():
		b.queue_free()
	_cards.clear()
	_pending.clear()
	_grid.columns = maxi(1, int((_host.custom_minimum_size.x + 10.0) / (CARD.x + 10.0)))
	for e in UIMaps.entries(g, _tab):
		_cards[e.id] = _card(e)
	_scroll.scroll_vertical = 0
	set_process(is_open and not _pending.is_empty())


func _process(_dt: float) -> void:
	for id in _pending.keys():
		var tex := UIMaps.thumb(g, _tab, UIMaps.index_of(id))
		if tex != null:
			_pending[id].texture = tex
			_pending.erase(id)
	if _pending.is_empty():
		set_process(false)


func open(sel: String = "", instant: bool = false) -> void:
	if is_open:
		return
	is_open = true
	if sel != "":
		selected = UIMaps.valid(g, sel)
	g._set_map_tab(int(g.map_tab))  # (queues the random previews and calls rebuild)
	_quiet = true
	visible = true
	_quiet = false
	_panel.modulate.a = 1.0
	_center()
	if instant:
		_dim.modulate.a = 1.0
		_panel.scale = Vector2.ONE
		return
	_dim.modulate.a = 0.0
	UIFx.fade(_dim, 1.0, 0.2)
	UIFx.pop_in(_panel, 0.0, 0.94, 0.3)
	ctx.sfx("open")


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
	var area := ctx.clear_rect()
	var gw := clampf(area.size.x - 80.0, 360.0, GRID_SIZE.x)
	var gh := clampf(area.size.y - 190.0, 200.0, GRID_SIZE.y)
	_host.custom_minimum_size = Vector2(gw, gh)
	if is_open:
		rebuild()
	_center()


func _center() -> void:
	var sz := _panel.get_combined_minimum_size()
	var area := ctx.clear_rect()
	var p := area.position + (area.size - sz) * 0.5
	var y := maxf(p.y, area.position.y + 4.0)
	_panel.position = Vector2(floorf(p.x + 0.5), floorf(y + 0.5))
	_panel.reset_size()
