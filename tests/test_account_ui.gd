# godot --headless --path . -s tests/test_account_ui.gd
extends SceneTree

const Account := preload("res://client/ui/account.gd")
const Api := preload("res://net/api.gd")
const TEST_BASE := "https://accounts.example.test/v1"
const TOKEN := "mock-account-token"
const PASSWORD := "test-password"
const PROFILE := {"account_id": "123", "username": "Commander_1", "elo": 1200, "matches": 3, "mc_linked": false}

class MockSave extends Node:
	var save := {
		"settings": {},
		"stars": 150,
		"cosmetics": {"owned": {"test_skin": true}},
		"stats": {"wins": 1},
	}
	var writes := 0
	var progress_sync = null

	func write_save() -> void:
		writes += 1

var fails := 0
var requests: Array[Dictionary] = []
var responses: Array[Array] = []


func _check(condition: bool, label: String) -> void:
	if not condition:
		fails += 1
		print("FAIL " + label)


func _reply(data: Dictionary, status := 200, result := HTTPRequest.RESULT_SUCCESS) -> void:
	responses.append([result, status, JSON.stringify(data).to_utf8_buffer()])


func _transport(url: String, headers: PackedStringArray, method: int, body: String) -> Array:
	requests.append({"url": url, "headers": headers, "method": method, "body": JSON.parse_string(body) if body != "" else null})
	await process_frame
	if responses.is_empty():
		_check(false, "unexpected HTTP request")
		return [HTTPRequest.RESULT_CANT_CONNECT, 0, PackedByteArray()]
	return responses.pop_front()


func _request(path: String, method: int, body = null, token := "", base := TEST_BASE) -> void:
	_check(not requests.is_empty(), "request sent for " + path)
	if requests.is_empty():
		return
	var request: Dictionary = requests.pop_front()
	_check(request.url == base + path and request.method == method, "URL and method for " + path)
	_check(request.body == (JSON.parse_string(JSON.stringify(body)) if body != null else null), "JSON body for " + path)
	var expected := PackedStringArray(["Accept: application/json"])
	if body != null:
		expected.append("Content-Type: application/json")
	if token != "":
		expected.append("Authorization: Bearer " + token)
	_check(request.headers == expected, "headers for " + path)


func _click(account: Account, caption: String) -> void:
	for child in account._body.get_children():
		if child is Button and child.text == caption and child.visible and not child.disabled:
			child.pressed.emit()
			return
	_check(false, "enabled button " + caption)


func _settle() -> void:
	for frame in 3:
		await process_frame


func _initialize() -> void:
	create_timer(15).timeout.connect(func() -> void:
		print("ACCOUNT_UI_TEST FAIL timeout")
		quit(1))
	_run.call_deferred()


