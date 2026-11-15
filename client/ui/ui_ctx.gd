# Port of src/client/UI/UICtx.luau.
# The UI's shared context: what every HUD part reads (the bound GameState, the session, the world
# view, the audio director), layout metrics, the Attack ratio, settings, and small helpers.
#
# Left out because Godot has them: data()/mod()/prime() (module loading), the Rect helpers (Rect2),
# u8/i32 (Packed arrays), the raw drawing helpers (CanvasItem._draw), to_logical/to_view (the
# canvas_items stretch mode makes viewport px = logical px).
class_name UICtx
extends RefCounted

signal state_bound
signal layout_changed
signal ratio_changed(r: float)
## an order was held back by troop_floor: trimmed to what may go, or not sent (UIAdvisor says why)
signal floor_held
signal local_changed

const MODE_TITLE := 0
const MODE_SOLO := 1
const MODE_MULTI := 2
const DEFAULT_DIFFICULTY := 0
const RATIO_STOPS: Array[float] = [0.10, 0.25, 0.35, 0.50, 0.75]
const DEFAULT_RATIO := 0.25
const TICK_RATE := 10.0  # Defs.TICK_RATE

# Defs: phases, owner kinds, terrain
const PHASE_LOBBY := 0
const PHASE_SPAWN := 1
const PHASE_PLAYING := 2
const PHASE_OVER := 3
const KIND_TRIBE := 0
const KIND_NATION := 1
const KIND_HUMAN := 2
const T_OCEAN := 0
const T_LAKE := 1
const T_PLAINS := 2
const T_HIGHLAND := 3
const T_MOUNTAIN := 4
const T_TUNDRA := 5
const T_ICECAP := 6

const SFX := {
	"hover": "ui_hover", "click": "ui_click", "open": "ui_open", "close": "ui_back", "deny": "ui_error",
	"toast": "ui_tab", "confirm": "ui_confirm", "tab": "ui_tab", "locked": "ui_locked",
	"star_tick": "star_tick", "star_get": "star_get", "buy": "buy_spend", "unlock": "unlock",
	"expand": "expand", "attack": "attack_launch", "boat": "boat_launch", "build": "build",
	"warship": "warship", "nuke_launch": "nuke_launch", "explosion": "nuke_explosion",
	"intercept": "sam_intercept", "alliance": "alliance", "betrayal": "betrayal", "alarm": "nuke_alarm",
	"eliminate": "eliminate", "victory": "victory", "defeat": "defeat", "tick": "countdown_tick",
	"start": "game_start", "spawn": "spawn_confirm", "under_attack": "under_attack",
	"ally_request": "ally_request", "ship_lost": "ship_sunk", "ship_kill": "ship_kill",
	"trade_captured": "trade_capture", "trade_lost": "trade_lost", "warship_retreat": "warship_retreat",
	"veterancy": "veterancy", "sam_launch": "sam_launch",
}
const SFX_FALLBACK := {
	"close": "ui_click", "toast": "ui_open", "confirm": "ui_click", "tab": "ui_click", "locked": "ui_error",
	"star_tick": "ui_hover", "star_get": "ui_open", "buy": "ui_click", "unlock": "alliance",
	"under_attack": "ui_error", "ally_request": "ui_open", "ship_lost": "sam_intercept",
	"ship_kill": "sam_intercept", "trade_captured": "build", "trade_lost": "ui_error",
	"warship_retreat": "ui_open", "veterancy": "alliance", "sam_launch": "attack_launch",
}
const SFX_GAP := {
	"hover": 60, "click": 40, "tab": 40, "confirm": 80, "locked": 200, "star_tick": 28, "unlock": 900,
	"toast": 400, "attack": 180, "expand": 180, "boat": 200, "build": 150, "explosion": 220,
	"alarm": 1500, "tick": 300, "deny": 200, "under_attack": 4000, "ally_request": 1500,
	"ship_lost": 1500, "ship_kill": 1500, "trade_captured": 2500, "trade_lost": 3000,
	"warship_retreat": 3000, "veterancy": 2000, "sam_launch": 100, "intercept": 120, "shell_fire": 50,
	"shell_hit": 50, "shell_splash": 50, "ship_sink": 300,
}

