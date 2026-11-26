extends Control

const API := preload("res://net/api.gd")
const POLL_MS := 3000

signal display_name_changed(display_name: String)

var ctx: UICtx
var g
var api: API
var is_open := false
var _panel: GlassPanel
var _body: VBoxContainer
var _notice: Label
var _countdown: Label
var _close_button: Button
var _username: LineEdit
var _password: LineEdit
var _repeat: LineEdit
var _form_button: Button
var _mode := ""
var _profile := {}
var _code := ""
var _deadline := 0
var _next_poll := 0
var _polling := false
var _busy := false
var _generation := 0
var _username_pattern := RegEx.create_from_string("^[A-Za-z0-9_]{3,16}\\z")


func _init(c: UICtx, main, transport := Callable()) -> void:
	ctx = c
	g = main
	api = API.new(self, g.save, Callable(g, "write_save"), transport)
	name = "Account"
	theme = UITheme.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hide()
	set_process(false)

	var dim := ColorRect.new()
	dim.color = UITheme.rgba(0.01, 0.015, 0.05, 0.78)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	_panel = GlassPanel.new(20, 16, 18, true, 34)
	_panel.set_tint(UITheme.rgba(0.045, 0.065, 0.13, 0.96))
	center.add_child(_panel)
	var column := UITheme.vbox(10)
	_panel.add_child(column)
	var header := UITheme.hbox(10)
	column.add_child(header)
	var title := UITheme.label("ACCOUNT", 20, 800, UITheme.TEXT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_close_button = UITheme.button("Close", "GhostButton", "", 34)
	_close_button.focus_mode = Control.FOCUS_ALL
	_close_button.pressed.connect(close)
	header.add_child(_close_button)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)
	var content := UITheme.vbox(12)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	_body = UITheme.vbox(8)
	content.add_child(_body)
	_notice = UITheme.label("", 14, 600, UITheme.TEXT_2)
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_notice)
	resized.connect(apply_layout)


func open() -> void:
	move_to_front()
	if is_open:
		return
	is_open = true
	show()
	apply_layout()
	set_process(true)
	ctx.sfx("open")
	_home()


func close() -> void:
	if _busy:
		return
	_generation += 1
	is_open = false
	hide()
	set_process(false)
	_render("")
	ctx.sfx("close")


func apply_layout() -> void:
	if _panel == null:
		return
	var padding := Vector2(ctx.insets.x + ctx.insets.z, ctx.insets.y + ctx.insets.w)
	_panel.custom_minimum_size = (size - padding - Vector2(24, 24)).clamp(Vector2(180, 110), Vector2(420, 400))
	var center := _panel.get_parent() as CenterContainer
	center.offset_left = ctx.insets.x
	center.offset_top = ctx.insets.y
	center.offset_right = -ctx.insets.z
	center.offset_bottom = -ctx.insets.w


func _home() -> void:
	_render("profile" if api.signed_in() else "guest")
	_start_request()
	var result: Dictionary
	if api.signed_in():
		result = await api.me()
		if result.ok:
			_profile = result.data
		elif result.status == 401:
			api.clear_session()
			_profile.clear()
			_end_request()
			await _home()
			_notice.text = "Your session expired. Please log in again."
			return
	elif str(api.settings().get("guest_name", "")).is_empty():
		result = await api.guest()
	_end_request()
	_render("profile" if api.signed_in() else "guest")
	var display_name := str(_profile.get("username", "")) if api.signed_in() else str(api.settings().get("guest_name", ""))
	if not display_name.is_empty():
		display_name_changed.emit(display_name)
	if not result.is_empty() and not result.ok:
		_notice.text = result.message


