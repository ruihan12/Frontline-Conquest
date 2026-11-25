extends SceneTree

const Lobby := preload("res://client/ui/lobby.gd")
const Model := preload("res://net/lobby_model.gd")

class SaveStub extends Node:
	var save := {"settings": {"guest_name": "Guest_0042"}}

	func write_save() -> void:
		pass

var fails := 0
var _paths: Array[String] = []
var _rankings_available := false


func _initialize() -> void:
	create_timer(12).timeout.connect(func() -> void:
		print("LOBBY_UI_TEST FAIL timeout")
		quit(1))
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	if not ok:
		fails += 1
		print("FAIL ", message)


func _transport(url: String, headers: PackedStringArray, method: int, body: String) -> Array:
	_check(method == HTTPClient.METHOD_GET and body.is_empty(), "read-only JSON request")
	_paths.append(url)
	await process_frame
	if url.ends_with("/me"):
		_check(headers.has("Authorization: Bearer mock-session"), "profile uses the saved token")
		return [HTTPRequest.RESULT_SUCCESS, 200, JSON.stringify({"username": "Commander_42", "elo": 1234}).to_utf8_buffer()]
	_check(url.ends_with("/leaderboard?limit=50"), "leaderboard uses expected endpoint")
	_check(headers.size() == 1, "leaderboard does not send credentials")
	if not _rankings_available:
		return [HTTPRequest.RESULT_CANT_CONNECT, 0, PackedByteArray()]
	return [HTTPRequest.RESULT_SUCCESS, 200, JSON.stringify({"players": [
		{"username": "First", "elo": 1300, "matches": 12},
		{"username": "Second", "elo": 1200, "matches": 8},
	]}).to_utf8_buffer()]


func _press(lobby: Lobby, caption: String) -> void:
	for child in lobby._body.get_children():
		if child is Button and child.text == caption and not child.disabled:
			child.pressed.emit()
			return
	_check(false, "enabled button " + caption)


func _has_text(lobby: Lobby, expected: String) -> bool:
	for child in lobby._body.get_children():
		if child is Label and child.text.contains(expected):
			return true
	return false


func _settle() -> void:
	for frame in 3:
		await process_frame


func _run() -> void:
	var game := SaveStub.new()
	root.add_child(game)
	var ctx := UICtx.new()
	var model := Model.new()
	model.auto_advance = false
	var lobby := Lobby.new(ctx, game, model, _transport)
	root.add_child(lobby)
	lobby.open()
	_check(lobby.is_open and lobby.visible, "window opens")
	_check(_has_text(lobby, "Create an account"), "guests have a ranked sign-in prompt")
	model.join_ranked()
	_check(lobby._title.text == "MULTIPLAYER", "guest cannot queue even through the model")
	_press(lobby, "Casual")
	_check(_has_text(lobby, "Host: Guest_0042's PC"), "casual lists the host")
	_check(_has_text(lobby, "Guest_0042") and _has_text(lobby, "40 bots"), "casual shows guest name and game details")
	model.start()
	_check(lobby._title.text == "CASUAL LOBBY", "host cannot start before ready")
	_press(lobby, "Ready")
	_press(lobby, "Start")
	_check(lobby._title.text == "MATCH STARTING", "ready host can start")
	_press(lobby, "Leave")
	_check(lobby._title.text == "MULTIPLAYER", "leave returns to choices")
	_check(_paths.is_empty(), "guest lobby is local")

	lobby.close()
	game.save.settings.session_token = "mock-session"
	lobby.open()
	await _settle()
	_check(_has_text(lobby, "Your Elo: 1234"), "ranked entry displays account Elo")
	_press(lobby, "Ranked")
	_check(lobby._title.text == "RANKED QUEUE" and _has_text(lobby, "Elapsed:"), "ranked queue includes elapsed timer")
	_press(lobby, "Cancel")
	model.complete_queue()
	_check(lobby._title.text == "MULTIPLAYER", "cancel prevents a stale queue from joining")
	_press(lobby, "Ranked")
	model.complete_queue()
	_check(_has_text(lobby, "Host: server") and _has_text(lobby, "1× speed"), "ranked server and speed displayed")
	_check(_has_text(lobby, "Commander_42 · Elo 1234"), "ranked player rating displayed")
	_press(lobby, "Ready")
	_check(lobby._title.text == "MATCH STARTING", "ranked server starts after readiness")
	model.finish_ranked(2, 1234, 1242)
	_check(_has_text(lobby, "Placement: #2") and _has_text(lobby, "1234 → 1242"), "ranked result displayed")
	_press(lobby, "Back")

	_press(lobby, "Leaderboard")
	await _settle()
	_check(lobby._rankings._notice.text.contains("try again"), "offline leaderboard message")
	_press(lobby, "Back")
	_rankings_available = true
	_press(lobby, "Leaderboard")
	await _settle()
	_check(lobby._rankings._rows.get_child_count() == 3, "header and both ranking rows")
	if lobby._rankings._rows.get_child_count() >= 2:
		_check(lobby._rankings._rows.get_child(1).get_child(1).text == "First", "server ranking order retained")
	_check(_paths.size() == 3, "profile and both ranking requests went to mocked account API")
	lobby.close()
	_check(not lobby.visible, "close hides lobby")
	ctx.rules = null
	print("LOBBY_UI_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
