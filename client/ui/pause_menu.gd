# Port of src/client/UI/PauseMenu.luau (scripts/ui/pause_menu.gd, UIPauseMenu).
# Game menu: resume, how to play, settings, and leave / surrender with a confirmation step.
#
# The same window has a second page, SETTINGS: the music, border pop, territory label and "select
# before attacking" switches and "Show tips again". The top bar's gear opens the window on that
# page (on the title too); the game menu's Settings row turns to it, and DONE turns back.
#
# This port keeps its own Settings window (graphics, volumes, ...): when `port_settings` is set, the
# Settings row and the gear open that one instead of the page.
class_name PauseMenu
extends Control

signal closed
signal help_requested
signal leave_requested
signal labels_toggled(on: bool)
signal music_toggled(on: bool)
## (v 0..1, final): the music volume slider; final once the drag ends (UIRoot saves then)
signal music_volume_changed(v: float, final: bool)
signal pops_toggled(on: bool)
signal restart_requested
signal tips_reset
signal new_player_requested
signal next_match_preview


# =============================================================================================
# Switch (a row button with an animated toggle on the right)
# =============================================================================================
class Switch:
	extends Button
	var on := false
	var _k := 0.0

	func _init(text_: String, icon_name: String) -> void:
		theme = UITheme.theme()
		theme_type_variation = "GlassButton"
		focus_mode = Control.FOCUS_NONE
		custom_minimum_size = Vector2(0, 46)
		var normal := UITheme.flat(Color(1, 1, 1, 0.04), 10, Color(1, 1, 1, 0.08), 1)
		var hover := UITheme.flat(Color(1, 1, 1, 0.07), 10, Color(1, 1, 1, 0.08), 1)
		add_theme_stylebox_override("normal", normal)
		add_theme_stylebox_override("pressed", normal)
		add_theme_stylebox_override("disabled", normal)
		add_theme_stylebox_override("hover", hover)
		add_theme_stylebox_override("hover_pressed", hover)
		var h := UITheme.hbox(12)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		h.offset_left = 14.0
		h.offset_right = -70.0
		add_child(h)
		var ic := UITheme.icon_rect(icon_name, 18.0, UITheme.TEXT_2)
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(ic)
		var l := UITheme.label(text_, 14, 600)
		l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(l)
		set_process(false)
		pressed.connect(func() -> void: set_on(not on))

	func set_on(v: bool) -> void:
		on = v
		set_process(true)

	## Without the slide (the window opening).
	func snap(v: bool) -> void:
		on = v
		_k = 1.0 if v else 0.0
		queue_redraw()

	func _process(delta: float) -> void:
		var target := 1.0 if on else 0.0
		if absf(_k - target) > 1e-4:
			_k = move_toward(_k, target, delta * 8.0)
			queue_redraw()
		else:
			set_process(false)

	func _draw() -> void:
		var tw := 40.0
		var th := 22.0
		var col := Color(1, 1, 1, 0.14).lerp(UITheme.AMBER, _k)
		var x := size.x - 14.0 - tw
		var y := (size.y - th) * 0.5
		draw_style_box(UITheme.flat(col, 11), Rect2(x, y, tw, th))
		var kx := size.x + (-14.0 - tw + 11.0) + (tw - 22.0) * _k
		draw_circle(Vector2(kx, size.y * 0.5), 8.0, Color.WHITE, true, -1.0, true)


