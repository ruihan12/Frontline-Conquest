extends Control

const API := preload("res://net/api.gd")
const Model := preload("res://net/lobby_model.gd")
const Rankings := preload("res://client/ui/leaderboard_screen.gd")

var ctx: UICtx
var model: Model
var api: API
var is_open := false
var _center: CenterContainer
var _panel: GlassPanel
var _title: Label
var _body: VBoxContainer
var _countdown: Label
var _rankings: Rankings
var _open_generation := 0
var _queued_at := 0
var _profile_message := ""


func _init(c: UICtx, main, backend: Model = null, transport := Callable()) -> void:
	ctx = c
	model = backend if backend != null else Model.new()
	api = API.new(self, main.save, Callable(main, "write_save"), transport)
	name = "Multiplayer"
	theme = UITheme.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hide()
	set_process(false)
	var dim := ColorRect.new()
	dim.color = UITheme.rgba(0.01, 0.015, 0.05, 0.78)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	_center = CenterContainer.new()
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_center)
	_panel = GlassPanel.new(20, 16, 18, true, 34)
	_panel.set_tint(UITheme.rgba(0.045, 0.065, 0.13, 0.96))
	_center.add_child(_panel)
	var column := UITheme.vbox(10)
	_panel.add_child(column)
	var header := UITheme.hbox(8)
	column.add_child(header)
	_title = UITheme.label("MULTIPLAYER", 20, 800, UITheme.TEXT)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title)
	var exit_button := UITheme.button("Close", "GhostButton", "", 34)
	exit_button.focus_mode = Control.FOCUS_ALL
	exit_button.pressed.connect(close)
	header.add_child(exit_button)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)
	var content := UITheme.vbox(8)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	_body = UITheme.vbox(8)
	content.add_child(_body)
	_rankings = Rankings.new(api)
	content.add_child(_rankings)
	model.lobby_updated.connect(_show_lobby)
	model.queue_state.connect(_show_queue)
	model.match_starting.connect(_show_start)
	model.match_result.connect(_show_result)
	resized.connect(apply_layout)


func open() -> void:
	move_to_front()
	if is_open:
		return
	is_open = true
	show()
	apply_layout()
	ctx.sfx("open")
	_open_generation += 1
	_load_identity()


func close() -> void:
	if not is_open:
		return
	is_open = false
	_open_generation += 1
	model.leave()
	_rankings.close()
	set_process(false)
	hide()
	ctx.sfx("close")


func apply_layout() -> void:
	var safe := Vector2(ctx.insets.x + ctx.insets.z, ctx.insets.y + ctx.insets.w)
	_panel.custom_minimum_size = (size - safe - Vector2(24, 24)).clamp(Vector2(220, 115), Vector2(500, 420))
	_center.offset_left = ctx.insets.x
	_center.offset_top = ctx.insets.y
	_center.offset_right = -ctx.insets.z
	_center.offset_bottom = -ctx.insets.w


func _load_identity() -> void:
	var generation := _open_generation
	model.configure_identity(str(api.settings().get("guest_name", "Guest_0001")), 1000, false)
	var pending := api.signed_in()
	_profile_message = "Loading your ranked profile…" if pending else ""
	_show_entry()
	if not pending:
		return
	var result: Dictionary = await api.me()
	if generation != _open_generation or not is_open:
		return
	if result.ok:
		model.configure_identity(str(result.data.get("username", "Commander")), int(result.data.get("elo", 1000)), true)
		_profile_message = ""
	else:
		_profile_message = str(result.message)
	# An account response can arrive after the player entered a casual lobby.
	if _title.text == "MULTIPLAYER":
		_show_entry()


func _reset(title: String) -> void:
	_title.text = title
	_countdown = null
	set_process(false)
	_rankings.close()
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()


func _label(value: String, color := UITheme.TEXT) -> Label:
	var label := UITheme.label(value, 14, 600, color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(label)
	return label


func _button(value: String, action: Callable, primary := false) -> Button:
	var button := UITheme.button(value, "PrimaryButton" if primary else "GlassButton", "", 40)
	button.focus_mode = Control.FOCUS_ALL
	button.pressed.connect(action)
	_body.add_child(button)
	return button


func _show_entry() -> void:
	_reset("MULTIPLAYER")
	_label("Lobby preview", UITheme.TEXT_3)
	_button("Casual", model.join_casual, true)
	_label("Unranked · Guests welcome · No Elo change", UITheme.TEXT_2)
	var ranked := _button("Ranked", model.join_ranked)
	ranked.disabled = not model.signed_in
	_label("Accounts only · Server hosted · 1× speed", UITheme.TEXT_2)
	if model.signed_in:
		_label("Your Elo: %d" % model.elo)
	elif not _profile_message.is_empty():
		_label(_profile_message, UITheme.TEXT_2)
	else:
		_label("Create an account or log in from the Account screen to play ranked.", UITheme.TEXT_2)
	_button("Leaderboard", _show_rankings)


func _show_lobby(snapshot: Dictionary) -> void:
	if not is_open:
		return
	if snapshot.is_empty():
		_show_entry()
		return
	var ranked: bool = snapshot.ranked
	_reset("RANKED LOBBY" if ranked else "CASUAL LOBBY")
	_label("Host: %s" % snapshot.host)
	_label("%s · %d bots%s" % [snapshot.map, snapshot.bots, " · 1× speed" if ranked else ""], UITheme.TEXT_2)
	_body.add_child(UITheme.hdivider())
	var ready := false
	var local_name := ""
	for player: Dictionary in snapshot.players:
		var detail := " · Elo %d" % player.elo if ranked else ""
		_label("%s%s · %s" % [player.name, detail, "Ready" if player.ready else "Not ready"])
		if local_name.is_empty():
			local_name = str(player.name)
			ready = player.ready
	_button("Not ready" if ready else "Ready", model.set_ready.bind(not ready), not ready)
	if snapshot.can_start:
		var start := _button("Start", model.start, true)
		start.disabled = not ready
	_button("Leave", model.leave)


func _show_queue(active: bool, elapsed: float) -> void:
	if not is_open:
		return
	if not active:
		if _countdown != null:
			_show_entry()
		return
	_reset("RANKED QUEUE")
	_label("Finding ranked players…")
	_queued_at = Time.get_ticks_msec() - roundi(elapsed * 1000.0)
	_countdown = _label("")
	_process(0.0)
	set_process(true)
	_button("Cancel", model.leave)


func _process(_delta: float) -> void:
	if _countdown != null:
		_countdown.text = "Elapsed: " + UITheme.fmt_time((Time.get_ticks_msec() - _queued_at) / 1000.0)


func _show_start(snapshot: Dictionary) -> void:
	if not is_open:
		return
	_reset("MATCH STARTING")
	_label("%s · Host: %s" % [snapshot.map, snapshot.host])
	_button("Leave", model.leave)


func _show_result(result: Dictionary) -> void:
	if not is_open:
		return
	_reset("RANKED RESULT")
	_label("Placement: #%d" % result.placement)
	_label("Elo: %d → %d" % [result.elo_before, result.elo_after], UITheme.AMBER)
	_button("Back", model.leave)


func _show_rankings() -> void:
	_reset("RANKED LEADERBOARD")
	_button("Back", _show_entry)
	_rankings.open()
