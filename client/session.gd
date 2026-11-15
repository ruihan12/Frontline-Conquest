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


func send_intent(intent: Dictionary) -> void:
	var me: int = g.PLAYER
	match String(intent.get("type", "")):
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
