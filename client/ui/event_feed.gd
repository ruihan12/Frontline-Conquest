# Port of src/client/UI/EventFeed.luau (scripts/ui/event_feed.gd, UIEventFeed).
# Lower-left event feed: stacking toasts coloured by message category that fade on their own, plus
# actionable alliance cards with an expiry bar: requests (Accept / Decline) and the "about to
# expire" renewal prompt (Renew / Ignore). Phones show one single-line toast at a time (a newer one
# replaces it; a tap dismisses it) and one-row cards.
#
# EventFeed.new(ctx, top_mode = false). Members: _stack, top_mode.
# Methods: apply_layout(bottom_y), apply_layout_top(y), stack_rect(), clear(),
# toast(category, text, icon_name?, seconds?), alliance_request(from_id), close_request(from_id),
# alliance_renewal(other, expires_at, other_asked), close_renewal(other), has_renewal_card(other),
# close_all_requests(), has_request_card(from_id); per frame update(dt).
class_name EventFeed
extends Control

const TOAST_SECONDS := 6.5
const INFO_SECONDS := 4.0
const ALERT_SECONDS := 9.0
## Phones: short lives, one line.
const PHONE_INFO_SECONDS := 2.5
const PHONE_SECONDS := 3.5
const PHONE_ALERT_SECONDS := 5.0
## Phones: a toast's widest (longer text ends in "…"), its text, and an alliance row's buttons.
const PHONE_MAX_W := 260.0
const PHONE_FONT := 11
const PHONE_BUTTON := 32.0

var ctx: UICtx
## Top-centre variant (session notices): grows downwards, visible on every screen.
var top_mode := false
var _cards := {}  # from owner id -> request card
var _recent := {}  # text -> {node, count, msec, badge}
var _bottom := 120.0
var _top_limit := 340.0
var _stack: VBoxContainer


func _init(c: UICtx, top: bool = false) -> void:
	ctx = c
	top_mode = top
	name = "EventFeed"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stack = UITheme.vbox(8)
	_stack.alignment = BoxContainer.ALIGNMENT_BEGIN if top_mode else BoxContainer.ALIGNMENT_END
	add_child(_stack)


## Top-centre placement for notices.
func apply_layout_top(y: float) -> void:
	var w := 520.0 if not ctx.compact else 380.0
	var st := _stack
	st.anchor_left = 0.5
	st.anchor_right = 0.5
	st.anchor_top = 0.0
	st.anchor_bottom = 0.0
	st.grow_horizontal = Control.GROW_DIRECTION_BOTH
	st.grow_vertical = Control.GROW_DIRECTION_END
	w = minf(w, ctx.vp.x - ctx.insets.x - ctx.insets.z - 24.0)
	var pt := ctx.place_top(w, y)
	st.offset_left = pt[0] - w * 0.5
	st.offset_right = pt[0] + w * 0.5
	st.offset_top = pt[1]
	st.offset_bottom = pt[1]
	st.custom_minimum_size = Vector2(w, 0)
	_bottom = ctx.vp.y
	_top_limit = 0.0


func apply_layout(bottom_y: float) -> void:
	var st := _stack
	_bottom = bottom_y
	if ctx.compact:
		# Phones: a narrow column under the top bar (top-left), clear of the globe's centre and of
		# the bottom-left thumb area where target / inspect cards appear.
		var lx := 8.0 + ctx.insets.x
		var ty := ctx.airship_bar.end.y + 2.0
		st.anchor_left = 0.0
		st.anchor_right = 0.0
		st.anchor_top = 0.0
		st.anchor_bottom = 0.0
		st.grow_vertical = Control.GROW_DIRECTION_END
		st.grow_horizontal = Control.GROW_DIRECTION_END
		st.alignment = BoxContainer.ALIGNMENT_BEGIN
		st.offset_left = lx
		st.offset_right = lx
		st.offset_top = ty
		st.offset_bottom = ty
		st.custom_minimum_size = Vector2(0, 0)
		_top_limit = ty
		st.queue_sort()
		_trim()
		return
	st.alignment = BoxContainer.ALIGNMENT_END
	var left := 16.0 + ctx.insets.x
	var w := 340.0
	st.anchor_left = 0.0
	st.anchor_right = 0.0
	st.anchor_top = 1.0
	st.anchor_bottom = 1.0
	st.grow_vertical = Control.GROW_DIRECTION_BEGIN
	st.grow_horizontal = Control.GROW_DIRECTION_END
	st.offset_left = left
	st.offset_right = left + w
	st.offset_bottom = -(ctx.vp.y - bottom_y)
	st.offset_top = st.offset_bottom
	st.custom_minimum_size = Vector2(w, 0)
	# Never grow into the reserved top-left area (the top bar).
	_top_limit = ctx.reserved_top_left.end.y + 12.0 + ctx.insets.y
	st.queue_sort()
	_trim()


