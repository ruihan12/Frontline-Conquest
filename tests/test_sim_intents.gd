extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var game = load("res://main.tscn").instantiate()
	game.sim_intents = game.SimIntentQueue.new()
	game.state = "play"
	var session := RWSession.new(game)
	var attack := {"aid": 41}
	session.send_intent({"type": "retreat", "attack": attack})
	attack.aid = 42
	session.send_intent({"type": "attack", "tile": 10, "ratio": 0.25})
	var commands: Array = game.sim_intents.take()
	var ordered: bool = commands == [
		{"type": "retreat", "attack_id": 41},
		{"type": "attack", "tile": 10, "ratio": 0.25},
	]
	var empty: bool = game.sim_intents.take().is_empty()
	game.sim_atk = SimAttacks.new(game, SimRules.new())
	var live_attack := {"aid": 41, "t": 0, "retreat_at": 0}
	game.attacks.append(live_attack)
	session.send_intent({"type": "retreat", "attack_id": 41})
	var waited: bool = live_attack.retreat_at == 0
	game._drain_sim_intents()
	var drained: bool = live_attack.retreat_at > 0
	var warship_orders := _check_warship_orders(game, session)
	game.sim_atk = null
	game.free()
	var passed := ordered and empty and waited and drained and warship_orders
	print("SIM_INTENTS ", "PASS" if passed else "FAIL")
	quit(0 if passed else 1)

func _check_warship_orders(game, session: RWSession) -> bool:
	var rules := SimRules.new()
	game.W = 4
	game.H = 1
	game.owner_map = PackedInt32Array([game.WATER, game.WATER, 0, game.WATER])
	game.sim_naval = SimNaval.new(game, rules)
	game.sim_naval.body = PackedInt32Array([1, 1, 0, 2])
	game.sim_ws = SimWarships.new(game, rules)
	var start := Vector2(0.5, 0.5)
	var ship := {"o": game.PLAYER, "pos": start, "tgt": start}
	game.sim_ws.init_ship(ship)
	game.warships = [ship]
	var landed := session.move_warship(ship.uid, 2) == "Warships can only sail on water"
	var isolated := session.move_warship(ship.uid, 3) == "That water is not reachable by this warship"
	var refused: bool = landed and isolated and game.sim_intents.take().is_empty()

	var queued: bool = session.move_warship(ship.uid, 1).is_empty() and ship.tgt == start
	game._drain_sim_intents()
	var destination := Vector2(1.5, 0.5)
	var applied: bool = ship.tgt == destination and ship.manual == game.sim_atk.tick
	var accepted := session.move_warship(ship.uid, 0).is_empty()
	ship.o = 2
	game._drain_sim_intents()
	var revalidated: bool = accepted and ship.tgt == destination and not game.notes.is_empty() and game.notes[0].text == "Not your warship"
	ship.o = game.PLAYER
	game.sim_intents = null
	var immediate: bool = session.move_warship(ship.uid, 0).is_empty() and ship.tgt == start
	game.sim_naval = null
	game.sim_ws = null
	return refused and queued and applied and revalidated and immediate
