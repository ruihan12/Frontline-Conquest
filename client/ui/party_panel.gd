# The party on the title screen (port of src/client/UI/PartyPanel.luau): who is in it (crown = leader,
# kick buttons for the leader), invites to answer (JOIN / NO), a hint, INVITE and LEAVE, and the invite
# list (players on the server, scrolling, SENT for 3 s). Phones: a PARTY pill under the top bar on the left
# that opens and closes the panel; the invite list takes the small panel's place. Desktop: the panel sits
# on the left, halfway down. Talks to a PartyModel (net/party_model.gd); a null model hides everything.
class_name PartyPanel
extends Control

const WIDTH := 250.0
## More members than this show in two columns, the panel this wide (parties of up to 8).
const ONE_COLUMN_MAX := 4
const WIDTH_WIDE := 360.0
const SENT_S := 3.0
const ROW_H := 34.0
const ROW_GAP := 6.0
const LIST_CHROME := 190.0
const LIST_CHROME_COMPACT := 165.0

signal notice(text: String)

var ctx: UICtx
var model: PartyModel
var is_open := false  ## phones: the small panel is showing
var _wide := false
var _panel: GlassPanel
var _pill: Button
var _count: Label
var _members: HBoxContainer
var _invites: VBoxContainer
var _hint: Label
var _invite_btn: Button
var _leave_btn: Button
var _list: GlassPanel
var _list_note: Label
var _list_caption: Label
var _list_empty: Label
var _list_scroll: ScrollContainer
var _list_rows: VBoxContainer
var _list_top := 60.0
var _sent := {}  ## uid -> msec of the invite


func _init(c: UICtx) -> void:
	ctx = c
	name = "PartyPanel"
	theme = UITheme.theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var T := UITheme
	_panel = GlassPanel.new(14.0, 12.0, 14, true, 24)
	add_child(_panel)
	var v := T.vbox(8)
	_panel.add_child(v)
	var head := T.hbox(8)
	var ic := T.icon_rect("users", 18.0, T.CYAN)
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(ic)
	var title := T.label("PARTY", 14, 800, T.TEXT, 2)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(title)
	_count = T.label("", 12, 600, T.TEXT_2)
	_count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_count)
	v.add_child(head)
	_members = T.hbox(12)
	v.add_child(_members)
	_invites = T.vbox(6)
	v.add_child(_invites)
	_hint = T.label("", 11, 500, T.TEXT_2)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size = Vector2(WIDTH - 28.0, 0)
	v.add_child(_hint)
	var btns := T.hbox(8)
	_invite_btn = _small_button("INVITE", "GlassButton", "users", 36.0, 12, 14)
	_invite_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_invite_btn.pressed.connect(open_list)
	btns.add_child(_invite_btn)
	_leave_btn = _small_button("LEAVE", "GhostButton", "exit", 36.0, 12, 14)
	_leave_btn.pressed.connect(func() -> void: _act("leave"))
	btns.add_child(_leave_btn)
	v.add_child(btns)

	# phones: the button that opens / closes the panel
	_pill = _small_button("PARTY", "GlassButton", "users", 40.0, 12, 16)
	_pill.pressed.connect(func() -> void:
		is_open = not is_open
		apply_layout())
	add_child(_pill)

	# the invite list
	_list = GlassPanel.new(16.0, 14.0, 16, true, 40)
	add_child(_list)
	var lv := T.vbox(10)
	_list.add_child(lv)
	var lh := T.hbox(10)
	var lic := T.icon_rect("users", 20.0, T.CYAN)
	lic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lh.add_child(lic)
	var lt := T.label("INVITE TO PARTY", 16, 800, T.TEXT, 2)
	lt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lh.add_child(lt)
	var close := _x_button(40.0, 6.0)
	close.pressed.connect(close_list)
	lh.add_child(close)
	lv.add_child(lh)
	_list_note = T.label("Players on this server. Whoever accepts joins your party.", 11, 500, T.TEXT_3)
	_list_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lv.add_child(_list_note)
	_list_caption = T.caption("On this server", 11, T.TEXT_2)
	lv.add_child(_list_caption)
	_list_empty = T.label("Nobody else is on this server yet.", 12, 500, T.TEXT_2)
	lv.add_child(_list_empty)
	_list_scroll = ScrollContainer.new()
	_list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list_rows = T.vbox(int(ROW_GAP))
	_list_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var inner := T.hbox(0)
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(_list_rows)
	var gutter := Control.new()
	gutter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gutter.custom_minimum_size = Vector2(10, 0)
	inner.add_child(gutter)
	_list_scroll.add_child(inner)
	lv.add_child(_list_scroll)
	_list.visible = false
	visible = false