# =============================================================================================
# VolumeRow (a row like a Switch with a slider on the right: the music's level)
# =============================================================================================
## Tap or drag the track (the grab area is the row's right part, its full height), or the mouse wheel
## over the row; `changed(v, final)`: v in 0..1, final once the finger lifts (save then).
class VolumeRow:
	extends Control
	signal changed(v: float, final: bool)

	## The room the icon and label keep on the left, the gap at the right, the value's column, the gap
	## before it, and the track's limits (it takes the room left between).
	const LEFT_W := 112.0
	const RIGHT := 14.0
	const PCT_W := 40.0
	const GAP := 10.0
	const TRACK_MIN := 80.0
	const TRACK_MAX := 170.0
	## A wheel notch moves it this much.
	const WHEEL_STEP := 0.05

	var ctx: UICtx = null
	var value := 1.0
	var _drag := false
	var _hover := false

	func _init(text_: String, icon_name: String) -> void:
		name = "MusicVolume"
		custom_minimum_size = Vector2(0, 46)
		mouse_filter = Control.MOUSE_FILTER_STOP
		var h := UITheme.hbox(12)
		h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		h.offset_left = 14.0
		h.offset_right = -(RIGHT + PCT_W + GAP + TRACK_MIN)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(h)
		var ic := UITheme.icon_rect(icon_name, 18.0, UITheme.TEXT_2)
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(ic)
		var l := UITheme.label(text_, 14, 600)
		l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(l)
		mouse_entered.connect(func() -> void:
			_hover = true
			queue_redraw())
		mouse_exited.connect(func() -> void:
			_hover = false
			queue_redraw())

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseButton:
			if e.button_index == MOUSE_BUTTON_LEFT:
				if e.pressed:
					if e.position.x >= _track_x() - 18.0:
						_drag = true
						_set_from_x(e.position.x, false)
						queue_redraw()
				elif _drag:
					_drag = false
					queue_redraw()
					changed.emit(value, true)
				accept_event()
			elif e.pressed and (e.button_index == MOUSE_BUTTON_WHEEL_UP or e.button_index == MOUSE_BUTTON_WHEEL_DOWN):
				var v := clampf(value + WHEEL_STEP * (1.0 if e.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0), 0.0, 1.0)
				_set_v(roundf(v * 20) / 20, true)
				accept_event()
		elif e is InputEventMouseMotion and _drag:
			_set_from_x(e.position.x, false)

	## The track's width: the room the row leaves after the icon and label and the value.
	func _track_w() -> float:
		var room := size.x - LEFT_W - (RIGHT + PCT_W + GAP)
		return clampf(room, TRACK_MIN, TRACK_MAX)

	## The track's left edge in the row.
	func _track_x() -> float:
		return size.x - RIGHT - PCT_W - GAP - _track_w()

	func _set_from_x(x: float, final: bool) -> void:
		var v := clampf((x - _track_x()) / _track_w(), 0.0, 1.0)
		_set_v(roundf(v * 20) / 20, final)  # (steps of 5%)

	func _set_v(v: float, final: bool) -> void:
		if v != value or final:
			if v != value and ctx != null:
				ctx.sfx("ui_click", -10.0, 0, 0.8 + v * 0.6)  # (a tick per step, higher as it rises)
			set_value(v)
			changed.emit(value, final)

	## Show `v` (0..1) without firing changed.
	func set_value(v: float) -> void:
		value = clampf(v, 0.0, 1.0)
		queue_redraw()

	func _draw() -> void:
		# (a Switch's look: 4% white, 7% under the mouse, a 8% line)
		draw_style_box(UITheme.flat(Color(1, 1, 1, 0.07 if _hover else 0.04), 10, Color(1, 1, 1, 0.08), 1), Rect2(Vector2.ZERO, size))
		var tw := _track_w()
		var x0 := size.x - (RIGHT + PCT_W + GAP + tw)
		var th := 6.0
		var cy := size.y * 0.5
		draw_style_box(UITheme.flat(Color(1, 1, 1, 0.14), 3), Rect2(x0, cy - th * 0.5, tw, th))
		var fw := tw * value
		if fw > 0.5:
			draw_style_box(UITheme.flat(UITheme.AMBER, 3), Rect2(x0, cy - th * 0.5, maxf(fw, th), th))
		var k := 19.0 if _drag else 16.0
		draw_circle(Vector2(x0 + fw, cy), k * 0.5 + 1.0, Color8(120, 72, 8, 230), true, -1.0, true)
		draw_circle(Vector2(x0 + fw, cy), k * 0.5 - 1.0, Color.WHITE, true, -1.0, true)
		var f := UITheme.font(700)
		draw_string(f, Vector2(size.x - RIGHT - PCT_W, cy + 13 * 0.36), "%d%%" % int(round(value * 100)), HORIZONTAL_ALIGNMENT_RIGHT, PCT_W, 13, UITheme.TEXT_2)


