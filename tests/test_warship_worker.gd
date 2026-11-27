extends SceneTree

const WarshipWorker = preload("res://sim/warship_worker.gd")

func _initialize() -> void:
	call_deferred("_run")

func _fixture():
	var game = load("res://main.tscn").instantiate()
	game.state = "play"
	game.W = 24
	game.H = 10
	game.owner_map.resize(game.W * game.H)
	game.owner_map.fill(game.WATER)
	game.sim_atk = SimAttacks.new(game, game.sim_rules)
	game.sim_atk.tick = 64
	game.sim_naval = SimNaval.new(game, game.sim_rules)
	game.sim_ws = SimWarships.new(game, game.sim_rules)
	game.nations = [
		{},
		{"name": "Player", "alive": true},
		{"name": "East", "alive": true, "prot": true, "skill": 1},
		{"name": "West", "alive": true, "prot": true, "skill": 1}]
	var port := {"o": 2, "tile": 51, "k": 1, "bt": 0.0, "level": 1}
	game.owner_map[port.tile] = 2
	game.structs = [port]
	game.struct_at = {port.tile: port}
	game.sim_naval.compute_bodies()
	game.sim_nav = SimNav.new()
	game.sim_nav.build(game.sim_naval.body, game.W, game.H)
	game.sim_nav.budget_us = 1000000000
	game.sim_nav._spent_us = 37
	var attacker := {"o": 2, "pos": Vector2(5.5, 3.5), "tgt": Vector2(3.5, 1.5)}
	var victim := {"o": 3, "pos": Vector2(8.5, 3.5), "tgt": Vector2(13.5, 3.5)}
	game.sim_ws.init_ship(attacker)
	game.sim_ws.init_ship(victim)
	attacker.port = port
	victim.hp = 600.0
	game.warships = [attacker, victim]
	var transport := {"a": 1, "uid": 6, "d": 0.0,
		"pts": PackedVector2Array([Vector2(16, 14), Vector2(30, 14)]), "cum": PackedFloat32Array([0, 14])}
	game.boats = [transport]
	game.sim_ws.tref[victim.uid] = {"kind": "ws", "ref": attacker}
	game.sim_ws.shells = [
		{"shooter": victim, "o": 3, "target": {"kind": "ws", "ref": attacker}, "dmg": 180, "t1": 64},
		{"shooter": attacker, "o": 2, "target": {"kind": "boat", "ref": transport}, "dmg": 200, "t1": 64},
	]
	game.rng.seed = 1627
	return game

func _check_full_pass() -> bool:
	var game = _fixture()
	var reference = _fixture()
	var worker := WarshipWorker.new()
	var attacker: Dictionary = game.warships[0]
	var port: Dictionary = game.structs[0]
	var source_rng: int = game.rng.state
	var started := worker.submit(game)
	worker.wait()
	var isolated: bool = game.rng.state == source_rng and game.boats.size() == 1 and game.sim_ws.shells.size() == 2
	game._begin_presentation_batch()
	reference._begin_presentation_batch()
	reference.sim_ws.tick()
	var applied := started and worker.take(game)
	var matching: bool = game.rng.state == reference.rng.state and game.warships == reference.warships \
		and game.boats == reference.boats and game.sim_ws.stats == reference.sim_ws.stats \
		and game.sim_ws.shells == reference.sim_ws.shells and game.sim_ws.tref == reference.sim_ws.tref \
		and game._presentation_events == reference._presentation_events and game.sim_nav._spent_us >= 37
	var references_restored: bool = is_same(attacker, game.warships[0]) and is_same(port, attacker.port) \
		and SimWarships.has_ref(game.warships, game.sim_ws.tref[2].ref)
	game._flush_presentation_batch()
	reference._flush_presentation_batch()
	var valid: bool = isolated and applied and matching and references_restored and worker.applied_ticks == 1 \
		and game.boats.is_empty() and is_equal_approx(attacker.hp, 820.0)
	if not valid:
		print("full pass started=", started, " applied=", applied, " matching=", matching,
			" references=", references_restored, " hp=", attacker.hp)
	worker.stop()
	game.free()
	reference.free()
	return valid

