# Every intent a player can send, applied to the sim as nation `me` (solo: PLAYER; a server: the
# sender's nation). RWSession.send_intent is the solo entry point and calls this with PLAYER.
class_name NetIntents
extends RefCounted


static func apply(g, me: int, intent: Dictionary) -> void:
	match String(intent.get("type", "")):
		"spawn":
			g._place_start(int(intent.get("tile", -1)), me)
		"move_warship":
			move_warship(g, me, int(intent.get("uid", 0)), int(intent.get("tile", -1)))
		"attack":
			g.intent_attack(me, int(intent.get("tile", -1)), float(intent.get("ratio", 0.25)))
		"boat":
			g.launch_boat(me, int(intent.get("tile", -1)), float(intent.get("ratio", 0.25)))
		"build", "nuke":
			var k: int = RWGameState.BUILD_ID.get(String(intent.get("kind", "")), -1)
			if k >= 0:
				for _i in maxi(1, int(intent.get("amount", 1))):
					if not g.try_build(k, int(intent.get("tile", -1)), me):
						break
		"reinforce":
			g.try_build(13, -1, me)
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


static func move_warship(g, me: int, uid: int, tile: int) -> String:
	for ws in g.warships:
		if int(ws.get("uid", 0)) == uid:
			if int(ws.o) != me:
				return "Not your warship"
			return g.order_warship(ws, tile)
	return "That warship is gone"
