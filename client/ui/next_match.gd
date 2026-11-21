# Port of src/client/UI/NextMatch.luau (upstream c422466, 2026-11-13).
# NEXT MATCH: after a new player's first match, two big ways into the next one: another solo match
# against the computer, or a public match with real players. It opens over the results screen a
# moment after it (DELAY_S: the outcome and the Stars land first); "See results" closes it. The
# game menu's "Next-match screen" (staging / admins upstream) opens it from the title to try it.
#
# (port) Solo only: this port has no public matches, so the ONLINE card is built but stays hidden
# (public never fires).
#
# API: NextMatch.new(ctx); open(map_name, over_results); close(); apply_layout(); signals solo,
# public, closed.
class_name NextMatch
extends Control

signal solo
signal public
signal closed

## Seconds after the results screen opens.
const DELAY_S := 2.5
## (port) whether the ONLINE card is shown (no public matches here).
const ONLINE := false

var ctx: UICtx
var is_open := false
var _dim: ColorRect
var _panel: GlassPanel
var _title: Label
var _sub: Label
var _cards: Array = []
var _solo_text: Label
var _back: Button


func _init(c: UICtx) -> void:
	ctx = c
	name = "NextMatch"
	var T := UITheme
	theme = T.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_dim = ColorRect.new()
	_dim.color = T.rgba(0.01, 0.015, 0.05, 0.62)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)
	_panel = GlassPanel.new(24.0, 22.0, 18, true, 34)
	_panel.set_tint(T.rgba(0.045, 0.065, 0.13, 0.95))
	add_child(_panel)
	var v := T.vbox(16)
	_panel.add_child(v)
	var head := T.vbox(4)
	_title = T.label("NEXT MATCH", 26, 800, T.TEXT, 4)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_child(_title)
	_sub = T.label("Pick your next war", 14, 500, T.TEXT_2)
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_child(_sub)
	v.add_child(head)
	var row := T.hbox(14)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(row)
	_solo_text = _card(row, "troops", "SOLO", "", "PLAY SOLO", solo)
	_card(row, "users", "ONLINE", "Real players from around the world, up to 50 in a match.", "PLAY ONLINE", public)
	_cards[1].panel.visible = ONLINE
	_back = T.button("See results", "GhostButton", "", 40.0)
	_back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_back.add_theme_font_size_override("font_size", 13)
	_back.pressed.connect(close)
	v.add_child(_back)


func _card(row: HBoxContainer, icon: String, heading: String, text: String, button: String, fire: Signal) -> Label:
	var T := UITheme
	var p := GlassPanel.new(18.0, 16.0, T.R_MD, true, 20)
	p.set_border(T.c(T.CYAN, 0.35))
	var cv := T.vbox(10)
	p.add_child(cv)
	var top := T.hbox(10)
	var disc := Panel.new()
	disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	disc.custom_minimum_size = Vector2(38, 38)
	disc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	disc.add_theme_stylebox_override("panel", T.flat(T.c(T.CYAN, 0.16), 19, T.c(T.CYAN, 0.5), 1))
	var ic := T.icon_rect(icon, 20.0, T.CYAN)
	ic.position = Vector2(9, 9)
	disc.add_child(ic)
	top.add_child(disc)
	var h := T.label(heading, 20, 800, T.TEXT, 2)
	h.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(h)
	cv.add_child(top)
	var l := T.label(text, 13, 500, T.TEXT_2)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cv.add_child(l)
	var b := T.button(button, "PrimaryButton", "play", 56.0)
	b.pressed.connect(func() -> void:
		if is_open:
			fire.emit())
	cv.add_child(b)
	row.add_child(p)
	_cards.append({"panel": p, "text": l, "button": b})
	return l


## `map_name`: the map a solo match would be on; `over_results`: it stands over a results screen
## (its foot button goes back to it).
func open(map_name: String = "", over_results: bool = true) -> void:
	_back.text = "See results" if over_results else "Close"
	_solo_text.text = "Another war against the computer, on %s." % (map_name if map_name != "" else "the same map")
	is_open = true
	visible = true
	move_to_front()
	apply_layout()
	_dim.modulate.a = 0.0
	UIFx.fade(_dim, 1.0, 0.25)
	UIFx.pop_in(_panel, 0.0, 0.92, 0.35)
	ctx.sfx("open")


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
			visible = false
			_panel.modulate.a = 1.0)
	closed.emit()


func apply_layout() -> void:
	var c := ctx.compact
	var w := 220.0 if c else 270.0
	for cd in _cards:
		cd.panel.custom_minimum_size = Vector2(w, 0)
		cd.text.custom_minimum_size = Vector2(w - 36.0, 34.0 if c else 40.0)
		cd.text.add_theme_font_size_override("font_size", 12 if c else 13)
		cd.button.custom_minimum_size = Vector2(0, 48.0 if c else 56.0)
	_title.add_theme_font_size_override("font_size", 22 if c else 26)
	_panel.reset_size()
	var sz := _panel.get_combined_minimum_size()
	var area := ctx.clear_rect()
	var p := area.position + (area.size - sz) * 0.5
	_panel.position = Vector2(floorf(p.x + 0.5), floorf(maxf(p.y, area.position.y + 4.0) + 0.5))
	_panel.reset_size()
