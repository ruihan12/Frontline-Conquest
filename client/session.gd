# The client's Session: upstream's Session surface (src/client/Session.luau as the UI uses it) over
# main.gd. Solo only: an intent is applied to the local simulation at once.
class_name RWSession
extends RefCounted

const MP_TIME_LIMIT_S := 2400.0

var g  # main.gd
var lobby := {}
## The last match's Stars: {total, balance, lines} (GameOver shows it).
var last_award = null
## 0 Relaxed, 1 Standard, 2 Brutal
var difficulty: int:
	get:
		return int(g.diff_i)
## UICtx.MODE_*
var mode: int:
	get:
		return UICtx.MODE_TITLE if g.state == "menu" else UICtx.MODE_SOLO


func _init(main) -> void:
	g = main


## Orders warship `uid` to `tile`; "" when the order was taken, else why not.
func move_warship(uid: int, tile: int) -> String:
	for ws in g.warships:
		if int(ws.get("uid", 0)) == uid:
			if int(ws.o) != int(g.PLAYER):
				return "Not your warship"
			return g.order_warship(ws, tile)
	return "That warship is gone"


func send_intent(intent: Dictionary) -> void:
	var me: int = g.PLAYER
	match String(intent.get("type", "")):
		"spawn":
			g._place_start(int(intent.get("tile", -1)))
		"move_warship":
			move_warship(int(intent.get("uid", 0)), int(intent.get("tile", -1)))
		"attack":
			g.intent_attack(me, int(intent.get("tile", -1)), float(intent.get("ratio", 0.25)))
		"boat":
			g.launch_boat(me, int(intent.get("tile", -1)), float(intent.get("ratio", 0.25)))
		"build", "nuke":
			var k: int = RWGameState.BUILD_ID.get(String(intent.get("kind", "")), -1)
			if k >= 0:
				for _i in maxi(1, int(intent.get("amount", 1))):
					if not g.try_build(k, int(intent.get("tile", -1))):
						break
		"reinforce":
			g.try_build(13, -1)
		"retreat":
			var a = intent.get("attack")
			if a == null and intent.has("attack_id"):
				for at in g.attacks:
					if int(at.get("aid", -1)) == int(intent.attack_id):
						a = at
			if a != null:
				g.retreat(a.get("raw", a))
		"ally_request":
			g.propose_alliance(me, int(intent.get("target", 0)))
		"ally_break":
			var other_b := int(intent.get("target", 0))
			if g.allied(me, other_b):
				g.break_alliance(me, other_b)
		"donate":
			var to := int(intent.get("target", 0))
			var mine_t: float = float(g.nations[me].troops)
			if g.allied(me, to) and mine_t > 0:
				g.donate(me, to, clampf(float(intent.get("troops", 0.0)) / mine_t, 0.0, 1.0))
		"donate_gold":
			var to_g := int(intent.get("target", 0))
			if g.allied(me, to_g):
				g.donate_gold(me, to_g, 0.25)
		"ally_reply":
			var who := int(intent.get("target", 0))
			if not g.ally_reply(me, who, bool(intent.get("accept", false))) and bool(intent.get("accept", false)):
				g.notify("That alliance request has expired", "info")
		"ally_extend":
			var other := int(intent.get("target", 0))
			if g.allied(me, other):
				var r: String = g.extend_alliance(me, other)
				if r == "asked":
					g.ally_extensions.append([g.sim_atk.tick + (1 if g.kind_of(other) == SimRules.KIND_TRIBE else g.rng.randi_range(20, 45)), me, other])
					g.notify("Asked %s to renew the alliance" % g._nname(other), "info")
				elif r == "":
					g.notify("The alliance can't be renewed now", "info")
		_:
			pass


## Unlock Arsenal item `key` with Stars; true when it was taken (the Shop's own rule).
func buy_unlock(key: String) -> bool:
	var it = ArsenalData.item(key)
	if it == null:
		return false
	return bool(g.unlock_arsenal_item(it.local_id))


## Solo only: there is no server to ask, so the account calls say "unavailable".
func multiplayer_available() -> bool:
	return false


## "connected", "connecting" or "offline" (the title card's multiplayer line).
func multiplayer_status() -> String:
	return "offline"


func join_multiplayer() -> void:
	g.notify("Multiplayer is unavailable right now. Try again in a moment.", "warn")


func join_lobby(_id: String) -> void:
	join_multiplayer()