# =============================================================================================
# Menu
# =============================================================================================
var ctx: UICtx
var is_open := false
var _layout_compact := -1
## "menu" or "settings", and whether the settings page was reached from the menu (DONE goes back)
var _page := "menu"
var _from_menu := false
var _confirm_action := ""
var _on_title := false
var _menu_sub := ""
var _music_on := true
var _music_keep := 1.0
## Port: when set, the Settings row calls this (the port's own Settings window) instead of turning
## the page.
var port_settings: Callable = Callable()

var _dim: ColorRect
var _panel: GlassPanel
var _v: VBoxContainer
var _title: Label
var _sub: Label
var _head_actions: HBoxContainer
var _main: HBoxContainer
var _col_a: VBoxContainer
var _col_b: VBoxContainer
var _resume: Button
var _help_btn: Button
var _settings_btn: Button
var _done: Button
var _labels: Switch
var _music: VolumeRow
var _pops: Switch
var _confirm_sw: Switch
var _tips: Button
var _new_player: Button
var _next_preview: Button
var _divider: ColorRect
var _restart: Button
var _leave: Button
var _confirm: VBoxContainer
var _confirm_text: Label
var _confirm_go: Button


func _init(c: UICtx) -> void:
	var T := UITheme
	ctx = c
	name = "PauseMenu"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_dim = ColorRect.new()
	_dim.color = Color(0.01, 0.015, 0.05, 0.6)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.gui_input.connect(func(e: InputEvent) -> void:
		# (only a press outside the window closes)
		if e is InputEventMouseButton and e.pressed and not _panel.get_global_rect().has_point(e.global_position):
			close())
	add_child(_dim)
	_panel = GlassPanel.new(22.0, 22.0, 18, true, 34)
	_panel.set_tint(Color(0.045, 0.065, 0.13, 0.94))
	_panel.custom_minimum_size = Vector2(380, 0)
	add_child(_panel)
	var v := T.vbox(14)
	_v = v
	_panel.add_child(v)
	# the head: the title and its line, and (the settings page on a phone) the page's own buttons
	# beside them, so the window is no taller than its switches
	var head_row := T.hbox(10)
	v.add_child(head_row)
	var head := T.vbox(2)
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_title = T.label("GAME MENU", 20, 800, T.TEXT, 3)
	head.add_child(_title)
	_sub = T.label("", 13, 500, T.TEXT_2)
	head.add_child(_sub)
	head_row.add_child(head)
	_head_actions = T.hbox(8)
	_head_actions.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_head_actions.visible = false
	head_row.add_child(_head_actions)
	# Items live in one column on desktop and in two side-by-side columns on phones (short screens).
	_main = T.hbox(12)
	v.add_child(_main)
	_col_a = T.vbox(8)
	_col_a.custom_minimum_size = Vector2(336, 0)
	_col_b = T.vbox(8)
	_col_b.custom_minimum_size = Vector2(336, 0)
	_main.add_child(_col_a)
	_main.add_child(_col_b)
	_resume = T.button("RESUME", "PrimaryButton", "play", 50.0)
	_resume.pressed.connect(close)
	_help_btn = T.button("How to play", "GlassButton", "help", 46.0)
	_help_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_help_btn.pressed.connect(func() -> void:
		close()
		help_requested.emit())
	_settings_btn = T.button("Settings", "GlassButton", "settings", 46.0)
	_settings_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_settings_btn.pressed.connect(func() -> void:
		if port_settings.is_valid():
			close()
			port_settings.call()
			return
		_from_menu = true
		_show_page("settings"))
	_done = T.button("DONE", "PrimaryButton", "check", 50.0)
	_done.pressed.connect(func() -> void:
		if _from_menu:
			_from_menu = false
			_show_page("menu")
		else:
			close())
	_labels = Switch.new("Territory labels", "layers")
	_labels.pressed.connect(func() -> void: labels_toggled.emit(_labels.on))
	# Music: one slider row (0% = off). Music stays on/off underneath (the top bar's button and M
	# toggle it): 0% is silent at once and switches it off when the finger lifts, any level above
	# switches it on, and the level saved and kept for the button is the last one above 0.
	_music = VolumeRow.new("Music", "music_on")
	_music.ctx = c
	_music.changed.connect(func(vol: float, final: bool) -> void:
		if vol <= 0:
			music_volume_changed.emit(0.0, false)
			if final and _music_on:
				_music_on = false
				music_toggled.emit(false)
			return
		music_volume_changed.emit(vol, final)
		if final:
			_music_keep = vol
		if not _music_on:
			_music_on = true
			music_toggled.emit(true))
	_pops = Switch.new("Border pop sound", "pops")
	_pops.pressed.connect(func() -> void: pops_toggled.emit(_pops.on))
	_confirm_sw = Switch.new("Select before attacking", "target")
	_confirm_sw.pressed.connect(func() -> void: ctx.set_setting(_confirm_key(), _confirm_sw.on))
	_tips = T.button("Show tips again", "GhostButton", "info", 44.0)
	_tips.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_tips.add_theme_font_size_override("font_size", 13)
	_tips.pressed.connect(func() -> void:
		tips_reset.emit()
		_tips.text = "Tips will show again"
		_tips.disabled = true)
	# Staging, and game admins: be a new player again.
	_new_player = T.button("Replay as new player", "GhostButton", "retreat", 44.0)
	_new_player.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_new_player.add_theme_font_size_override("font_size", 13)
	_new_player.pressed.connect(_ask_new_player)
	_new_player.visible = false
	_next_preview = T.button("Next-match screen", "GhostButton", "play", 44.0)
	_next_preview.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_next_preview.add_theme_font_size_override("font_size", 13)
	_next_preview.pressed.connect(func() -> void:
		close()
		next_match_preview.emit())
	_next_preview.visible = false
	_divider = T.hdivider()
	_restart = T.button("Restart match", "GlassButton", "retreat", 46.0)
	_restart.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_restart.pressed.connect(_ask_restart)
	# (big and solid red)
	_leave = T.button("LEAVE MATCH", "SurrenderButton", "exit", 56.0)
	_leave.pressed.connect(_ask_leave)
	_reflow(false)
	_confirm = T.vbox(12)
	_confirm.visible = false
	v.add_child(_confirm)
	_confirm_text = T.label("", 14, 500, T.TEXT)
	_confirm_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_confirm_text.custom_minimum_size = Vector2(320, 0)
	_confirm.add_child(_confirm_text)
	var row := T.hbox(10)
	var cancel := T.button("Stay", "GlassButton", "", 46.0)
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.pressed.connect(func() -> void:
		_confirm.visible = false
		_main.visible = true
		_center())
	row.add_child(cancel)
	_confirm_go = T.button("Leave", "SurrenderButton", "exit", 46.0)
	_confirm_go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_confirm_go.pressed.connect(func() -> void:
		close()
		if _confirm_action == "restart":
			restart_requested.emit()
		elif _confirm_action == "new_player":
			new_player_requested.emit()
		else:
			leave_requested.emit())
	row.add_child(_confirm_go)
	_confirm.add_child(row)


