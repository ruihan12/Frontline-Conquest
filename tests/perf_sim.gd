# Headless sim tick profiler: World, 400 tribes. godot --headless -s tests/perf_sim.gd -- [--ticks=N] [--seed=S]
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
	if "--navfree" in OS.get_cmdline_user_args() and m.sim_nav != null: m.sim_nav.budget_us = 1000000000
	var keys := ["atk", "ai", "naval", "eco", "ars", "ws", "trains", "req", "missiles", "boats"]
	var acc := {}; for k in keys: acc[k] = 0
	var worst := {}; for k in keys: worst[k] = 0
	var tot_worst := 0
	var blk := 600
	for i in ticks:
		var ts := []
		ts.append(Time.get_ticks_usec()); m._tick_attacks()
		ts.append(Time.get_ticks_usec()); m._ai(0.1)
		ts.append(Time.get_ticks_usec()); m.sim_naval.tick()
		ts.append(Time.get_ticks_usec()); m.ticks_done += 1; m._economy(0.1)
		ts.append(Time.get_ticks_usec()); m.sim_ars.tick()
		ts.append(Time.get_ticks_usec()); m.sim_ws.tick()
		ts.append(Time.get_ticks_usec()); m._trains_tick()
		ts.append(Time.get_ticks_usec()); m._requests_tick()
		ts.append(Time.get_ticks_usec()); m._tick_missiles(SimArsenal.DT_TICK)
		ts.append(Time.get_ticks_usec()); m._tick_boats(0.1)
		ts.append(Time.get_ticks_usec())
		for k in keys.size():
			var d: int = ts[k + 1] - ts[k]
			acc[keys[k]] += d; worst[keys[k]] = maxi(worst[keys[k]], d)
		tot_worst = maxi(tot_worst, ts[-1] - ts[0])
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
	quit()
