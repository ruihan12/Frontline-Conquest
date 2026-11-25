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
	game.sim_atk = null
	game.free()
	var passed := ordered and empty and waited and drained
	print("SIM_INTENTS ", "PASS" if passed else "FAIL")
	quit(0 if passed else 1)