func stack_rect() -> Rect2:
	if is_visible_in_tree():
		return _stack.get_global_rect()
	return Rect2()


func clear() -> void:
	for ch in _stack.get_children():
		_stack.remove_child(ch)
		ch.queue_free()
	_cards.clear()
	_recent.clear()


# ---------------------------------------------------------------------------------------------
# Toasts
# ---------------------------------------------------------------------------------------------
func toast(category: int, text: String, icon_name: String = "", seconds: float = -1.0) -> void:
	var T := UITheme
	if text.strip_edges() == "":
		return
	var now := UICtx.msec()
	var prev = _recent.get(text)
	if prev != null and is_instance_valid(prev.node) and not prev.node.has_meta("leaving") and now - prev.msec < 4000:
		prev.count += 1
		prev.msec = now
		prev.badge.text = "×%d" % prev.count
		prev.badge.visible = true
		prev.node.set_meta("expire", now + (PHONE_SECONDS if ctx.compact else TOAST_SECONDS) * 1000.0)
		return
	if ctx.compact and not top_mode:
		_toast_line(category, text, icon_name, seconds)
		return
	var col := T.msg_color(category)
	var card := GlassPanel.new(12.0 if not ctx.compact else 10.0, 9.0 if not ctx.compact else 6.0, T.R_MD, true, 12)
	# On touch a toast must swallow taps (they would otherwise order an attack underneath).
	card.mouse_filter = Control.MOUSE_FILTER_STOP if ctx.touch else Control.MOUSE_FILTER_IGNORE
	card.set_accent(col)
	var row := T.hbox(10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(row)
	row.add_child(_icon_disc(icon_name if icon_name != "" else T.msg_icon(category), col, 26.0 if not ctx.compact else 22.0))
	var l := T.label(text, 13 if not ctx.compact else 12, 500, T.TEXT)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size = Vector2(200, 0)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(l)
	var badge := T.label("", 11, 700, col)
	badge.visible = false
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(badge)
	var life := seconds
	if life <= 0:
		if category == Defs.MSG_ALERT:
			life = ALERT_SECONDS
		elif category == Defs.MSG_INFO:
			life = INFO_SECONDS if not ctx.compact else 3.0
		else:
			life = TOAST_SECONDS
	card.set_meta("expire", now + life * 1000.0)
	card.set_meta("kind", "toast")
	_add_toast_node(card)
	_recent[text] = {"node": card, "count": 1, "msec": now, "badge": badge}
	UIFx.pop_in(card, 0.0, 0.94, 0.32)
	_trim()


## Phones: one short line at a time. A newer toast replaces the current one, except that routine
## info never pushes out an alert that has barely been seen. Tap to dismiss.
func _toast_line(category: int, text: String, icon_name: String, seconds: float) -> void:
	var T := UITheme
	var now := UICtx.msec()
	for c in _stack.get_children():
		if not c.has_meta("leaving") and c.get_meta("kind", "") == "toast":
			if category == Defs.MSG_INFO and c.get_meta("cat", -1) == Defs.MSG_ALERT and now - c.get_meta("born", 0.0) < 2000:
				return
			_stack.remove_child(c)  # swap in place: the line never jumps
			c.queue_free()
	var col := T.msg_color(category)
	var card := GlassPanel.new(8.0, 2.0, T.R_MD, true, 10)
	card.mouse_filter = Control.MOUSE_FILTER_STOP if ctx.touch else Control.MOUSE_FILTER_IGNORE
	card.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	card.set_accent(col)
	card.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and not e.pressed:
			_remove(card, true))
	var fs := PHONE_FONT
	var row := T.hbox(5)
	row.custom_minimum_size = Vector2(0, 18)
	card.add_child(row)
	var ic := T.icon_rect(icon_name if icon_name != "" else T.msg_icon(category), 11.0, col)
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(ic)
	var l := T.label(text, fs, 600, T.TEXT)
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.custom_minimum_size = Vector2(minf(T.measure_text(text, fs, 600) + 2.0, PHONE_MAX_W), 0)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(l)
	var badge := T.label("", fs, 700, col)
	badge.visible = false
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(badge)
	var life := seconds
	if life <= 0:
		life = PHONE_ALERT_SECONDS if category == Defs.MSG_ALERT else (PHONE_INFO_SECONDS if category == Defs.MSG_INFO else PHONE_SECONDS)
	life = minf(life, PHONE_ALERT_SECONDS)
	card.set_meta("expire", now + life * 1000.0)
	card.set_meta("kind", "toast")
	card.set_meta("cat", category)
	card.set_meta("born", now)
	_add_toast_node(card)
	_recent[text] = {"node": card, "count": 1, "msec": now, "badge": badge}
	UIFx.pop_in(card, 0.0, 0.96, 0.2)
	_trim()