func _run() -> void:
	var game := MockSave.new()
	root.add_child(game)
	var ctx := UICtx.new()
	var account := Account.new(ctx, game, _transport)
	root.add_child(account)
	_reply({"name": "Guest_0001", "token": "mock-guest-token"})
	account.open()
	_check(account.is_open and account.visible, "window opens")
	await _settle()
	_request("/guest", HTTPClient.METHOD_POST, {}, "", Api.DEFAULT_BASE)
	_check(game.save.settings.guest_name == "Guest_0001" and game.writes == 1, "guest name cached")
	_check(game.save.settings.session_token == "mock-guest-token" and not account.api.signed_in(), "guest token cached")
	account.close()
	account.open()
	_check(requests.is_empty(), "reopen uses cached guest name")
	game.save.settings.api_base = TEST_BASE + "/"

	_click(account, "Create account")
	_check(account._password.secret and account._repeat.secret, "registration masks passwords")
	_click(account, "Continue")
	_check(not account._notice.text.is_empty() and requests.is_empty(), "blank username rejected")
	account._username.text = "abc-def"
	account._password.text = PASSWORD
	account._repeat.text = PASSWORD
	_click(account, "Continue")
	_check(not account._notice.text.is_empty() and requests.is_empty(), "invalid username rejected")
	account._username.text = "Commander_1"
	account._password.text = "short"
	_click(account, "Continue")
	_check(not account._notice.text.is_empty() and requests.is_empty(), "short password rejected")
	account._password.text = PASSWORD
	account._repeat.text = "different"
	_click(account, "Continue")
	_check(not account._notice.text.is_empty() and requests.is_empty(), "mismatched passwords rejected")
	account._repeat.text = PASSWORD
	_click(account, "Continue")
	_check(requests.is_empty(), "progress choice precedes registration request")
	_reply({"error": "username_taken", "message": "That username is taken."}, 409)
	_click(account, "Create account without progress")
	await _settle()
	_request("/register", HTTPClient.METHOD_POST, {"username": "Commander_1", "password": PASSWORD})
	_check(account._notice.text == "That username is taken." and account._password.text.is_empty(), "registration error and password cleared")

	account._password.text = PASSWORD
	account._repeat.text = PASSWORD
	_click(account, "Continue")
	_reply({"token": TOKEN, "account_id": "123", "username": "Commander_1", "expires_in": 3600})
	_reply(PROFILE)
	_click(account, "Create account with progress")
	await _settle()
	_request("/register", HTTPClient.METHOD_POST, {"username": "Commander_1", "password": PASSWORD, "progress": {
		"stars": 150, "cosmetics": {"owned": {"test_skin": true}}, "stats": {"wins": 1},
	}})
	_request("/me", HTTPClient.METHOD_GET, null, TOKEN)
	_check(account._mode == "profile" and account.api.signed_in(), "registration opens account profile")
	_check(not JSON.stringify(game.save).contains(PASSWORD), "password absent from save")

	_reply({"code": "ABCD-1234", "expires_in": 600})
	_click(account, "Link Minecraft")
	await _settle()
	_request("/mc/link-code", HTTPClient.METHOD_POST, null, TOKEN)
	_check(account._mode == "link_code" and account._countdown.text.begins_with("Expires in "), "link code and countdown displayed")
	_reply({"linked": false})
	account._next_poll = 0
	await _settle()
	_request("/mc/status", HTTPClient.METHOD_GET, null, TOKEN)
	_check(account._mode == "link_code", "unlinked state keeps code visible")
	_reply({"linked": true})
	await account._poll()
	_request("/mc/status", HTTPClient.METHOD_GET, null, TOKEN)
	_check(account._mode == "profile" and account._profile.mc_linked, "link confirmation updates profile")
	_reply({}, 204)
	_click(account, "Unlink Minecraft")
	await _settle()
	_request("/mc/unlink", HTTPClient.METHOD_POST, null, TOKEN)
	_check(not account._profile.mc_linked, "unlink updates profile")

	var api := account.api
	_reply({"data": {"stars": 150}, "updated_at": "mock"})
	var result := await api.get_progress()
	_request("/progress", HTTPClient.METHOD_GET, null, TOKEN)
	_check(result.ok and result.data.data.stars == 150, "progress response")
	_reply({"error": "too_large", "message": "Progress is too large."}, 413)
	result = await api.put_progress({"stars": 150})
	_request("/progress", HTTPClient.METHOD_PUT, {"data": {"stars": 150}}, TOKEN)
	_check(not result.ok and result.error == "too_large", "progress error response")
	_reply({"players": [PROFILE]})
	result = await api.leaderboard()
	_request("/leaderboard?limit=50", HTTPClient.METHOD_GET)
	_check(result.ok and result.data.players.size() == 1, "leaderboard response")
	_reply({"elo": 1200, "matches": 3, "wins": 1})
	result = await api.rating()
	_request("/rating", HTTPClient.METHOD_GET, null, TOKEN)
	_check(result.ok and result.data.wins == 1, "rating response")

	_reply({}, 204)
	_click(account, "Log out")
	await _settle()
	_request("/logout", HTTPClient.METHOD_POST, null, TOKEN)
	_check(account._mode == "guest" and not game.save.settings.has("session_token"), "logout clears token")

	_click(account, "Forgot password")
	account._username.text = "Commander_1"
	var recovery_code := "a +/?&"
	_reply({"code": recovery_code, "expires_in": 600})
	_click(account, "Get recovery code")
	await _settle()
	_request("/recover/start", HTTPClient.METHOD_POST, {"username": "Commander_1"})
	_check(account._mode == "recover_code", "recovery code displayed")
	_reply({"state": "pending"})
	await account._poll()
	_request("/recover/status?code=a%20%2B%2F%3F%26", HTTPClient.METHOD_GET)
	_check(account._mode == "recover_code", "pending keeps recovery code visible")
	_reply({"state": "confirmed"})
	await account._poll()
	_request("/recover/status?code=a%20%2B%2F%3F%26", HTTPClient.METHOD_GET)
	_check(account._mode == "reset", "confirmation opens password reset")
	account._password.text = PASSWORD
	account._repeat.text = PASSWORD
	_reply({})
	_click(account, "Set new password")
	await _settle()
	_request("/recover/complete", HTTPClient.METHOD_POST, {"code": recovery_code, "new_password": PASSWORD})
	_check(account._mode == "login", "password reset returns to login")

	account._username.text = "Commander_1"
	for reply in [
		[{"error": "invalid_credentials", "message": "Invalid username or password."}, 401, HTTPRequest.RESULT_SUCCESS],
		[{}, 429, HTTPRequest.RESULT_SUCCESS],
		[{}, 0, HTTPRequest.RESULT_TIMEOUT],
		[{}, 0, HTTPRequest.RESULT_CANT_CONNECT],
	]:
		_reply(reply[0], reply[1], reply[2])
		account._password.text = PASSWORD
		_click(account, "Log in")
		await _settle()
		_request("/login", HTTPClient.METHOD_POST, {"username": "Commander_1", "password": PASSWORD})
		_check(not account._notice.text.is_empty() and not account._busy and account._password.text.is_empty(), "login error leaves form usable")
	_reply({"token": TOKEN, "account_id": "123", "username": "Commander_1", "expires_in": 3600})
	_reply(PROFILE)
	account._password.text = PASSWORD
	_click(account, "Log in")
	await _settle()
	_request("/login", HTTPClient.METHOD_POST, {"username": "Commander_1", "password": PASSWORD})
	_request("/me", HTTPClient.METHOD_GET, null, TOKEN)
	_check(account._mode == "profile" and account.api.signed_in(), "login restores profile")
	_reply({"code": "TIME-0000", "expires_in": 600})
	_click(account, "Link Minecraft")
	await _settle()
	_request("/mc/link-code", HTTPClient.METHOD_POST, null, TOKEN)
	account._deadline = Time.get_ticks_msec()
	await _settle()
	_check(account._mode == "profile" and account._notice.text.contains("expired"), "countdown expiration returns to profile")

	_check(responses.is_empty() and requests.is_empty(), "all mock exchanges accounted for")
	account.close()
	_check(not account.visible and not account.is_open, "window closes")
	ctx.rules = null
	print("ACCOUNT_UI_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
