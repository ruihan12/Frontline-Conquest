# Headless sim tick profiler: World, 400 tribes. godot --headless -s tests/perf_sim.gd -- [--ticks=N] [--seed=S]
# Times the game's own tick: atk = begin + attack pass, ai = AI pass, rest = naval, economy, arsenal, missiles,
# requests, warships, trains, trade ships, transports.
extends SceneTree
func _initialize(): _run()
func _run():
	var ticks := 3000; var seed := 12345
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--ticks="): ticks = int(a.substr(8))
		if a.begins_with("--seed="): seed = int(a.substr(7))
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	m.rng.seed = seed; seed(seed)
	var t0 := Time.get_ticks_usec()
	hs.start(0, 0, Vector2(0.5, 0.38), 0, -1.0)
	print("start ms=%.0f W=%d H=%d nations=%d" % [(Time.get_ticks_usec() - t0) / 1000.0, m.W, m.H, m.nations.size()])
	m.peace = 0.0
	if "--navfree" in OS.get_cmdline_user_args() and m.sim_nav != null: m.sim_nav.budget_n = 1000000000
	# the game's own tick (game/audio.gd _sim_tick_begin / _sim_tick_end; main.gd slices the two passes)
	var keys := ["atk", "ai", "rest"]
	var acc := {}; for k in keys: acc[k] = 0
	var worst := {}; for k in keys: worst[k] = 0
	var tot_worst := 0
	var grand := 0
	var slice_max := 0
	var blk := 600
	for i in ticks:
		var ts := []
		ts.append(Time.get_ticks_usec()); m._sim_tick_begin(); m.sim_atk.run_slice(-1)
		ts.append(Time.get_ticks_usec())
		m._ai_place_budget = 24; m.sim_ai.begin_tick()
		if "--sliced" in OS.get_cmdline_user_args():
			while true:
				var q0 := Time.get_ticks_usec()
				var dn: bool = m.sim_ai.run_slice(q0 + (2500 if "--real" in OS.get_cmdline_user_args() else 50))
				slice_max = maxi(slice_max, Time.get_ticks_usec() - q0)
				if dn: break
		else:
			m.sim_ai.run_slice(0)
		ts.append(Time.get_ticks_usec()); m._sim_tick_end()
		ts.append(Time.get_ticks_usec())
		for k in keys.size():
			var d: int = ts[k + 1] - ts[k]
			acc[keys[k]] += d; worst[keys[k]] = maxi(worst[keys[k]], d)
		tot_worst = maxi(tot_worst, ts[-1] - ts[0])
		grand += ts[-1] - ts[0]
		if (i + 1) % blk == 0:
			var s := "t=%dmin ms/tick:" % ((i + 1) / 600)
			var tot := 0.0
			for k in keys: s += " %s=%.2f(max %.1f)" % [k, acc[k] / 1000.0 / blk, worst[k] / 1000.0]; tot += acc[k] / 1000.0 / blk
			var alive := 0
			for id in range(1, m.nations.size()): if m.nations[id].alive and m.nations[id].land > 0: alive += 1
			print(s, " TOTAL=%.2f worst_tick=%.1f attacks=%d alive=%d boats=%d" % [tot, tot_worst / 1000.0, m.attacks.size(), alive, m.boats.size()])
			for k in keys: acc[k] = 0; worst[k] = 0
			var hsum := hash(m.owner_map)
			var tr := 0.0
			for id in range(1, m.nations.size()): tr += float(m.nations[id].troops) * (id % 13 + 1) + float(m.nations[id].gold) * 0.001
			print("   HASH t=", i + 1, " owner=", hsum, " troops=", tr)
			tot_worst = 0
	print("AVG ms/tick over %d ticks: %.2f" % [ticks, grand / 1000.0 / maxi(ticks, 1)])
	print("AI_SLICE_MAX_MS ", slice_max / 1000.0)
	quit()
