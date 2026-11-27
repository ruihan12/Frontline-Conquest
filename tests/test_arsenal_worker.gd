extends SceneTree

const ArsenalWorker = preload("res://sim/arsenal_worker.gd")

func _initialize() -> void:
	call_deferred("_run")

func _fixture():
	var game = load("res://main.tscn").instantiate()
	game.W = 96
	game.H = 32
	game.state = "play"
	game.owner_map.resize(game.W * game.H)
	game.owner_map.fill(2)
	game.owner_map[0] = 0
	game.nations = [{}, {"name": "Player", "troops": 10000.0}, {"name": "Enemy", "troops": 12000.0}]
	game.sim_atk = SimAttacks.new(game, game.sim_rules)
	game.sim_atk.tick = 50
	game.sim_ars = SimArsenal.new(game, game.sim_rules)
	game.tile_snapshot = game.TileSnapshot.new()
	game.rng.seed = 51009
	for i in 16:
		game.build_data.append([null, "Structure %d" % i])
	var city := {"k": 0, "o": 1, "tile": 96 * 12 + 25, "level": 1, "bt": 0.05}
	var victim := {"k": 0, "o": 2, "tile": 96 * 12 + 35, "level": 1, "hp": 1}
	var battery := {"k": 10, "o": 1, "tile": 96 * 12 + 23, "level": 1, "next_fire": 50}
	var sam := {"k": 4, "o": 1, "tile": 96 * 12 + 20, "level": 2, "shots": [-10000]}
	for st: Dictionary in [city, victim, battery, sam]:
		game.structs.append(st)
		game.struct_at[st.tile] = st
	game.attacks = [{"a": 2, "troops": 1000.0}]
	game.boats = [{"a": 2, "troops": 300.0}]
	game.sim_ars.munitions.append({"nk": SimRules.N_AIRSTRIKE, "tile": victim.tile, "o": 1, "t1": 50})
	var missile := {"nk": SimRules.N_ATOM, "k": 5, "o": 2, "dur": 12.0, "ft": 120, "lt": 0,
		"from": Vector2(0, 0), "to": Vector2(22, 12), "sim_uid": 1, "sam_st": sam, "sam_hit": 50, "sam_k": 60}
	game.missiles.append(missile)
	game.sim_ars.sam_shots.append({"ms": missile, "t1": 50})
	var inbound := {"nk": SimRules.N_ATOM, "k": 5, "o": 2, "dur": 12.0, "ft": 120, "lt": 0,
		"from": Vector2(0, 0), "to": Vector2(22, 12), "sim_uid": 2, "cands": [sam], "cand_tick": 70,
		"plan_fire": {}, "plan_k": {}}
	game.missiles.append(inbound)
	return game

func _blast_fixture():
	var game = _fixture()
	game.sim_ars.munitions.clear()
	game.sim_ars.sam_shots.clear()
	game.attacks.clear()
	game.boats.clear()
	game.structs.clear()
	game.struct_at.clear()
	game.missiles.clear()
	game.fallout.resize(game.W * game.H)
	game.fallout_t.resize(game.W * game.H)
	game.nations.append({"name": "Neighbor", "troops": 3500.0})
	for id in [2, 3]:
		game.nations[id].merge({"land": 0, "sx": 0.0, "sy": 0.0})
	game.border = [{}, {}, {}, {}]
	for tile in range(1, game.W * game.H):
		if tile % game.W > 46:
			game.owner_map[tile] = 3
		var nation: Dictionary = game.nations[game.owner_map[tile]]
		nation.land += 1
		nation.sx += tile % game.W
		nation.sy += tile / game.W
	for tile in game.W * game.H:
		game._upd_border(tile)
	var building := {"k": 0, "o": 2, "tile": 15 * int(game.W) + 40, "bt": 0.0}
	game.structs.append(building)
	game.struct_at[building.tile] = building
	game._publish_tile_snapshot()
	game._attack_worker = game.AttackWorker.new()
	for offset in [0, 9]:
		game.missiles.append({"nk": SimRules.N_ATOM, "k": 7, "o": 1, "dur": 1.0, "ft": 50,
			"lt": 0, "from": Vector2(2, 2), "to": Vector2(40 + offset, 15), "r": 13.0,
			"evade": true})
	return game

