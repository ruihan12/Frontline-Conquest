# Owner-map hash of a seeded headless match through the game's own tick (docs/LUAU_PORT.md baselines).
#   godot --headless --path . -s tests/sim_hash.gd -- [--seed=5516] [--ticks=6000] [--sliced]
# World, 400 tribes, player spawn at (0.5, 0.38). Prints HASH lines every 600 ticks and SIM_HASH at the end.
# --sliced runs both passes in tiny slices (deadline already past): the hash must not change.
extends SceneTree
func _initialize(): _run()
func _run():
	var ticks := 6000; var seed := 5516
	var sliced := "--sliced" in OS.get_cmdline_user_args()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--ticks="): ticks = int(a.substr(8))
		if a.begins_with("--seed="): seed = int(a.substr(7))
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	m.rng.seed = seed; seed(seed)
	hs.start(0, 0, Vector2(0.5, 0.38), 0, -1.0)
	m.peace = 0.0
	var t0 := Time.get_ticks_usec()
	for i in ticks:
		if sliced:
			m._sim_tick_begin()
			while not m.sim_atk.run_slice(1): pass
			m._ai_place_budget = 24; m.sim_ai.begin_tick()
			while not m.sim_ai.run_slice(1): pass
			m._sim_tick_end()
		else:
			m._sim_tick_whole()
		if (i + 1) % 600 == 0:
			print("HASH t=%d owner=%d %s" % [i + 1, hash(m.owner_map), _state(m)])
	print("SIM_HASH seed=%d ticks=%d owner=%d %s godot=%s ms=%.0f" % [seed, ticks, hash(m.owner_map), _state(m), Engine.get_version_info().string, (Time.get_ticks_usec() - t0) / 1000.0])
	quit()

func _state(m) -> String:
	var tr := 0.0; var gd := 0.0; var alive := 0
	for id in range(1, m.nations.size()):
		var n = m.nations[id]
		tr += float(n.troops) * (id % 13 + 1); gd += float(n.gold) * (id % 7 + 1)
		if n.alive and n.land > 0: alive += 1
	return "troops=%.1f gold=%.1f alive=%d structs=%d attacks=%d boats=%d traders=%d" % [tr, gd, alive, m.structs.size(), m.attacks.size(), m.boats.size(), m.traders.size()]
