# Port of the top bar in src/client/Main.luau (make_button, show_tip, layout_hud, topbar_rect,
# refresh_hud, build_hud): the row of round buttons at the top-left: music, help, leaderboard,
# centre on your nation, settings, game menu.
#
# Geometry and look as upstream measured them from Roblox's own top bar: 44 px circles filled
# RGB(18,18,21) at 0.08 transparency, 36 px icon frames, 8 px apart, top edge 12 px below the screen
# top, a white state overlay on hover / press. (On Roblox the row continues after Roblox's own
# buttons; here it starts at the left edge.)
class_name ClientTopbar
extends Control

const BUTTON := 44.0
const GAP := 8.0
const ICON := 36.0  # the hud_* masks keep a 0.7 inset framing (glyph ≈ 25 px)
const FILL := Color8(18, 18, 21)
const FILL_T := 0.08
const OVERLAY_T := 1.0
const OVERLAY_HOVER_T := 0.92
const OVERLAY_PRESS_T := 0.84


class TopButton:
	extends Button
	var icon_name := ""
	var tooltip := ""
	var overlay_t := 1.0  # the white state overlay's transparency
	var _tw: Tween = null

	func _init(key: String, icon: String, tip: String) -> void:
		name = key
		icon_name = icon
		tooltip = tip
		focus_mode = Control.FOCUS_NONE
		custom_minimum_size = Vector2(BUTTON, BUTTON)
		for st in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
			add_theme_stylebox_override(st, StyleBoxEmpty.new())

	func set_icon(n: String) -> void:
		icon_name = n
		queue_redraw()

	func tween_overlay(t: float) -> void:
		if _tw:
			_tw.kill()
		_tw = create_tween()
		_tw.tween_method(func(v: float) -> void:
			overlay_t = v
			queue_redraw(), overlay_t, t, 0.1).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5
		draw_circle(c, r, Color(FILL.r, FILL.g, FILL.b, 1.0 - FILL_T))
		if overlay_t < 1.0:
			draw_circle(c, r, Color(1, 1, 1, 1.0 - overlay_t))
		var t := UITheme.icon_texture("hud_" + icon_name)
		if t != null:
			draw_texture_rect(t, Rect2(c - Vector2(ICON, ICON) * 0.5, Vector2(ICON, ICON)), false, Color.WHITE)


var hud  # ClientHud
var bar: HBoxContainer
var buttons := {}
var tip: PanelContainer
var _tip_l: Label


func _init(h) -> void:
	hud = h
	name = "Topbar"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bar = HBoxContainer.new()
	bar.name = "Bar"
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_theme_constant_override("separation", int(GAP))
	add_child(bar)
	tip = PanelContainer.new()
	tip.name = "Tooltip"
	tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tip.add_theme_stylebox_override("panel", UITheme.flat(Color(FILL.r, FILL.g, FILL.b, 0.9), 8, null, 0, 10, 6))
	_tip_l = UITheme.label("", 14, 500, Color.WHITE)
	tip.add_child(_tip_l)
	tip.visible = false
	add_child(tip)

	var g = hud.g
	_make("music", "music_on" if g.music_on_setting() else "music_off", "Music (M)", func() -> void:
		g.hud_toggle_music()
		refresh())
	_make("help", "help", "Help & Credits (H)", func() -> void: g.help_panel.visible = not g.help_panel.visible)
	_make("leaderboard", "leaderboard", "Leaderboard", func() -> void: hud.board.toggle())
	_make("home", "globe", "Center on your nation (Home)", func() -> void: hud.ctx.world_call("focus_owner", [hud.ctx.me()]))
	_make("settings", "settings", "Settings", func() -> void: g._open_settings())
	_make("menu", "exit", "Game menu", func() -> void: g.hud.open_menu())
	layout()
	refresh()


func _show_tip(b: Control, text: String) -> void:
	if b == null or text == "" or hud.ctx.touch:
		tip.visible = false
		return
	_tip_l.text = text
	tip.reset_size()
	var pos := b.global_position
	tip.position = Vector2(maxf(4.0, pos.x + b.size.x / 2 - tip.size.x / 2), pos.y + b.size.y + 8)
	tip.visible = true


func _make(key: String, icon: String, tooltip: String, on_press: Callable) -> TopButton:
	var b := TopButton.new(key, icon, tooltip)
	b.mouse_entered.connect(func() -> void:
		b.tween_overlay(OVERLAY_HOVER_T)
		_show_tip(b, b.tooltip))
	b.mouse_exited.connect(func() -> void:
		b.tween_overlay(OVERLAY_T)
		_show_tip(null, ""))
	b.button_down.connect(func() -> void: b.tween_overlay(OVERLAY_PRESS_T))
	b.button_up.connect(func() -> void: b.tween_overlay(OVERLAY_HOVER_T))
	b.pressed.connect(func() -> void:
		_show_tip(null, "")
		hud.ctx.sfx("click", -6.0)
		on_press.call())
	bar.add_child(b)
	buttons[key] = b
	return b


func layout() -> void:
	bar.position = Vector2(12, 12)
	bar.reset_size()


## Rect of the visible buttons (UIRoot keeps HUD panels clear of the row).
func topbar_rect() -> Rect2:
	var out := Rect2()
	var any := false
	for b in buttons.values():
		if b.visible:
			var r := Rect2(bar.position + b.position, b.size)
			out = r if not any else out.merge(r)
			any = true
	return out


func refresh() -> void:
	var g = hud.g
	# Match-only controls: the title screen has no leaderboard, nation or game menu yet.
	var in_match: bool = g.state == "play" or g.state == "pick"
	# Phones: no music button in the row (Settings has the switch).
	buttons["music"].visible = not hud.ctx.compact
	buttons["music"].set_icon("music_on" if g.music_on_setting() else "music_off")
	for key in ["leaderboard", "home", "menu"]:
		buttons[key].visible = in_match
	bar.reset_size()