func _check_first_blast(change_rng: bool, change_fallout := false) -> bool:
	var game = _blast_fixture()
	var reference = _blast_fixture()
	var worker := ArsenalWorker.new()
	game._arsenal_worker = worker
	var began := worker.submit(game)
	worker.wait()
	game._begin_presentation_batch()
	reference._begin_presentation_batch()
	var applied := began and worker.take(game)
	reference.sim_ars.tick()
	var isolated: bool = game.rng.state == reference.rng.state and game.fallout_list.is_empty()
	if change_rng:
		game.rng.randi()
		reference.rng.randi()
	if change_fallout:
		game.fallout[0] = 1
		reference.fallout[0] = 1
		game._record_tile_snapshot(0)
		reference._record_tile_snapshot(0)
	game._tick_missiles()
	reference._tick_missiles()
	var matches: bool = game.rng.state == reference.rng.state and game.missiles.is_empty() \
		and game.fallout_list.size() > 0 and game.fallout_list == reference.fallout_list \
		and game.owner_map == reference.owner_map and game.nations == reference.nations \
		and game._presentation_events == reference._presentation_events
	var used_expected := worker.prepared_blasts_used == (0 if change_rng else 1) \
		and worker.prepared_territory_used == (0 if change_rng or change_fallout else 1)
	game._flush_presentation_batch()
	reference._flush_presentation_batch()
	game._publish_tile_snapshot()
	reference._publish_tile_snapshot()
	var map_matches: bool = game.border[2].keys() == reference.border[2].keys() \
		and game.border[3].keys() == reference.border[3].keys() and game._rp_list == reference._rp_list \
		and game._render_owners() == reference._render_owners() and game._render_fallout() == reference._render_fallout() \
		and game._attack_map_revision == reference._attack_map_revision \
		and game.structs == reference.structs and game._sv == reference._sv
	game.free()
	reference.free()
	return applied and isolated and matches and used_expected and map_matches

func _run() -> void:
	var game = _fixture()
	var reference = _fixture()
	var worker := ArsenalWorker.new()
	game._arsenal_worker = worker
	var city: Dictionary = game.structs[0]
	var victim: Dictionary = game.structs[1]
	var sam: Dictionary = game.structs[3]
	var missile: Dictionary = game.missiles[0]
	var inbound: Dictionary = game.missiles[1]
	var before: int = game.rng.state
	var held: bool = not game._advance_arsenal_phase() and game._tick_stage == game.ARSENAL_PHASE_PENDING
	worker.wait()
	var isolated: bool = game.rng.state == before and city.bt == 0.05 and victim.hp == 1 \
		and game.missiles.size() == 2 and inbound.plan_fire.is_empty() and game._intercepted_missiles.is_empty()
	reference._begin_presentation_batch()
	reference.sim_ars.tick()
	game._begin_presentation_batch()
	var applied: bool = game._advance_arsenal_phase() and game._tick_stage == 0 and worker.applied_ticks == 1
	var parity: bool = game.structs == reference.structs and game.struct_at == reference.struct_at \
		and game.missiles == reference.missiles and game.nations == reference.nations \
		and game.attacks == reference.attacks and game.boats == reference.boats and game.rng.state == reference.rng.state \
		and game._sv == reference._sv and game._own_sv == reference._own_sv \
		and game.sim_ars.munitions == reference.sim_ars.munitions and game.sim_ars.sam_shots == reference.sim_ars.sam_shots \
		and game.sim_ars.stats == reference.sim_ars.stats and game._presentation_events == reference._presentation_events
	var correct: bool = game.sim_ars.stats.shells == 1 and game.sim_ars.stats.sam_hits == 1 \
		and game._intercepted_missiles == {1: true} and not game.struct_at.has(victim.tile) \
		and game.nations[2].troops < 12000.0 and game.attacks[0].troops < 1000.0 and game.boats[0].troops < 300.0 \
		and is_same(game.structs[0], city) and is_same(game.sim_ars.sam_shots[0].ms, missile) and missile.shot_down \
		and is_same(game.missiles[0], inbound) and inbound.plan_fire.has(sam.tile) and is_same(inbound.cands[0], sam)
	game._flush_presentation_batch()
	reference._flush_presentation_batch()

	var pending := worker.submit(game)
	game._set_owner(0, game.WATER)
	worker.wait()
	var map_stale := pending and not worker.take(game)
	pending = worker.submit(game)
	game.missiles[0].cand_tick += 5
	worker.wait()
	var record_stale := pending and not worker.take(game) and worker.inline_retries == 2
	pending = worker.submit(game)
	game._stop_sim_workers()
	var stopped := pending and not worker.ready()
	game.free()
	reference.free()
	var first_blast := _check_first_blast(false) and _check_first_blast(true) and _check_first_blast(false, true)
	var passed := held and isolated and applied and parity and correct and map_stale and record_stale and stopped and first_blast
	if not passed:
		print("arsenal held=", held, " isolated=", isolated, " applied=", applied, " parity=", parity,
			" correct=", correct, " map_stale=", map_stale, " record_stale=", record_stale, " stopped=", stopped, " first_blast=", first_blast)
	print("ARSENAL_WORKER ", "PASS" if passed else "FAIL")
	quit(0 if passed else 1)