## Actionable cards never move under a finger: toasts come and go on the far side of them (above the
## cards in the bottom-anchored desktop stack, below them in the phone column).
func _add_toast_node(card: Control) -> void:
	_stack.add_child(card)
	if top_mode:
		return
	var first_card := -1
	var kids := _stack.get_children()
	for i in kids.size():
		if kids[i].get_meta("kind", "") == "card":
			first_card = i
			break
	if first_card >= 0 and not ctx.compact:
		_stack.move_child(card, first_card)


func _add_card_node(card: Control) -> void:
	_stack.add_child(card)
	if ctx.compact and not top_mode:
		# Phone column grows downward: cards first, toasts after them.
		var last_card := -1
		var kids := _stack.get_children()
		for i in kids.size():
			if kids[i] != card and kids[i].get_meta("kind", "") == "card":
				last_card = i
		_stack.move_child(card, last_card + 1)


func _icon_disc(icon_name: String, col: Color, px: float) -> PanelContainer:
	var T := UITheme
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.custom_minimum_size = Vector2(px, px)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	T.set_disc(p, T.c(col, 0.16), T.c(col, 0.4), 1.0)  # (upstream: flat(c(col, 0.16), px / 2, c(col, 0.4), 1))
	var ic := T.icon_rect(icon_name, px * 0.52, col)
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.add_child(ic)
	return p


func _remove(node: Control, fast: bool = false) -> void:
	if not is_instance_valid(node) or node.has_meta("leaving"):
		return
	node.set_meta("leaving", true)
	var t := node.create_tween()
	t.tween_property(node, "modulate:a", 0.0, 0.12 if fast else 0.35)
	t.tween_callback(node.queue_free)


func _trim() -> void:
	# Drop the oldest toasts while the stack would reach into the reserved top-left area.
	var guard := 0
	while guard < 12:
		guard += 1
		var h := 0.0
		var toasts: Array[Control] = []
		for c in _stack.get_children():
			if not c.has_meta("leaving"):
				h += (c as Control).get_combined_minimum_size().y + 8.0
				if c.get_meta("kind", "") == "toast":
					toasts.append(c)
		var limit := _bottom - _top_limit
		var max_toasts := 5
		if top_mode:
			max_toasts = 3
		elif ctx.compact:
			max_toasts = 1
		if (h <= limit and toasts.size() <= max_toasts) or toasts.size() == 0:
			return
		_stack.remove_child(toasts[0])
		toasts[0].queue_free()