func _ask_restart() -> void:
	_confirm_action = "restart"
	_confirm_text.text = "Restart with a fresh world? This match will be lost."
	_confirm_go.text = "Restart"
	_confirm_go.icon = UITheme.icon_texture("retreat")
	_main.visible = false
	_confirm.visible = true
	_center()


func _ask_new_player() -> void:
	_confirm_action = "new_player"
	_confirm_text.text = "Play as a new player again? Your match count and the tutorial start over" + (", and this match ends." if ctx.in_match() else ".") + " What you own stays."
	_confirm_go.text = "Replay"
	_confirm_go.icon = UITheme.icon_texture("retreat")
	_main.visible = false
	_confirm.visible = true
	_center()


func _ask_leave() -> void:
	_confirm_action = "leave"
	_confirm_go.text = "Leave"
	_confirm_go.icon = UITheme.icon_texture("exit")
	if not ctx.in_match():
		close()
		leave_requested.emit()
		return
	var o = ctx.my()
	var mp := ctx.mode() == UICtx.MODE_MULTI
	if o != null and o.alive and ctx.state != null and ctx.state.phase == Defs.PHASE_PLAYING:
		_confirm_text.text = "Surrender and return to the title screen? " + ("Your nation stays on the map without a commander." if mp else "This campaign will end.")
	else:
		_confirm_text.text = "Return to the title screen?"
	_main.visible = false
	_confirm.visible = true
	_center()


