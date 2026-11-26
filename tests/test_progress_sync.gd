# godot --headless --path . -s tests/test_progress_sync.gd
extends SceneTree

const Sync := preload("res://net/progress_sync.gd")

class Main extends Node:
	var save := {"settings": {"session_token": "tok", "api_base": "https://x.test/v1"}, "stars": 7,
		"cosmetics": {"owned": {"a": true}, "skin": "a", "flag": "", "opened": 0, "last": ""}, "stats": {"wins": 1}, "unlocked": ["mega", "reinf"]}
	var writes := 0
	func write_save_file() -> void:
		writes += 1

var fails := 0
var server_data = {}
var user := "Commander_1"
var puts: Array = []


func _check(c: bool, label: String) -> void:
	if not c:
		fails += 1
		print("FAIL " + label)


func _reply(data: Dictionary, status := 200) -> Array:
	return [HTTPRequest.RESULT_SUCCESS, status, JSON.stringify(data).to_utf8_buffer()]


func _transport(url: String, _h: PackedStringArray, method: int, body: String) -> Array:
	await process_frame
	if url.ends_with("/me"):
		return _reply({"username": user})
	if url.ends_with("/admin/token"):
		return _reply({}, 403)
	if url.ends_with("/progress"):
		if method == HTTPClient.METHOD_PUT:
			server_data = JSON.parse_string(body).data
			puts.append(server_data)
			return _reply({"ok": true})
		return _reply({"data": server_data})
	return _reply({}, 404)


func _init() -> void:
	var m := Main.new()
	root.add_child(m)
	var s := Sync.new()
	m.add_child(s)
	s.setup(m, _transport)

	# server empty: baseline pushed, local kept
	await s.pull()
	_check(m.save.stars == 7, "empty server keeps local stars")
	await s.flush()
	_check(puts.size() == 1 and puts[0].stars == 7, "baseline pushed")
	_check(m.save.settings.progress_owner == "Commander_1", "owner set")

	# change + push
	m.save.stars = 20
	s.mark_dirty()
	await s.flush()
	_check(server_data.stars == 20, "change pushed")

	# server copy wins on login
	server_data = {"stars": 500, "unlocked": ["mega"], "cosmetics": {"owned": {"z": true}}, "stats": {"wins": 9}}
	await s.pull()
	_check(m.save.stars == 500, "server stars win")
	_check("reinf" in m.save.unlocked, "required unlocks restored")
	_check(m.save.cosmetics.owned.has("z") and m.save.cosmetics.has("skin"), "cosmetics merged with defaults")

	# logout resets
	m.save.settings.erase("session_token")
	s.on_logout()
	_check(m.save.stars == 0 and not m.save.settings.has("progress_owner"), "logout resets progress")

	# other account's local progress is not inherited
	m.save.settings["session_token"] = "t2"
	m.save.settings["progress_owner"] = "Someone"
	m.save.stars = 99
	server_data = {}
	user = "Other"
	await s.pull()
	_check(m.save.stars == 0, "foreign local progress reset")

	# guest: no sync
	var m2 := Main.new()
	m2.save.settings = {"session_token": "g", "guest_session": true}
	root.add_child(m2)
	var s2 := Sync.new()
	m2.add_child(s2)
	s2.setup(m2, _transport)
	var before := puts.size()
	await s2.pull()
	m2.save.stars = 5
	s2.mark_dirty()
	await s2.flush()
	_check(puts.size() == before and m2.save.stars == 5, "guest never syncs")

	print("progress sync: %d failures" % fails)
	quit(1 if fails else 0)