func _render(mode: String) -> void:
	_generation += 1
	_mode = mode
	if mode not in ["link_code", "recover_code", "reset"]:
		_code = ""
	_notice.text = ""
	_countdown = null
	_username = null
	_password = null
	_repeat = null
	_form_button = null
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()
	match mode:
		"guest":
			_label(str(api.settings().get("guest_name", "Guest")))
			_button("Create account", _render.bind("register"), true)
			_button("Log in", _render.bind("login"))
			_button("Forgot password", _render.bind("recover"))
		"profile":
			if _profile.has("username"):
				_label(str(_profile.username))
			if not _profile.has("elo"):
				_button("Refresh account", _home, true)
			else:
				_label("Elo %d   ·   %d matches" % [int(_profile.get("elo", 0)), int(_profile.get("matches", 0))])
				if _profile.get("mc_linked", false):
					_label("Minecraft linked")
					_button("Unlink Minecraft", _unlink)
				else:
					_button("Link Minecraft", _begin_link, true)
			_button("Match history", _history)
			_button("Log out", _logout)
		"register", "login", "recover", "reset":
			_build_form(mode)
		"link_code", "recover_code":
			var instruction := "Enter this link code in Minecraft." if mode == "link_code" else "Run recover %s in Minecraft." % _code
			_label(instruction)
			_label(_code)
			_button("Copy code", _copy_code)
			_countdown = _label("")
			_button("Back", _home)
			_update_countdown()


func _label(value: String) -> Label:
	var label := UITheme.label(value, 15, 600, UITheme.TEXT)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(label)
	return label


func _button(value: String, action: Callable, primary := false) -> Button:
	var button := UITheme.button(value, "PrimaryButton" if primary else "GlassButton", "", 38)
	button.focus_mode = Control.FOCUS_ALL
	button.pressed.connect(action)
	_body.add_child(button)
	return button


func _field(label: String, limit: int, secret := false) -> LineEdit:
	_label(label)
	var field := LineEdit.new()
	field.placeholder_text = label
	field.custom_minimum_size.y = 34
	field.max_length = limit
	field.secret = secret
	if secret:
		field.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_PASSWORD
	field.text_submitted.connect(func(_value: String) -> void:
		if is_instance_valid(_form_button) and _form_button.visible and not _form_button.disabled:
			_submit())
	_body.add_child(field)
	return field


func _build_form(mode: String) -> void:
	if mode != "reset":
		_username = _field("Username", 16)
	if mode != "recover":
		_password = _field("New password" if mode == "reset" else "Password", 128, true)
	if mode == "register" or mode == "reset":
		_repeat = _field("Repeat password", 128, true)
	var titles := {"register": "Continue", "login": "Log in", "recover": "Get recovery code", "reset": "Set new password"}
	_form_button = _button(titles[mode], _submit, true)
	_button("Back", _render.bind("guest"))
	var first := _username if _username != null else _password
	first.grab_focus()


func _validation_error() -> String:
	if _username != null:
		var username := _username.text
		if username.length() < 3 or _username_pattern.search(username) == null:
			return "Use 3–16 letters, digits or underscores for the username."
	if _password != null and _password.text.length() < 8:
		return "Use 8–128 characters for the password."
	if _repeat != null and _repeat.text != _password.text:
		return "The passwords must match."
	return ""


func _submit() -> void:
	if _busy:
		return
	_notice.text = _validation_error()
	if not _notice.text.is_empty():
		return
	match _mode:
		"register":
			_form_button.hide()
			_username.editable = false
			_password.editable = false
			_repeat.editable = false
			_label("Choose whether to copy your local Stars, cosmetics and stats to your account.")
			var with_progress := _button("Create account with progress", _register.bind(true), true)
			_button("Create account without progress", _register.bind(false))
			with_progress.grab_focus()
		"login":
			var password := _take_password()
			_start_request()
			var result := await api.login(_username.text, password)
			_end_request()
			await _finish_auth(result)
		"recover":
			await _begin_recovery()
		"reset":
			await _complete_recovery()


func _take_password() -> String:
	var password := _password.text
	_password.clear()
	if _repeat != null:
		_repeat.clear()
	return password


func _register(include_progress: bool) -> void:
	var username := _username.text
	var password := _take_password()
	var progress = null
	if include_progress:
		progress = {}
		for key in ["stars", "cosmetics", "stats", "unlocked"]:
			if g.save.has(key):
				progress[key] = g.save[key]
	_render("register")
	_username.text = username
	_start_request()
	var result := await api.register(username, password, progress)
	_end_request()
	await _finish_auth(result)


func _finish_auth(result: Dictionary) -> void:
	if result.ok:
		_profile = {"username": result.data.get("username", "")}
		if g.progress_sync != null: g.progress_sync.pull()  # the account's stored progress replaces this browser's
		await _home()
	else:
		_notice.text = result.message