func join_public(_mode: String) -> void:
	join_multiplayer()


func spectate_lobby(_id: String) -> void:
	join_multiplayer()


func leave_line() -> void:
	pass


func vote_start() -> void:
	pass


func party_action(_action: String, _user_id := 0) -> void:
	pass


## (in a party?, leader?)
func in_party() -> Array:
	return [false, false]


## Analytics and the account's credit and crate calls need a server: false.
func report(_kind: String, _a = null, _b = null, _c = null) -> bool:
	return false


func use_credit(_kind: String, _target := 0) -> bool:
	return false


## A crate costs Stars here (upstream: Robux). Takes the Stars, rolls an item the player doesn't own and
## keeps it (its id is in last_crate_item). False when the Stars fall short or everything is owned.
var last_crate_item := ""
var _crate_rng := RandomNumberGenerator.new()


func cosmetics() -> Dictionary:
	return g.save.cosmetics


func crate_cost() -> int:
	return CosmeticsRules.CRATE_COST


func crate_owned() -> Dictionary:
	return g.save.cosmetics.owned


func open_crate() -> bool:
	var co: Dictionary = g.save.cosmetics
	if int(g.save.stars) < CosmeticsRules.CRATE_COST:
		return false
	_crate_rng.randomize()
	var id := CosmeticsRules.roll(co.owned, _crate_rng.randf(), _crate_rng.randf())
	if id == "":
		return false
	g.save.stars = int(g.save.stars) - CosmeticsRules.CRATE_COST
	co.owned[id] = true
	co.opened = int(co.opened) + 1
	co.last = id
	last_crate_item = id
	g.write_save()
	return true


## Open up to n crates in a row (stops when the Stars or the items run out). The item ids, in order.
func open_crates(n: int) -> Array:
	var out: Array = []
	for _i in n:
		if not open_crate():
			break
		out.append(last_crate_item)
	return out


## Put an owned item on ("skin" or "flag"); "" takes it off. True when done.
func equip(slot: String, id) -> bool:
	var co: Dictionary = g.save.cosmetics
	var sid := str(id) if id != null else ""
	if slot != "skin" and slot != "flag":
		return false
	if sid != "":
		var it = CosmeticsRules.item(sid)
		if it == null or it.kind != slot or not co.owned.has(sid):
			return false
	co[slot] = sid
	g.write_save()
	if slot == "skin" and g.surface != null:
		# only the player's territory changes with a skin: repaint it over a few frames (the terrain
		# recolour of the whole map froze the game for about 4 s)
		g.surface._pal.clear()
		g.surface._sweep(int(g.PLAYER), true)
	return true


func starter_seen() -> bool:
	return false


func new_player() -> bool:
	return false


func hop_solo(_difficulty: int, _map_id = null) -> bool:
	return false


## The player touched the controls (only multiplayer listens).
func note_activity() -> void:
	pass


func is_building() -> bool:
	return bool(g.get("_map_building")) if g.get("_map_building") != null else false


## A fallen player may take over a living nation (the game has no take-over rule yet: never).
func can_take_over(_target: int) -> bool:
	return false


func take_over(_target: int) -> bool:
	return false


## Back to the title.
func leave_match() -> void:
	g._to_menu()


func local_sim():
	return g.sim_atk


func has_unlock(key: String) -> bool:
	var it = ArsenalData.item(key)
	if it == null:
		return true
	return bool(g.unlocked(it.local_id))


## Stars the item costs in this port's Arsenal (0: free or unknown).
func unlock_cost(key: String) -> int:
	var it = ArsenalData.item(key)
	if it == null:
		return 0
	for a in g.ARSENAL:
		if a.id == it.local_id:
			return int(a.cost)
	return 0


func set_paused(on: bool) -> void:
	g.sim_paused = on


func local_display_name() -> String:
	return "Commander"


func load_settings(section: String):
	var cf := ConfigFile.new()
	if cf.load("user://rw_client.cfg") != OK or not cf.has_section(section):
		return {}
	var out := {}
	for k in cf.get_section_keys(section):
		out[k] = cf.get_value(section, k)
	return out


func save_settings(section: String, values: Dictionary) -> void:
	var cf := ConfigFile.new()
	cf.load("user://rw_client.cfg")
	for k in values:
		cf.set_value(section, k, values[k])
	cf.save("user://rw_client.cfg")