## `page`: "settings" opens on the settings page (the top bar's gear), else the game menu.
func open(labels_on: bool, page: String = "menu") -> void:
	if is_open:
		return
	is_open = true
	_page = "settings" if page == "settings" else "menu"
	_from_menu = false
	_labels.snap(labels_on)
	_music_on = ctx.music_enabled()
	if ctx.music_volume() > 0:
		_music_keep = ctx.music_volume()
	_music.set_value(ctx.music_volume() if _music_on else 0.0)
	_pops.snap(ctx.pops_enabled())
	var cs = ctx.setting(_confirm_key(), ctx.touch_device or ctx.touch) if ctx.touch else ctx.setting(_confirm_key(), false)
	_confirm_sw.snap(cs == true)
	var mp := ctx.mode() == UICtx.MODE_MULTI
	var on_title := not ctx.in_match()
	_on_title = on_title
	var diff := ["Relaxed", "Standard", "Brutal"]
	var d := clampi(int(ctx.session.get("difficulty")) if (ctx.session != null and ctx.session.get("difficulty") != null) else UICtx.DEFAULT_DIFFICULTY, 0, 2)
	if on_title:
		_menu_sub = "Waiting for the next multiplayer match" if ctx.mp_waiting() else "Main menu"
	else:
		_menu_sub = "Multiplayer match" if mp else "Solo match · %s · paused" % diff[d]
	_restart.visible = not mp and not on_title
	_labels.visible = not on_title
	_confirm_sw.visible = not on_title
	_tips.text = "Show tips again"
	_tips.disabled = false
	_new_player.visible = ctx.staging or ctx.admin()
	_next_preview.visible = on_title and (ctx.staging or ctx.admin())
	var o = ctx.my()
	var alive: bool = o != null and o.alive and ctx.state != null and ctx.state.phase == Defs.PHASE_PLAYING
	_leave.visible = not on_title or ctx.mp_waiting()
	if on_title:
		_leave.text = "LEAVE QUEUE"
	else:
		_leave.text = "SURRENDER" if alive else "LEAVE MATCH"
	_main.visible = true
	_confirm.visible = false
	visible = true
	_panel.modulate.a = 1.0
	_show_page(_page)
	_dim.modulate.a = 0.0
	UIFx.fade(_dim, 1.0, 0.2)
	UIFx.pop_in(_panel, 0.0, 0.94, 0.3)
	ctx.sfx("open")


## Separate settings for touch and mouse (UIInteract.confirm_orders reads the same keys).
func _confirm_key() -> String:
	return "confirm_orders" if ctx.touch else "confirm_orders_desktop"


func sync_music(on: bool) -> void:
	_music_on = on
	if on and ctx.music_volume() <= 0:
		# (back on from the top bar or M after the slider went to 0: the last level above 0)
		ctx.set_music_volume(_music_keep, false)
	_music.set_value(ctx.music_volume() if on else 0.0)


func sync_pops(on: bool) -> void:
	_pops.set_on(on)


## The page shown: "menu" or "settings".
func page() -> String:
	return _page