## A square ghost button with a drawn cross (the theme's button padding squeezes a small icon away).
func _x_button(px: float, arm: float) -> Button:
	var b := UITheme.button("", "GhostButton", "", px)
	b.custom_minimum_size = Vector2(px, px)
	var d := Control.new()
	d.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	d.draw.connect(func() -> void:
		var mid := d.size * 0.5
		d.draw_line(mid + Vector2(-arm, -arm), mid + Vector2(arm, arm), UITheme.TEXT_2, 2.0, true)
		d.draw_line(mid + Vector2(-arm, arm), mid + Vector2(arm, -arm), UITheme.TEXT_2, 2.0, true))
	b.add_child(d)
	return b


func _small_button(text: String, variation: String, icon_name: String, h: float, fs: int, icon_px: int) -> Button:
	var b := UITheme.button(text, variation, icon_name, h)
	b.add_theme_font_size_override("font_size", fs)
	b.add_theme_constant_override("icon_max_width", icon_px)
	return b


## The model (net/party_model.gd), or null (parties off: hidden).
func bind(m: PartyModel) -> void:
	if model != null and model.changed.is_connected(refresh):
		model.changed.disconnect(refresh)
	model = m
	if model != null:
		model.changed.connect(refresh)
	refresh()


func _act(action: String, uid: int = 0) -> void:
	if model == null:
		return
	var reason := model.act(action, uid)
	ctx.sfx("click")
	if reason != "":
		notice.emit(reason)


static func _clear(box: Control) -> void:
	for ch in box.get_children():
		box.remove_child(ch)
		ch.queue_free()


## Rebuilds the panel from the model's state (server/Party.state).
func refresh() -> void:
	visible = model != null and model.enabled
	if not visible:
		return
	var T := UITheme
	var st: Dictionary = model.state()
	var me := model.local_id()
	var members: Array = st.members
	var leader: bool = st.leader
	_clear(_members)
	var columns := 2 if members.size() > ONE_COLUMN_MAX else 1
	_wide = columns > 1
	var per_column := int(ceil(float(members.size()) / columns))
	var cols: Array[VBoxContainer] = []
	for c in columns:
		var col := T.vbox(4)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_members.add_child(col)
		cols.append(col)
	for i in members.size():
		var m: Dictionary = members[i]
		var row := T.hbox(6)
		# (rows with and without a kick button line up across the columns)
		row.custom_minimum_size = Vector2(0, 26)
		var crown := T.icon_rect("crown" if m.leader else "users", 14.0, T.AMBER if m.leader else T.TEXT_3)
		crown.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(crown)
		var nm := T.label(str(m.name) + ("  (you)" if m.uid == me else ""), 13, 600, T.TEXT)
		nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		nm.clip_text = true
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nm.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(nm)
		if leader and m.uid != me:
			var kick := _x_button(26.0, 4.0)
			var uid: int = m.uid
			kick.pressed.connect(func() -> void: _act("kick", uid))
			row.add_child(kick)
		cols[i / per_column].add_child(row)
	_clear(_invites)
	for inv: Dictionary in st.invites:
		var box := T.vbox(4)
		var who := T.label(str(inv.name) + " invited you", 12, 600, T.CYAN)
		who.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		who.clip_text = true
		box.add_child(who)
		var row := T.hbox(6)
		var uid: int = inv.uid
		var yes := _small_button("JOIN", "PrimaryButton", "check", 32.0, 12, 12)
		yes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		yes.pressed.connect(func() -> void: _act("accept", uid))
		row.add_child(yes)
		var no := _small_button("NO", "GhostButton", "close", 32.0, 12, 10)
		no.pressed.connect(func() -> void: _act("decline", uid))
		row.add_child(no)
		box.add_child(row)
		_invites.add_child(box)
	var n := members.size()
	var cap := int(st.max)
	_count.text = "%d / %d" % [n, cap] if n >= 2 else ""
	_leave_btn.visible = n >= 2
	_invite_btn.disabled = n >= cap
	if n < 2:
		_hint.text = "Play public matches with friends: in a team game you're on the same team."
	elif leader:
		_hint.text = "You pick the match. Your party comes with you."
	else:
		_hint.text = "Your party leader picks the match."
	var pending := _invites.get_child_count()
	_pill.text = "PARTY  %d" % n if n >= 2 else ("PARTY  •" if pending > 0 else "PARTY")
	if pending > 0:
		is_open = true  # an invite to answer: phones open the panel
	if _list.visible:
		_refresh_list()
	apply_layout()