# ---------------------------------------------------------------------------------------------
# Alliance requests
# ---------------------------------------------------------------------------------------------
## An incoming alliance request: Accept / Decline, the bar runs out with the request.
func alliance_request(from_id: int) -> void:
	_ally_card(from_id, from_id, {
		"text": "proposes an alliance",
		"row_text": "wants an alliance",
		"yes": "Accept",
		"no": "Decline",
		"on_yes": func() -> void: ctx.send({"type": "ally_reply", "target": from_id, "accept": true}),
		"on_no": func() -> void: ctx.send({"type": "ally_reply", "target": from_id, "accept": false}),
		"tick_start": ctx.render_tick(),
		"span": SimRules.ALLY_REQUEST_TICKS,
	})


## The "about to expire" event: the alliance with `other` is in its last
## ALLIANCE_EXTEND_WINDOW_TICKS; Renew sends ally_extend (renewed once both asked). The bar runs out
## with the alliance.
func alliance_renewal(other: int, expires_at: float, other_asked: bool) -> void:
	var window: int = SimRules.ALLIANCE_EXTEND_WINDOW_TICKS
	_ally_card(-other, other, {
		"text": "wants to renew your alliance" if other_asked else "alliance is about to expire",
		"row_text": "wants to renew" if other_asked else "alliance expiring",
		"yes": "Renew",
		"no": "Ignore",
		"on_yes": func() -> void: ctx.send({"type": "ally_extend", "target": other}),
		"on_no": func() -> void: pass,
		"tick_start": expires_at - window,
		"span": window,
	})


func close_renewal(other: int) -> void:
	close_request(-other)


func has_renewal_card(other: int) -> bool:
	return _cards.has(-other)


func _ally_card(key: int, owner_id: int, spec: Dictionary) -> void:
	var T := UITheme
	var s = ctx.state
	if s == null or _cards.has(key):
		return
	var o = s.get_owner(owner_id)
	if o == null:
		return
	if ctx.compact:
		_alliance_row(key, o, spec)
		return
	var card := GlassPanel.new(14.0, 12.0, T.R_MD, true, 16)
	card.set_accent(T.VIOLET)
	card.set_border(T.c(T.VIOLET, 0.35))
	card.set_meta("kind", "card")
	var v := T.vbox(8)
	card.add_child(v)
	var head := T.hbox(10)
	head.add_child(_icon_disc("alliance", T.VIOLET, 30.0))
	var tv := T.vbox(0)
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var nr := T.hbox(6)
	var sw := T.swatch(o.color, 10.0, 3)
	sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	nr.add_child(sw)
	var nl := T.label(o.name, 14, 700)
	nl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nl.custom_minimum_size = Vector2(60, 0)
	nr.add_child(nl)
	tv.add_child(nr)
	tv.add_child(T.label(spec.text, 12, 500, T.TEXT_2))
	head.add_child(tv)
	v.add_child(head)
	var bar := FillBar.new(3.0, T.VIOLET)
	bar.glow = false
	bar.set_target(1.0, true)
	v.add_child(bar)
	var btns := T.hbox(8)
	var accept := T.button(spec.yes, "PrimaryButton", "", 34.0 if not ctx.touch else 44.0)
	accept.add_theme_font_size_override("font_size", 13)
	accept.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var decline := T.button(spec.no, "GlassButton", "", 34.0 if not ctx.touch else 44.0)
	decline.add_theme_font_size_override("font_size", 13)
	decline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btns.add_child(accept)
	btns.add_child(decline)
	v.add_child(btns)
	accept.pressed.connect(func() -> void:
		spec.on_yes.call()
		close_request(key))
	decline.pressed.connect(func() -> void:
		spec.on_no.call()
		close_request(key))
	card.set_meta("tick_start", spec.tick_start)
	card.set_meta("span", spec.span)
	card.set_meta("owner_name", o.name)
	card.set_meta("bar", bar)
	_cards[key] = card
	_add_card_node(card)
	UIFx.pop_in(card, 0.0, 0.92, 0.36)
	_trim()