func _history() -> void:
	_render("history")
	_button("Back", _render.bind("profile"))
	_start_request()
	var response: Dictionary = await api.history()
	_end_request()
	if not response.ok:
		_notice.text = response.message
		return
	var matches: Array = response.data.get("matches", [])
	if matches.is_empty():
		_notice.text = "No matches yet."
		return
	for row: Dictionary in matches:
		var team := " · Team %d" % int(row.team) if row.get("team") != null else ""
		_label("%s · #%d%s" % [row.get("map", "World"), int(row.get("placement", 0)), team])
		if row.get("ranked", false):
			_label("Elo %d -> %d" % [int(row.elo_before), int(row.elo_after)])


func _logout() -> void:
	_start_request()
	if g.progress_sync != null: await g.progress_sync.flush()
	var result := await api.logout()
	_end_request()
	if not api.signed_in():
		if g.progress_sync != null: g.progress_sync.on_logout()
		_profile.clear()
		await _home()
	else:
		_notice.text = result.message


func _unlink() -> void:
	_start_request()
	var result := await api.unlink()
	_end_request()
	if result.ok or result.status == 404:
		_profile.mc_linked = false
		_render("profile")
	if not result.ok:
		_notice.text = result.message


func _begin_link() -> void:
	_start_request()
	var result := await api.link_code()
	_end_request()
	if result.ok:
		_show_code(result.data, "link_code")
	elif result.status == 409:
		_profile.mc_linked = true
		_render("profile")
		_notice.text = result.message
	else:
		_notice.text = result.message


func _begin_recovery() -> void:
	_start_request()
	var result := await api.recover_start(_username.text)
	_end_request()
	if result.ok:
		_show_code(result.data, "recover_code")
	else:
		_notice.text = result.message


func _complete_recovery() -> void:
	var password := _take_password()
	_start_request()
	var result := await api.recover_complete(_code, password)
	_end_request()
	if result.ok:
		_code = ""
		_render("login")
		_notice.text = "Password updated. Log in with your new password."
	else:
		if result.status == 410:
			_render("recover")
		_notice.text = result.message


func _start_request() -> void:
	_busy = true
	_close_button.disabled = true
	_notice.text = "Contacting account server…"
	for child in _body.get_children():
		if child is Button:
			child.disabled = true
		elif child is LineEdit:
			child.editable = false


func _end_request() -> void:
	_busy = false
	_close_button.disabled = false
	_notice.text = ""
	for child in _body.get_children():
		if child is Button:
			child.disabled = false
		elif child is LineEdit:
			child.editable = true


func _show_code(data: Dictionary, mode: String) -> void:
	_code = str(data.get("code", ""))
	var now := Time.get_ticks_msec()
	_deadline = now + int(data.get("expires_in", 600)) * 1000
	_next_poll = now + POLL_MS
	_render(mode)


func _copy_code() -> void:
	# Web clipboard writes must run directly inside the button's input handler.
	DisplayServer.clipboard_set(_code)


func _update_countdown() -> void:
	var remaining := ceili(float(_deadline - Time.get_ticks_msec()) / 1000.0)
	_countdown.text = "Expires in %d:%02d" % [floori(remaining / 60.0), remaining % 60] if remaining > 0 else "Code expired."


func _process(_delta: float) -> void:
	if _countdown == null:
		return
	_update_countdown()
	var now := Time.get_ticks_msec()
	if now >= _deadline:
		_render("profile" if _mode == "link_code" else "recover")
		_notice.text = "The code expired. Request a new code to try again."
	elif not _polling and now >= _next_poll:
		_poll()


func _poll() -> void:
	_polling = true
	var generation := _generation
	var linking := _mode == "link_code"
	var result: Dictionary
	if linking:
		result = await api.mc_status()
	else:
		result = await api.recover_status(_code)
	_polling = false
	if generation != _generation:
		return
	_next_poll = Time.get_ticks_msec() + (10000 if result.status == 429 else POLL_MS)
	if not result.ok:
		_notice.text = result.message
		if linking and result.status == 401:
			await _home()
		return
	_notice.text = ""
	if linking and result.data.get("linked", false):
		_profile.mc_linked = true
		_render("profile")
	elif not linking:
		match result.data.get("state"):
			"confirmed":
				_render("reset")
			"expired":
				_render("recover")
				_notice.text = "The code expired. Request a new code to try again."
