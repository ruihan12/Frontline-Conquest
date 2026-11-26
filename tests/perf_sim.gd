# Headless World tick profiler; accepts the live worker flags and --ticks=N --seed=S --navfree --worker-attacks.
extends SceneTree
const AttackWorker = preload("res://sim/attack_worker.gd")

func _worker_attack_pass(m) -> bool:
	m._rebuild_def_posts()
	if not m._attack_worker.submit(m):
		return false
	# This timing harness joins immediately so later stages keep the reference order.
	# The live scheduler instead polls on subsequent frames.
	m._attack_worker.wait()
	return m._attack_worker.take(m)

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
	var slice_max := 0
	var blk := 600
	var worker_enabled := "--worker-attacks" in OS.get_cmdline_user_args()
	var worker_ticks := 0
	var economy_worker: EconomyWorker = m._economy_worker
	var economy_rows := 0
	var naval_job_ticks := 0
	if worker_enabled:
		m._attack_worker = AttackWorker.new()
		m._attack_worker.prepare_ai_scans = "--sim-worker-ai-scan" in OS.get_cmdline_user_args()
		m._attack_worker.prepare_batteries = "--sim-worker-arsenal" in OS.get_cmdline_user_args()
		m._attack_worker.prepare_rails = "--sim-worker-trains" in OS.get_cmdline_user_args()
		m._attack_worker.prepare_warships = "--sim-worker-warships" in OS.get_cmdline_user_args()
	for i in ticks:
		var ts := []
		ts.append(Time.get_ticks_usec())
		if worker_enabled and _worker_attack_pass(m):
			worker_ticks += 1
		else:
			m._tick_attacks()
		ts.append(Time.get_ticks_usec())
		if "--sliced" in OS.get_cmdline_user_args():
			m._ai_place_budget = 24; m.sim_ai.begin_tick()
			while true:
				var q0 := Time.get_ticks_usec()
				var dn: bool = m.sim_ai.run_slice(q0 + (2500 if "--real" in OS.get_cmdline_user_args() else 50))
				slice_max = maxi(slice_max, Time.get_ticks_usec() - q0)
				if dn: break
		else:
			m._ai(0.1)
		ts.append(Time.get_ticks_usec())
		var naval_worker: NavalWorker = m._naval_worker
		if naval_worker != null and naval_worker.submit(m, false):
			naval_worker.wait()
			if naval_worker.take(m):
				naval_job_ticks += 1
			else:
				m.sim_naval.tick()
		else:
			m.sim_naval.tick()
		ts.append(Time.get_ticks_usec()); m.ticks_done += 1
		if economy_worker != null:
			m._economy_begin()
			var job: EconomyWorker.Job = m._prepared_economy
			m._prepared_economy = null
			if job == null and not worker_enabled and economy_worker.submit(m, 0.1):
				job = economy_worker.wait()
			economy_rows += m._economy_finish(0.1, job)
		else:
			m._economy(0.1)
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
	print("AI_SLICE_MAX_MS ", slice_max / 1000.0)
	print("ATTACK_WORKER_TICKS ", worker_ticks)
	print("AI_WORKER_SCANS ", m.sim_ai.worker_scan_count, "/", m.sim_ai.scan_n)
	print("ECONOMY_WORKER_ROWS ", economy_rows)
	print("NAVAL_WORKER_TICKS ", naval_job_ticks)
	if m._naval_worker != null:
		print("NAVAL_WORKER_GRAPH_QUERIES ", m._naval_worker.graph_queries)
	if worker_enabled and m._attack_worker.prepare_batteries:
		print("ARSENAL_WORKER_TARGETS ", m.sim_ars.worker_battery_count)
	if worker_enabled and m._attack_worker.prepare_rails:
		print("RAIL_WORKER_CURVES ", m._rail_worker_curves_used)
		print("RAIL_WORKER_TRAIN_STEPS ", m._rail_worker_train_steps_used)
	if worker_enabled and m._attack_worker.prepare_warships:
		print("WARSHIP_WORKER_SHORE_CHECKS ", m.sim_ws.worker_shore_checks_used)
		print("WARSHIP_WORKER_TRANSPORT_SCANS ", m.sim_ws.worker_transport_scans_used)
	m.queue_free()
	await process_frame
	quit()