## Phones: one row: [alliance] ■ Name wants an alliance [✓] [✕], with a thin expiry line.
func _alliance_row(key: int, o: Dictionary, spec: Dictionary) -> void:
	var T := UITheme
	var card := GlassPanel.new(8.0, 2.0, T.R_MD, true, 14)
	card.set_accent(T.VIOLET)
	card.set_border(T.c(T.VIOLET, 0.35))
	card.set_meta("kind", "card")
	card.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var v := T.vbox(0)
	card.add_child(v)
	var fs := PHONE_FONT
	var bs := PHONE_BUTTON
	var row := T.hbox(5)
	var ic := T.icon_rect("alliance", 12.0, T.VIOLET)
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(ic)
	var sw := T.swatch(o.color, 8.0, 2)
	sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(sw)
	var nl := T.label(o.name, fs + 1, 700)
	nl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nl.custom_minimum_size = Vector2(minf(T.measure_text(o.name, fs + 1, 700) + 2.0, 100.0), 0)
	nl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(nl)
	var wl := T.label(spec.row_text, fs, 500, T.TEXT_2)
	wl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(wl)
	var accept := T.button("", "PrimaryButton", "check", bs)
	accept.name = spec.yes
	accept.custom_minimum_size = Vector2(bs, bs)
	var decline := T.button("", "GlassButton", "close", bs)
	decline.name = spec.no
	decline.custom_minimum_size = Vector2(bs, bs)
	for b in [accept, decline]:
		b.expand_icon = true
		b.add_theme_constant_override("icon_max_width", 14)
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Icon-only buttons: the theme's wide text margins would leave no room for the icon.
	var acc := T.flat(T.AMBER, T.R_MD, T.CLEAR, 0, 4.0, 4.0)
	acc.border_width_bottom = 3
	acc.border_color = T.AMBER_LO
	var acc_h: StyleBoxFlat = acc.duplicate()
	acc_h.bg_color = T.AMBER_HI
	var dec := T.flat(T.FILL, T.R_MD, T.LINE, 1, 4.0, 4.0)
	var dec_h := T.flat(T.FILL_2, T.R_MD, T.LINE_2, 1, 4.0, 4.0)
	for st in ["normal", "hover", "pressed", "disabled", "focus"]:
		var hot: bool = st != "normal" and st != "disabled"
		accept.add_theme_stylebox_override(st, acc_h if hot else acc)
		decline.add_theme_stylebox_override(st, dec_h if hot else dec)
	row.add_child(accept)
	row.add_child(decline)
	v.add_child(row)
	var bar := FillBar.new(2.0, T.VIOLET)
	bar.glow = false
	bar.set_target(1.0, true)
	v.add_child(bar)
	accept.pressed.connect(func() -> void:
		spec.on_yes.call()
		close_request(key))
	decline.pressed.connect(func() -> void:
		spec.on_no.call()
		close_request(key))
	card.set_meta("tick_start", spec.tick_start)
	card.set_meta("span", spec.span)
	card.set_meta("owner_name", o.name)
	card.set_meta("bar", bar)
	_cards[key] = card
	_add_card_node(card)
	UIFx.pop_in(card, 0.0, 0.94, 0.3)
	_trim()


func close_request(from_id: int) -> void:
	var card = _cards.get(from_id)
	_cards.erase(from_id)
	if card != null:
		_remove(card)


func close_all_requests() -> void:
	for id in _cards.keys():
		close_request(id)


func has_request_card(from_id: int) -> bool:
	return _cards.has(from_id)


## Per frame.
func update(_delta: float) -> void:
	var now := UICtx.msec()
	# (the stack's own list: _remove only starts a fade, the node goes later)
	for c in _stack.get_children():
		var e = c.get_meta("expire") if c.has_meta("expire") else null
		if e != null and now > e:
			_remove(c)
	# Expiry bars on alliance cards (drawn again when they move a pixel).
	if _cards.is_empty():
		return
	var tick := ctx.render_tick()
	var done: Array = []
	for from_id in _cards:
		var card = _cards[from_id]
		if not is_instance_valid(card):
			done.append(from_id)
		else:
			var start: float = card.get_meta("tick_start", tick)
			var left := 1.0 - (tick - start) / maxf(float(card.get_meta("span", 1)), 1.0)
			var bar = card.get_meta("bar", null)
			if bar != null:
				bar.set_instant(left)
			if left <= 0:
				done.append(from_id)
	for id in done:
		close_request(id)