func _check_rejections() -> bool:
	var game = _fixture()
	var worker := WarshipWorker.new()
	var started := worker.submit(game)
	game.warships[0].tgt = Vector2(12.5, 4.5)
	worker.wait()
	var stale: bool = started and not worker.take(game) and game.sim_ws.shells.size() == 2 and game.boats.size() == 1
	game._warship_worker = worker
	started = worker.submit(game)
	game._set_owner(0, 0)
	worker.wait()
	var terrain: bool = started and not worker.take(game)
	started = worker.submit(game)
	game._stop_sim_workers()
	var stopped: bool = started and not worker.ready() and game.boats.size() == 1 and game.sim_ws.shells.size() == 2
	game.free()
	if not (stale and terrain and stopped):
		print("rejections stale=", stale, " terrain=", terrain, " stopped=", stopped)
	return stale and terrain and stopped

func _check_retaliation() -> bool:
	var game = _fixture()
	var reference = _fixture()
	var random := RandomNumberGenerator.new()
	var chosen_seed := 1
	random.seed = chosen_seed
	while random.randf() >= SimAI.WARSHIP_RETALIATE_P[1]:
		chosen_seed += 1
		random.seed = chosen_seed
	for world in [game, reference]:
		world.rng.seed = chosen_seed
		world.sim_atk.tick = 65
		world.nations[2].gold = 1000000.0
		world.boats[0].a = 2
		world.sim_ws.shells[1].o = 3
		for ship: Dictionary in world.warships:
			ship.last_shot = 65
	var port: Dictionary = game.structs[0]
	var worker := WarshipWorker.new()
	var started := worker.submit(game)
	worker.wait()
	reference.sim_ws.tick()
	var applied := started and worker.take(game)
	var matched: bool = applied and game.warships.size() == 3 and game.boats.is_empty() \
		and game.nations[2].gold < 1000000.0 and game.nations[2].gold == reference.nations[2].gold \
		and game.warships == reference.warships and game.rng.state == reference.rng.state \
		and game.warships[-1].home == port.tile and game.sim_ws.next_uid == reference.sim_ws.next_uid
	if not matched:
		print("retaliation applied=", applied, " ships=", game.warships.size(), " gold=", game.nations[2].gold)
	worker.stop()
	game.free()
	reference.free()
	return matched

func _check_capture_and_audio() -> bool:
	var game = _fixture()
	var worker := WarshipWorker.new()
	var voice := AudioStreamPlayer.new()
	game.sfx_pool.append(voice)
	game.sfx_streams["warship_shot"] = [AudioStreamWAV.new()]
	var started := worker.submit(game)
	worker.wait()
	var audio_retried: bool = started and not worker.take(game) and game.boats.size() == 1
	game.sfx_pool.clear()
	voice.free()

	game.warships.resize(1)
	game.boats.clear()
	game.sim_ws.shells.clear()
	var ship: Dictionary = game.warships[0]
	var port: Dictionary = game.structs[0]
	ship.pos = Vector2(9.5, 5.5)
	var trader := {"o": 1, "d": 0.0, "pts": PackedVector2Array([Vector2(20, 11), Vector2(28, 11)]),
		"cum": PackedFloat32Array([0, 8]), "dst": {"o": 1}}
	game.traders = [trader]
	game.sim_ws.tref[ship.uid] = {"kind": "trade", "ref": trader}
	game.sim_atk.tick = 65
	var rng_before: int = game.rng.state
	started = worker.submit(game)
	worker.wait()
	var captured := started and worker.take(game)
	var rebound: bool = captured and game.traders.size() == 1 and not is_same(game.traders[0], trader) \
		and is_same(game.traders[0].dst, port) and game.traders[0].o == 2 and game.traders[0].orig == 1
	var matched: bool = rebound and game.sim_ws.stats.captures == 1 and game.sim_ws.stats.rerouted == 1 \
		and game.rng.state == rng_before and game.sim_nav._route_cache.size() > 0
	if not (audio_retried and matched):
		print("capture/audio audio_retried=", audio_retried, " captured=", captured, " rebound=", rebound, " matched=", matched)
	worker.stop()
	game.free()
	return audio_retried and matched

func _run() -> void:
	var phase := _check_full_pass()
	var rejection := _check_rejections()
	var capture := _check_capture_and_audio()
	var retaliation := _check_retaliation()
	var passed := phase and rejection and capture and retaliation
	print("WARSHIP_WORKER ", "PASS" if passed else "FAIL")
	quit(0 if passed else 1)