var session = null  # client/session.gd (RWSession)
var world = null  # the map view
var audio = null  # the audio director
var state = null  # client/game_state.gd (RWGameState)
## Mode the bound state belongs to (a queued MP client still shows the title state).
var state_mode := MODE_TITLE
## The UI root Control (full screen) once UIRoot built it.
var root: Control = null
var rules = null  # UIRules
## Persisted settings ([ui] section of user://settings.cfg).
var settings := {}
# Layout metrics (logical px)
var vp := Vector2(1600, 900)
## Safe area: left, top, right, bottom.
var insets := Vector4(0, 0, 0, 0)
## Phone-sized viewport.
var compact := false
## Last pointer input was touch (or a touch device).
var touch := false
var touch_device := false
var staging := false
## Room for the single-row command bar.
var wide := true
## Top-left rectangle owned by the top-bar buttons.
var reserved_top_left := Rect2(0, 0, 420, 320)
var airship_bar := Rect2(0, 0, 350, 58)
var ratio := DEFAULT_RATIO
## The Attack bar stops here (1 = no cap) and an order leaves this share of the army's cap at home
## (NAN = no floor): the tutorial sets both while it runs.
var ratio_max := 1.0
var troop_floor := NAN
## Tick at which the local player's nation was first seen in play this match (alive_seconds)
var alive_from_tick := NAN
## Tick at which the PLAYING phase began (match clock and durations come from game ticks).
var play_start_tick := -1.0
## Test hook: when x >= 0 this replaces the real pointer position.
var debug_mouse := Vector2(-1, -1)
## Last pointer position seen (logical px).
var pointer := Vector2(-1, -1)
## Shared hover card (set by UIRoot).
var tooltip = null
## First-match coach marks (set by UIRoot).
var coach = null
var telemetry = null
## Last intents sent (tests use this to prove one tap = one order).
var sent_log: Array = []
var _sfx_last := {}
var _save_pending := false
## Widgets.sound_serial: a sound was asked for, so default button press sounds stay out of its way.
var sound_serial := 0


func _init() -> void:
	_load_settings()
	ratio = DEFAULT_RATIO


static func commas(n: float) -> String:
	var s := str(int(floor(absf(n) + 0.5)))
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return "-" + out if n < 0 else out


static func msec() -> float:
	return float(Time.get_ticks_msec())


