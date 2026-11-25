extends RefCounted

const DEFAULT_BASE := "https://frontline.henrymc.org/api/v1"

var _host: Node
var _save: Dictionary
var _persist: Callable
var _transport: Callable


func _init(host: Node, save: Dictionary, persist: Callable, transport := Callable()) -> void:
	_host = host
	_save = save
	_persist = persist
	_transport = transport


func settings() -> Dictionary:
	return _save.settings


func signed_in() -> bool:
	return not str(settings().get("session_token", "")).is_empty() and not settings().get("guest_session", false)


func clear_session() -> void:
	settings().erase("session_token")
	settings().erase("guest_session")
	_persist.call()


func guest() -> Dictionary:
	var result := await _request(HTTPClient.METHOD_POST, "/guest", false, {})
	if result.ok:
		if result.data.get("name") is String:
			settings().guest_name = result.data.name
		_store_token(result.data, true)
		_persist.call()
	return result


func register(username: String, password: String, progress = null) -> Dictionary:
	var body := {"username": username, "password": password}
	if progress is Dictionary:
		body.progress = progress
	return await _authenticate("/register", body)


func login(username: String, password: String) -> Dictionary:
	return await _authenticate("/login", {"username": username, "password": password})


func _authenticate(path: String, body: Dictionary) -> Dictionary:
	var result := await _request(HTTPClient.METHOD_POST, path, false, body)
	if result.ok:
		if not _store_token(result.data, false):
			return _failure(result.status, "invalid_response", "The server returned an invalid session.")
		_persist.call()
	return result


func _store_token(data: Dictionary, guest_session: bool) -> bool:
	var token = data.get("token")
	if not (token is String) or token.is_empty():
		return false
	settings().session_token = token
	settings().guest_session = guest_session
	return true


func logout() -> Dictionary:
	var result := await _request(HTTPClient.METHOD_POST, "/logout", true)
	if result.ok or result.status == 401:
		clear_session()
	return result


func me() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/me", true)


func get_progress() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/progress", true)


func put_progress(data: Dictionary) -> Dictionary:
	return await _request(HTTPClient.METHOD_PUT, "/progress", true, {"data": data})


func link_code() -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/mc/link-code", true)


func mc_status() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/mc/status", true)


func unlink() -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/mc/unlink", true)


func recover_start(username: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/recover/start", false, {"username": username})


func recover_status(code: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/recover/status?code=" + code.uri_encode())


func recover_complete(code: String, password: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/recover/complete", false, {"code": code, "new_password": password})


func leaderboard(limit := 50) -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/leaderboard?limit=%d" % limit)


func rating() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/rating", true)


func _request(method: int, path: String, auth := false, body = null) -> Dictionary:
	var base := str(settings().get("api_base", DEFAULT_BASE)).strip_edges()
	if base.is_empty() or not (base.begins_with("https://") or base.begins_with("http://localhost") or base.begins_with("http://127.0.0.1")):
		base = DEFAULT_BASE  # passwords and tokens only ever travel over https (or to a local dev server)
	var headers := PackedStringArray(["Accept: application/json"])
	if body != null:
		headers.append("Content-Type: application/json")
	if auth:
		var token := str(settings().get("session_token", ""))
		if token.is_empty():
			return _failure(401, "missing_session", "Please log in first.")
		headers.append("Authorization: Bearer " + token)
	var url := base.rstrip("/") + path
	var encoded := JSON.stringify(body) if body != null else ""
	var response: Array
	if _transport.is_valid():
		response = await _transport.call(url, headers, method, encoded)
	else:
		response = await _http(url, headers, method, encoded)
	var status: int = response[1]
	if response[0] != HTTPRequest.RESULT_SUCCESS:
		var message := "Could not reach the account server. Please try again."
		if response[0] == HTTPRequest.RESULT_TIMEOUT:
			message = "The account server took too long to respond. Please try again."
		return _failure(status, "offline", message)
	var raw: PackedByteArray = response[2]
	var json := JSON.new()
	var data: Variant = {} if raw.is_empty() else null
	if not raw.is_empty() and json.parse(raw.get_string_from_utf8()) == OK:
		data = json.data
	if status == 429:
		var error: Dictionary = data if data is Dictionary else {}
		return _failure(status, "rate_limited", str(error.get("message", "Too many attempts. Please wait and try again.")))
	if status < 200 or status >= 300:
		var error: Dictionary = data if data is Dictionary else {}
		return _failure(status, str(error.get("error", "")), str(error.get("message", "The account server returned an error (%d)." % status)))
	if not (data is Dictionary):
		return _failure(status, "invalid_response", "The account server returned an invalid response.")
	return {"ok": true, "status": status, "data": data}


func _failure(status: int, code: String, message: String) -> Dictionary:
	return {"ok": false, "status": status, "error": code, "message": message, "data": {}}


func _http(url: String, headers: PackedStringArray, method: int, body: String) -> Array:
	var request := HTTPRequest.new()
	request.timeout = 10.0
	request.max_redirects = 0
	_host.add_child(request)
	if request.request(url, headers, method, body) != OK:
		request.queue_free()
		return [HTTPRequest.RESULT_CANT_CONNECT, 0, PackedByteArray()]
	var response: Array = await request.request_completed
	request.queue_free()
	return [response[0], response[1], response[3]]
