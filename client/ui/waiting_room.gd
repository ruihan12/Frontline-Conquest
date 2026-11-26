# Online waiting room (upstream TitleScreen's public-match card): over the match's map, a bottom panel with the kind
# of match and its map, the countdown, how many players are in (and some names), "Vote to start" and Leave.
# Fed by the server's S_LOBBY packets (g.net_lobby, net/mp_host.gd); shown while the room is open, before the shared
# spawn phase. Vote and Leave act through main.gd (net_client.send_vote, _to_menu).
class_name WaitingRoom
extends Control

const LOBBY_SECS := 60.0

var ctx: UICtx
var g
var panel: GlassPanel
var _title: Label
var _count: Label
var _bar: FillBar
var _who: Label
var _vote: Button
var _leave: Button
var _accum := 0.0


func _init(c: UICtx, game) -> void:
	ctx = c
	g = game
	name = "WaitingRoom"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var T := UITheme
	panel = GlassPanel.new(24.0, 18.0, T.R_LG, true, 26)
	add_child(panel)
	var v := T.vbox(10)
	panel.add_child(v)
	var head := T.hbox(10)
	var ic := TextureRect.new()
	ic.texture = T.icon_texture("users")
	ic.custom_minimum_size = Vector2(22, 22)
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ic.modulate = T.CYAN
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(ic)
	_title = T.label("PUBLIC MATCH", 20, 800, T.TEXT, 3)
	head.add_child(_title)
	v.add_child(head)
	var row := T.hbox(10)
	var l := T.label("Match starts in", 15, 500, T.TEXT_2)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	_count = T.label("1:00", 28, 800, T.AMBER)
	row.add_child(_count)
	v.add_child(row)
	_bar = FillBar.new(5.0, T.AMBER)
	_bar.glow = false
	v.add_child(_bar)
	_who = T.label("", 13, 500, T.TEXT_2)
	_who.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_who)
	var btns := T.hbox(12)
	_vote = T.button("Vote to start", "PrimaryButton", "play", 44.0)
	_vote.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vote.pressed.connect(_on_vote)
	btns.add_child(_vote)
	_leave = T.button("Leave", "GlassButton", "exit", 44.0)
	_leave.pressed.connect(func() -> void: g._to_menu())
	btns.add_child(_leave)
	v.add_child(btns)
	visible = false


func _lobby() -> Dictionary:
	return g.net_lobby


func _on_vote() -> void:
	var lb := _lobby()
	if g.net_client != null:
		g.net_client.send_vote(not bool(lb.get("voted", false)))


## Is the room up: online viewer, spawn stage, the server says the lobby is open.
func should_show() -> bool:
	return g.net_remote and g.state == "pick" and bool(_lobby().get("on", false))


func refresh() -> void:
	var lb := _lobby()
	var left := maxf(0.0, float(lb.get("left", 0.0)))
	var secs := int(ceil(left))
	_count.text = "%d:%02d" % [secs / 60, secs % 60]
	_count.add_theme_color_override("font_color", UITheme.RED if left <= 5.0 else UITheme.AMBER)
	_bar.set_target(clampf(1.0 - left / maxf(1.0, float(lb.get("total", LOBBY_SECS))), 0.0, 1.0), true)
	var kind := "TEAM GAME" if bool(lb.get("team", false)) else "PUBLIC MATCH"
	var tm := str(lb.get("teams", ""))
	if kind == "TEAM GAME" and tm != "":
		kind += "  ·  " + tm.to_upper()
	_title.text = kind + "  ·  " + UIMaps.name_of(g).to_upper()
	var players := int(lb.get("players", 0))
	var names: Array = lb.get("names", [])
	var more := players - names.size()
	var txt := "%d / %d players" % [players, int(lb.get("max", 0))]
	if not names.is_empty():
		txt += "  ·  " + ", ".join(names.map(func(n) -> String: return str(n)))
		if more > 0:
			txt += " +%d" % more
	_who.text = txt
	var votes := int(lb.get("votes", 0))
	var need := int(lb.get("need", 1))
	var min_p := int(lb.get("vote_min", 2))
	_vote.text = ("Voted to start" if bool(lb.get("voted", false)) else "Vote to start") + "  ·  %d / %d" % [votes, need]
	_vote.disabled = players < min_p
	_vote.tooltip_text = "Needs at least %d players" % min_p if players < min_p else ""
	_place()


func _place() -> void:
	var w := minf(ctx.vp.x - 24.0, 640.0)
	panel.custom_minimum_size = Vector2(w, 0)
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.offset_left = 0.0
	panel.offset_right = 0.0
	panel.offset_top = -(18.0 + ctx.insets.w)
	panel.offset_bottom = -(18.0 + ctx.insets.w)
	panel.reset_size()


func apply_layout() -> void:
	_place()


func _process(delta: float) -> void:
	_accum += delta
	if _accum >= 0.1 and visible:
		_accum = 0.0
		refresh()