func open_list() -> void:
	if model == null:
		return
	if ctx.compact:
		is_open = false  # the list takes the small panel's place
	apply_layout()
	_list.visible = true
	_refresh_list()
	UIFx.pop_in(_list, 0.0, 0.94, 0.25)
	ctx.sfx("open")


func close_list() -> void:
	if _list.visible:
		_list.visible = false
		ctx.sfx("close")


## The players on this server who could be invited (not already in the party).
func _refresh_list() -> void:
	var T := UITheme
	_clear(_list_rows)
	var now := Time.get_ticks_msec()
	var shown := 0
	for p: Dictionary in model.online_players():
		shown += 1
		var uid: int = p.uid
		var row := T.hbox(8)
		row.custom_minimum_size = Vector2(0, ROW_H)
		var nm := T.label(str(p.name), 13, 600, T.TEXT)
		nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		nm.clip_text = true
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nm.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		nm.custom_minimum_size = Vector2(150, 0)
		row.add_child(nm)
		var sent := _sent.has(uid) and now - int(_sent[uid]) < int(SENT_S * 1000.0)
		var b := _small_button("SENT" if sent else "INVITE", "GhostButton" if sent else "GlassButton", "", 34.0, 12, 14)
		b.custom_minimum_size = Vector2(84, 34)
		b.disabled = sent
		b.pressed.connect(func() -> void:
			_sent[uid] = Time.get_ticks_msec()
			_act("invite", uid)
			_refresh_list()
			get_tree().create_timer(SENT_S + 0.1).timeout.connect(func() -> void:
				if is_instance_valid(self) and _list.visible:
					_refresh_list()))
		row.add_child(b)
		_list_rows.add_child(row)
	_list_empty.visible = shown == 0
	_list_caption.visible = shown > 0
	# as tall as the rows, never past the screen
	var rows_h := shown * ROW_H + maxi(shown - 1, 0) * ROW_GAP
	var room := ctx.clear_rect().end.y - _list_top - 8.0 - (LIST_CHROME_COMPACT if ctx.compact else LIST_CHROME)
	_list_scroll.visible = shown > 0
	_list_scroll.custom_minimum_size = Vector2(0, maxf(ROW_H, minf(rows_h, room)))
	_list.reset_size()


func apply_layout() -> void:
	if ctx.vp == Vector2.ZERO or not is_node_ready():
		return
	var compact := ctx.compact
	var x := 12.0 + ctx.insets.x
	var width := WIDTH_WIDE if _wide else WIDTH
	_panel.custom_minimum_size = Vector2(width, 0)
	_hint.custom_minimum_size = Vector2(width - 28.0, 0)
	_pill.visible = compact
	if compact:
		# phones: the PARTY button under the top bar on the left; the panel under it while open
		var y := maxf(ctx.reserved_top_left.end.y, 44.0) + 6.0 + ctx.insets.y
		_pill.set_anchors_preset(Control.PRESET_TOP_LEFT)
		_pill.position = Vector2(x, y)
		_pill.size = Vector2(120, 40)
		_panel.visible = is_open
		_place(_panel, 0.0, 0.0, x, y + 46.0, Control.GROW_DIRECTION_END)
	else:
		# desktop: on the left, halfway down
		_panel.visible = true
		_place(_panel, 0.0, 0.5, x + 4.0, 0.0, Control.GROW_DIRECTION_BOTH)
	_panel.reset_size()
	# the invite list: under the top bar row, growing down, its rows scrolling in what the screen leaves
	var clear := ctx.clear_rect()
	_list_top = maxf(clear.position.y + 8.0, 0.0 if compact else ctx.vp.y * 0.1)
	_list_note.visible = not compact
	_list.custom_minimum_size = Vector2(minf(360.0, ctx.vp.x - 24.0) if compact else 380.0, 0)
	_list.anchor_left = 0.5
	_list.anchor_right = 0.5
	_list.anchor_top = 0.0
	_list.anchor_bottom = 0.0
	_list.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_list.grow_vertical = Control.GROW_DIRECTION_END
	_list.offset_left = 0.0
	_list.offset_right = 0.0
	_list.offset_top = _list_top
	_list.offset_bottom = _list_top
	_list.reset_size()
	if _list.visible:
		_refresh_list()


func _place(p: Control, ax: float, ay: float, ox: float, oy: float, grow_v: int) -> void:
	p.anchor_left = ax
	p.anchor_right = ax
	p.anchor_top = ay
	p.anchor_bottom = ay
	p.grow_horizontal = Control.GROW_DIRECTION_END
	p.grow_vertical = grow_v
	p.offset_left = ox
	p.offset_right = ox
	p.offset_top = oy
	p.offset_bottom = oy