static func luminance(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


# =============================================================================================
# Session / state
# =============================================================================================
func mode() -> int:
	if session == null:
		return MODE_TITLE
	return int(session.mode)


func in_match() -> bool:
	return mode() != MODE_TITLE and state_mode == mode()


## Waiting in the multiplayer queue (mode switched, match state not yet received).
func mp_waiting() -> bool:
	return mode() == MODE_MULTI and state_mode != MODE_MULTI


func me() -> int:
	return int(state.local_owner) if state != null else 0


## The local owner (a Dictionary: id, name, color, tiles, troops, max_troops, gold, alive, spawned,
## kind, team), or null.
func my():
	if state == null:
		return null
	return state.get_owner(state.local_owner)


static func _ranks_before(o: Dictionary, p: Dictionary) -> bool:
	return o.tiles > p.tiles or (o.tiles == p.tiles and o.id < p.id)


## GameState.ranking()'s first (most land among the living; ties: the lower id), or null.
func leader():
	if state == null:
		return null
	var best = null
	for o in state.owners():
		if o.alive and o.tiles > 0 and (best == null or _ranks_before(o, best)):
			best = o
	return best


## An owner's place in the ranking (1-based; 0: not in it).
func rank_of(id: int) -> int:
	var mine = state.get_owner(id) if state != null else null
	if mine == null or not (mine.alive and mine.tiles > 0):
		return 0
	var r := 1
	for o in state.owners():
		if o.id != mine.id and o.alive and o.tiles > 0 and _ranks_before(o, mine):
			r += 1
	return r


## A commander that still has to place a capital (spawn phase, or dropping into a running match).
func needs_spawn() -> bool:
	var o = my()
	if o == null or not o.alive or not in_match() or state == null:
		return false
	var ph: int = state.phase
	return (not o.spawned) and (ph == PHASE_SPAWN or ph == PHASE_PLAYING)


func alive_player() -> bool:
	var o = my()
	return o != null and o.alive and in_match()


func lobby() -> Dictionary:
	if session == null:
		return {}
	var l = session.get("lobby")
	return l if l is Dictionary else {}


func send(intent: Dictionary) -> void:
	if not is_nan(troop_floor) and (intent.get("type") == "attack" or intent.get("type") == "boat"):
		var share: float = minf(float(intent.get("ratio", ratio)), floor_share())
		if share < ratio - 1e-6:
			floor_held.emit()
		if share <= 0.001:
			return
		intent["ratio"] = share
	sent_log.append({"msec": msec(), "intent": intent})
	if sent_log.size() > 64:
		sent_log.pop_front()
	if session != null and session.has_method("send_intent"):
		session.send_intent(intent)
	if telemetry != null:
		telemetry.on_intent(intent)


func session_call(method: String, args: Array = []):
	if session == null or not session.has_method(method):
		return null
	return session.callv(method, args)


func tick_seconds(ticks: float) -> float:
	return ticks / TICK_RATE


## Seconds of play so far (from game ticks, so pausing / time-lapse are exact).
func match_seconds() -> float:
	if state == null or play_start_tick < 0.0:
		return 0.0
	return maxf(0.0, (render_tick() - play_start_tick) / TICK_RATE)


func admin() -> bool:
	return false


## Seconds the local player's nation has been in play this match (0 before).
func alive_seconds() -> float:
	if state == null or play_start_tick < 0.0 or not alive_player():
		return 0.0
	var now := render_tick()
	if is_nan(alive_from_tick):
		alive_from_tick = now
	return maxf(0.0, (now - alive_from_tick) / TICK_RATE)


## Multiplayer match length in seconds.
func match_limit_s() -> float:
	if session != null:
		var v = session.get("MP_TIME_LIMIT_S")
		if v is float or v is int:
			return float(v)
	return 2400.0


## Solo only: freeze the local simulation while a modal (help, game menu) is open.
func set_paused(on: bool) -> void:
	if mode() == MODE_SOLO:
		session_call("set_paused", [on])


func render_tick() -> float:
	if state == null:
		return 0.0
	return maxf(float(state.render_tick), float(state.tick))


# =============================================================================================
# World
# =============================================================================================
func world_call(method: String, args: Array = []):
	if world == null or not world.has_method(method):
		return null
	return world.callv(method, args)


func set_world_input(on: bool) -> void:
	if world == null:
		return
	if world.has_method("set_input_enabled"):
		world.set_input_enabled(on)
	else:
		world.set("input_enabled", on)


## WorldView.set_aim(kind, tile, radius_tiles, valid, detail, level).
func set_aim(kind: String, tile: int, radius: float, valid: bool = true, detail: String = "", level: int = 1) -> void:
	world_call("set_aim", [kind, tile, radius, valid, detail, level])


## Pointer position in logical px.
func mouse_pos() -> Vector2:
	if debug_mouse.x >= 0.0:
		return debug_mouse
	if touch and pointer.x >= 0.0:
		return pointer
	if root != null and root.is_inside_tree():
		return root.get_viewport().get_mouse_position()
	return pointer if pointer.x >= 0 else Vector2.ZERO


func ui_scale() -> float:
	return 1.0


## Tile under a screen point (-1 if none).
func tile_at(pos: Vector2) -> int:
	var v = world_call("tile_at_screen", [pos])
	return int(v) if (v is int or v is float) else -1


## Screen area modals and transient pop-ups may use.
func clear_rect() -> Rect2:
	var top := maxf(insets.y, airship_bar.end.y)
	if compact:
		top = maxf(top, reserved_top_left.end.y)
	return Rect2(insets.x, top, vp.x - insets.x - insets.z, vp.y - top - insets.w)


## Where a top-centred panel of width `w` can sit at height `y` without touching the top-left
## reserved HUD: returns [dx from centre, top].
func place_top(w: float, y: float) -> Array:
	var margin := 8.0
	var left := (vp.x - w) * 0.5
	var res := reserved_top_left
	if y >= res.end.y or left >= res.end.x + margin:
		return [0.0, y]
	var dx := res.end.x + margin - left
	if left + dx + w <= vp.x - insets.z - margin:
		return [dx, y]
	return [0.0, res.end.y + 4.0]


## Horizontal nudge for a top-centred panel of width `w` so it clears the reserved top-left area.
func clear_of_reserved(w: float) -> float:
	var min_left := reserved_top_left.end.x + 12.0
	var left := (vp.x - w) * 0.5
	return maxf(0.0, min_left - left)


## Screen position of a tile in logical px, (-1, -1) without a world.
func tile_screen_pos(tile: int) -> Vector2:
	var v = world_call("screen_pos_of_tile", [tile])
	if not (v is Vector2) or v.x < 0:
		return Vector2(-1, -1)
	return v


# =============================================================================================
# Audio
# =============================================================================================
## `pitch`: an exact playback speed (instead of the small random jitter); < 0 = none.
func sfx(id: String, volume_db: float = 0.0, pitch_jitter: float = 0.04, pitch: float = -1.0) -> void:
	var a = audio
	if a == null or not a.has_method("play_sfx"):
		return
	sound_serial += 1
	var now := msec()
	var gap: float = SFX_GAP.get(id, 60)
	if now - float(_sfx_last.get(id, -100000.0)) < gap:
		return
	_sfx_last[id] = now
	var sfx_name: String = SFX.get(id, id)
	var fb = SFX_FALLBACK.get(id)
	if fb != null and a.has_method("has_sfx") and not a.has_sfx(sfx_name):
		sfx_name = fb
	a.play_sfx(sfx_name, volume_db, pitch_jitter, pitch)


func music_enabled() -> bool:
	if audio != null and audio.has_method("is_music_enabled"):
		return bool(audio.is_music_enabled())
	return true


func set_music(on: bool) -> void:
	if audio != null and audio.has_method("set_music_enabled"):
		audio.set_music_enabled(on)


func music_volume() -> float:
	if audio != null and audio.has_method("music_volume"):
		return float(audio.music_volume())
	return 1.0


func set_music_volume(v: float, save: bool = false) -> void:
	if audio != null and audio.has_method("set_music_volume"):
		audio.set_music_volume(v, save)


func pops_enabled() -> bool:
	if audio != null and audio.has_method("is_pops_enabled"):
		return bool(audio.is_pops_enabled())
	return true


func set_pops(on: bool) -> void:
	if audio != null and audio.has_method("set_pops_enabled"):
		audio.set_pops_enabled(on)


func set_music_mood(mood: String) -> void:
	if audio != null and audio.has_method("set_music_mood"):
		audio.set_music_mood(mood)
	elif audio != null and audio.has_method("play_theme"):
		audio.play_theme("menu" if (mood == "title" or mood == "wait") else "war")


func play_theme(theme_name: String) -> void:
	if audio != null and audio.has_method("play_theme"):
		audio.play_theme(theme_name)


# =============================================================================================
# Attack ratio & settings
# =============================================================================================
## The most of the army any order may send now: what stands above `troop_floor`. Under 2% counts as
## nothing (0).
func floor_share() -> float:
	var o = my()
	if is_nan(troop_floor) or o == null or float(o.get("max_troops", 0)) <= 0 or float(o.get("troops", 0)) <= 0:
		return 1.0
	var allowed: float = (o.troops - troop_floor * o.max_troops) / o.troops
	return 0.0 if allowed < 0.02 else minf(allowed, 1.0)


## The share of the army an order sends now: the slider's, trimmed to floor_share().
func order_ratio() -> float:
	return minf(ratio, floor_share())


## The index (0-based) in RATIO_STOPS of the stop nearest `r` among those not above `max_r` (the
## lowest stop when none is). Half way between two stops is the lower one.
static func ratio_stop_index(r: float, max_r: float = 1.0) -> int:
	var top := max_r + 1e-6
	var best := 0
	for i in range(1, RATIO_STOPS.size()):
		if RATIO_STOPS[i] <= top and absf(RATIO_STOPS[i] - r) < absf(RATIO_STOPS[best] - r) - 1e-9:
			best = i
	return best


static func ratio_stop(r: float, max_r: float = 1.0) -> float:
	return RATIO_STOPS[ratio_stop_index(r, max_r)]


## The Attack ratio: the stop nearest `r` that ratio_max allows.
func set_ratio(r: float) -> void:
	var v := ratio_stop(r, ratio_max)
	if absf(v - ratio) < 1e-5:
		return
	ratio = v
	ratio_changed.emit(v)


## The highest share the Attack bar gives (1: every stop).
func set_ratio_max(max_r: float) -> void:
	ratio_max = max_r
	ratio = ratio_stop(ratio, max_r)
	ratio_changed.emit(ratio)


## One stop up (`dir` > 0) or down: the Q / E keys and the mouse wheel.
func step_ratio(dir: float) -> void:
	var i := ratio_stop_index(ratio, ratio_max)
	set_ratio(RATIO_STOPS[clampi(i + (1 if dir > 0 else -1), 0, RATIO_STOPS.size() - 1)])


func reset_ratio() -> void:
	set_ratio(DEFAULT_RATIO)


## Troops sent by an attack at the current ratio.
func troops_for_ratio() -> float:
	var o = my()
	return float(o.get("troops", 0)) * order_ratio() if o != null else 0.0


func setting(key: String, default = null):
	var v = settings.get(key)
	return default if v == null else v


func set_setting(key: String, value) -> void:
	settings[key] = value
	_save_later()


func _load_settings() -> void:
	var v = session_call("load_settings", ["ui"])
	if v is Dictionary:
		for k in v:
			settings[k] = v[k]


## Re-read settings once a session is attached (UIRoot.setup).
func reload_settings() -> void:
	_load_settings()


func _save_later() -> void:
	if _save_pending:
		return
	_save_pending = true
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		_save_pending = false
		_save_now()
		return
	tree.create_timer(0.6).timeout.connect(func() -> void:
		_save_pending = false
		_save_now())


func _save_now() -> void:
	session_call("save_settings", ["ui", settings.duplicate()])


# =============================================================================================
# Hints (hover cards anchored to controls; suppressed on touch)
# =============================================================================================
func show_hint(anchor: Control, spec: Dictionary, force: bool = false) -> void:
	if tooltip != null and (force or not touch):
		tooltip.show_anchor(spec, anchor)


func hide_hint(anchor: Control = null) -> void:
	var tt = tooltip
	if tt == null or tt.place != tt.PLACE_ANCHOR:
		return
	if anchor == null or tt.anchor_is(anchor):
		tt.hide_tip()


func pause_menu_open() -> bool:
	return false


func username() -> String:
	var d = session_call("local_display_name")
	return d if (d is String and d != "") else "Commander"


# =============================================================================================
# Owners
# =============================================================================================
## Progress toward victory: share of the land that is not fallout.
func win_share(id: int) -> float:
	var s = state
	if s == null or s.map == null:
		return 0.0
	var o = s.get_owner(id)
	if o == null:
		return 0.0
	var denom: int = int(s.map.contestable_count) - int(s.fallout_count)
	return float(o.tiles) / maxf(denom, 1)


## A team game: team `t`'s progress toward victory.
func team_share(t: int) -> float:
	var s = state
	if s == null or s.map == null or t == 0:
		return 0.0
	var tiles := 0
	for o in s.owners():
		if o.team == t and o.alive:
			tiles += int(o.tiles)
	return float(tiles) / maxf(int(s.map.contestable_count) - int(s.fallout_count), 1)


## A team game: the team's name as players read it ("Red team", "Team 3", "Humans").
func team_label(t: int) -> String:
	var s = state
	var n: String = s.team_name(t) if (s != null and s.has_method("team_name")) else ""
	if n == "":
		return ""
	if n.begins_with("Team ") or n == "Humans" or n == "Nations":
		return n
	return n + " team"


## "You", "Teammate", "Ally", "Traitor", "At war", "Neutral".
func relation(id: int) -> String:
	var s = state
	if s == null or id == 0:
		return ""
	if id == me():
		return "You"
	if s.has_method("same_team") and s.same_team(me(), id):
		return "Teammate"
	if s.are_allies(me(), id):
		return "Ally"
	if s.is_traitor(id):
		return "Traitor"
	if at_war(id):
		return "At war"
	return "Neutral"


func relation_color(rel: String) -> Color:
	if rel == "You":
		return UITheme.AMBER
	elif rel == "Ally" or rel == "Teammate":
		return UITheme.GREEN
	elif rel == "Traitor":
		return UITheme.RED
	elif rel == "At war":
		return UITheme.ORANGE
	return UITheme.TEXT_2


func at_war(id: int) -> bool:
	var s = state
	var mine := me()
	if s == null or mine == 0:
		return false
	for a in s.attacks():
		if (a.attacker == mine and a.target == id) or (a.attacker == id and a.target == mine):
			return true
	return false


func kind_title(kind: int) -> String:
	if kind == KIND_TRIBE:
		return "Tribe"
	elif kind == KIND_HUMAN:
		return "Commander"
	return "Nation"


func terrain_at(tile: int) -> int:
	return int(state.map.terrain_at(tile))


func terrain_title(tile: int) -> String:
	var s = state
	if s == null or tile < 0:
		return ""
	if s.has_fallout(tile):
		return "Fallout"
	match terrain_at(tile):
		T_OCEAN: return "Ocean"
		T_LAKE: return "Lake"
		T_PLAINS: return "Plains"
		T_HIGHLAND: return "Highland"
		T_MOUNTAIN: return "Mountains"
		T_TUNDRA: return "Tundra"
		T_ICECAP: return "Ice cap"
	return ""


## Structure within `radius` tiles of `tile` (exact tile first), or null. Ties go to the oldest
## structure.
func structure_at(tile: int, radius: int = 1):
	var s = state
	if s == null or tile < 0:
		return null
	var w: int = s.map.W
	var tx := tile % w
	@warning_ignore("integer_division")
	var ty := tile / w
	var best = null
	var best_d := 1 << 30
	for st in s.structures():
		var dx: int = absi(int(st.tile) % w - tx)
		@warning_ignore("integer_division")
		var dy: int = absi(int(st.tile) / w - ty)
		var d: int = maxi(dx, dy)
		if d <= radius and (d < best_d or (d == best_d and best != null and st.sid < best.sid)):
			best = st
			best_d = d
	return best