## The settings page while the window is open (the top bar's gear pressed over the game menu).
func show_settings() -> void:
	if is_open and _page != "settings":
		_from_menu = true
		_show_page("settings")


func _show_page(p: String) -> void:
	_page = p
	var settings := p == "settings"
	_title.text = "SETTINGS" if settings else "GAME MENU"
	_sub.text = "Saved for next time" if settings else _menu_sub
	_confirm.visible = false
	_main.visible = true
	_layout_compact = -1
	_reflow(ctx.compact)
	_center()


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
	_reflow(ctx.compact)
	_center()


func _reflow(compact: bool) -> void:
	var want := 1 if compact else 0
	if want == _layout_compact:
		return
	_layout_compact = want
	for cc in [_resume, _help_btn, _settings_btn, _labels, _music, _pops, _confirm_sw, _tips, _new_player, _next_preview, _divider, _restart, _leave, _done]:
		if cc.get_parent() != null:
			cc.get_parent().remove_child(cc)
	var h := 44.0 if compact else 46.0
	_leave.custom_minimum_size = Vector2(0, 46.0 if compact else 56.0)
	for b in [_help_btn, _settings_btn, _restart, _labels, _music, _pops, _confirm_sw]:
		b.custom_minimum_size = Vector2(0, h)
	_resume.custom_minimum_size = Vector2(0, 46.0 if compact else 50.0)
	# one column on desktop, two side by side on phones (short screens)
	var a: Array = []
	var b2: Array = []
	# the settings page on a phone: DONE and "Show tips again" stand in the head beside the title, and
	# the title's line goes
	var slim := compact and _page == "settings"
	_head_actions.visible = slim
	_sub.visible = not slim
	_title.add_theme_font_size_override("font_size", 18 if slim else 20)
	_v.add_theme_constant_override("separation", 10 if slim else 14)
	_done.custom_minimum_size = Vector2(120, 38) if slim else Vector2(0, 46.0 if compact else 50.0)
	_tips.custom_minimum_size = Vector2(0, 38.0 if slim else 44.0)
	if slim:
		for sw in [_labels, _music, _pops, _confirm_sw]:
			sw.custom_minimum_size = Vector2(0, 42.0)
		_head_actions.add_child(_tips)
		_head_actions.add_child(_done)
		if _on_title:
			a = [_music, _new_player]
			b2 = [_pops, _next_preview]
		else:
			a = [_music, _pops, _new_player]
			b2 = [_labels, _confirm_sw]
	elif _page == "settings":
		a = [_music, _pops, _labels, _confirm_sw, _tips, _new_player, _next_preview, _done]
	elif compact:
		a = [_resume, _help_btn, _new_player]
		b2 = [_settings_btn, _restart, _leave]
	else:
		a = [_resume, _help_btn, _settings_btn, _new_player, _divider, _restart, _leave]
	for c2 in a:
		_col_a.add_child(c2)
	for c3 in b2:
		_col_b.add_child(c3)
	var w := 290 if compact else 336
	_col_a.custom_minimum_size = Vector2(w, 0)
	_col_b.custom_minimum_size = Vector2(w, 0)
	_col_b.visible = not b2.is_empty()
	_panel.set_padding(16.0 if compact else 22.0, 12.0 if slim else (14.0 if compact else 22.0), 16.0 if compact else 22.0, 12.0 if slim else (14.0 if compact else 22.0))


func _center() -> void:
	var sz := _panel.get_combined_minimum_size()
	var area := ctx.clear_rect()
	var p := area.position + (area.size - sz) * 0.5
	var y := maxf(p.y, area.position.y + 4.0)
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.position = Vector2(floorf(p.x + 0.5), floorf(y + 0.5))
	_panel.reset_size()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for cc in [_resume, _help_btn, _settings_btn, _labels, _music, _pops, _confirm_sw, _tips, _new_player, _next_preview, _divider, _restart, _leave, _done]:
			if is_instance_valid(cc) and cc.get_parent() == null:
				cc.free()
