extends Node
# Registered accounts keep their progress (stars, skins and flag ownership, unlocked arsenal, stats) on the account
# server: pulled when the game starts and after a login, pushed a few seconds after it changes. Guests (and anyone
# signed out) keep it in the local browser save only. The server's copy wins on login; a new account with nothing
# stored yet starts from this browser's progress only if that progress is not another account's.
# Local copy: user://save.json is still written, it is just a cache for a registered account.

const API := preload("res://net/api.gd")
const KEYS := ["stars", "cosmetics", "stats", "unlocked"]
const PUSH_DELAY_S := 4.0
const RETRY_S := 30.0

signal applied

var g
var api
var _dirty := false
var _wait := 0.0
var _busy := false
var _pulling := false
var _pulled := false  # this session's progress was loaded from the server (nothing is pushed before that)
var _last_sent := ""


func setup(main, transport := Callable()) -> void:
	g = main
	api = API.new(self, g.save, Callable(g, "write_save_file"), transport)


func active() -> bool:
	return api != null and api.signed_in()


## Called by game.write_save: a push is due if the account's progress changed.
func mark_dirty() -> void:
	if _pulled and active():
		_dirty = true
		_wait = maxf(_wait, 0.0)


func _payload() -> Dictionary:
	var p := {}
	for k in KEYS:
		if g.save.has(k):
			p[k] = g.save[k]
	return p


static func _defaults() -> Dictionary:
	return {"cosmetics": {"owned": {}, "skin": "", "flag": "", "opened": 0, "last": ""}, "stars": 0,
		"unlocked": ["mega", "reinf"]}


func _reset_local() -> void:
	var d := _defaults()
	for k in KEYS:
		g.save.erase(k)
	for k in d:
		g.save[k] = d[k]


func _apply(d: Dictionary) -> void:
	var s: Dictionary = g.save
	if d.has("stars"):
		s.stars = maxi(0, int(d.stars))
	if d.get("unlocked") is Array:
		var u: Array = d.unlocked.duplicate()
		for need in ["mega", "reinf"]:
			if not need in u:
				u.append(need)
		s.unlocked = u
	if d.get("cosmetics") is Dictionary:
		var c: Dictionary = _defaults().cosmetics
		for k in d.cosmetics:
			c[k] = d.cosmetics[k]
		s.cosmetics = c
	if d.has("stats"):
		s["stats"] = d.stats


## After startup or a login: the account's stored progress replaces this browser's. Offline: keep playing locally,
## nothing is pushed until a pull has worked.
func pull() -> void:
	if _pulling or not active():
		return
	_pulling = true
	_pulled = false
	var me: Dictionary = await api.me()
	var got: Dictionary = {}
	if me.get("ok", false):
		got = await api.get_progress()
	_pulling = false
	if not me.get("ok", false) or not got.get("ok", false):
		if int(me.get("status", 0)) == 401:
			api.clear_session()
		_wait = RETRY_S
		_dirty = false
		return
	var name := str(me.data.get("username", ""))
	var stored = got.data.get("data", {})
	if stored is Dictionary and not (stored as Dictionary).is_empty():
		_apply(stored)
	else:
		var owner := str(g.save.settings.get("progress_owner", ""))
		if owner != "" and owner != name:
			_reset_local()  # the progress here belongs to another account
	g.save.settings["progress_owner"] = name
	g.write_save_file()
	_pulled = true
	_last_sent = ""
	_dirty = true  # (sends the baseline when the server had nothing, and is a no-op when it matches)
	_wait = 0.0
	applied.emit()


## Signed out of an account: the progress goes back to a fresh guest's (it lives on the server).
func on_logout() -> void:
	_pulled = false
	_dirty = false
	_last_sent = ""
	if str(g.save.settings.get("progress_owner", "")) != "":
		_reset_local()
		g.save.settings.erase("progress_owner")
		g.write_save_file()
		applied.emit()


func flush() -> void:
	if _dirty and _pulled and active() and not _busy:
		await _push()


func _process(dt: float) -> void:
	if not _dirty or not _pulled or _busy or api == null:
		return
	_wait -= dt
	if _wait > 0.0:
		return
	if not active():
		_dirty = false
		return
	_push()


func _push() -> void:
	var p := _payload()
	var enc := JSON.stringify(p)
	if enc == _last_sent:
		_dirty = false
		return
	_busy = true
	var r: Dictionary = await api.put_progress(p)
	_busy = false
	if r.get("ok", false):
		_last_sent = enc
		_dirty = enc != JSON.stringify(_payload())  # changed while it was sending
		_wait = PUSH_DELAY_S
	else:
		_wait = RETRY_S  # offline / server busy: try again later
		if int(r.get("status", 0)) == 401:
			api.clear_session()
			_dirty = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		flush()
