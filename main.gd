extends "res://game/audio.gd"
# Game loop, overlay drawing, input and capture tools

func _pf_add(k: String, v: float) -> void: _pf[k] = _pf.get(k, 0.0) + v
func _pf_line() -> String:
	var f: float = maxf(1.0, _pf.get("frames", 0.0))
	var out := "frames=%d ms/frame:" % int(f)
	for k in ["process", "sim", "atk", "ai", "eco", "missiles", "fx", "boats", "paint", "draw", "wfx", "w_cap", "w_meta", "w_rail", "hud", "nv_bfs"]:
		out += " %s=%.1f" % [k, _pf.get(k, 0.0) / f / 1000.0]
	out += " state=%s paused=%s tick=%d pland=%d" % [state, str(sim_paused), sim_atk.tick if sim_atk else -1, nations[PLAYER].land if nations.size() > PLAYER else -1]
	if _attack_worker != null:
		out += " attack_worker_passes=%d" % _attack_worker_applied
		if _attack_worker.prepare_ai_scans and sim_ai != null:
			out += " ai_worker_scans=%d" % sim_ai.worker_scan_count
	if _naval_worker != null:
		out += " naval_worker_ticks=%d" % _naval_worker_ticks
	if _economy_worker != null:
		out += " economy_worker_rows=%d" % _economy_worker_rows
	out += " dt_avg=%.1f dt_max=%.1f fps=%d drawcalls=%d" % [_pf.get("dt", 0.0) / f * 1000.0, _pf.get("dt_max", 0.0) * 1000.0, Engine.get_frames_per_second(), int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))]
	for k2 in ["names", "names_place", "fronts", "fxl", "ranges", "fallout", "uploads", "flush_n", "labels_anim", "alliances", "dominates", "cam_paint", "tooltip", "anim_ui", "hud_proc", "client_proc", "notes", "pre", "c_world", "c_ranges", "c_advisor", "c_top", "c_hover", "c_feed", "c_bar_s", "c_nukes", "c_alert", "c_bar", "c_board", "c_attacks"]:
		if _pf.has(k2): out += " %s=%.2f" % [k2, _pf[k2] / f / (1.0 if k2 in ["uploads", "flush_n"] else 1000.0)]
	out += " ticks/frame=%.2f tiles/tick=%.0f atk_per_tick=%.0f set_owner_ms/tick=%.1f naval=%.1f" % [_pf.get("ticks", 0.0) / f, _pf.get("tiles", 0.0) / maxf(1.0, _pf.get("ticks", 0.0)), _pf.get("atk_n", 0.0) / maxf(1.0, _pf.get("ticks", 0.0)), _pf.get("set_owner", 0.0) / maxf(1.0, _pf.get("ticks", 0.0)) / 1000.0, _pf.get("naval", 0.0) / f / 1000.0]
	_pf = {}
	return out
# Multiplayer from the command line (see net/mp_node.gd): a dedicated server or a viewer that connects to one.
func _net_boot() -> void:
	var args := OS.get_cmdline_user_args()
	var opt := {}
	for a in args:
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		opt[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var node = preload("res://net/mp_node.gd").new()
	node.name = "MPNode"
	add_child(node)
	node.netlog = opt.has("netlog")
	node.autospawn = opt.has("autospawn")
	node.token = str(opt.get("token", ""))
	if opt.has("hostlocal"):
		node.free()
		var hn := net_host_local(int(opt.get("port", 8070)), int(opt.get("bots", 40)), int(opt.get("max", 8)))
		if hn != null:
			hn.netlog = opt.has("netlog")
			if opt.has("teams"):
				hn.host.team_game = true
				hn.host.team_expected = int(opt.teams)
		print("MPHOSTLOCAL ", "ok" if hn != null else "failed")
	elif opt.has("server"):
		Engine.max_fps = 30  # a dedicated server needs little more than the tick rate (10/s)
		var port := int(OS.get_environment("FRONTLINE_PORT")) if OS.has_environment("FRONTLINE_PORT") else int(opt.get("port", 8070))
		var bots := int(OS.get_environment("FRONTLINE_DEFAULT_BOTS")) if OS.has_environment("FRONTLINE_DEFAULT_BOTS") else int(opt.get("bots", 40))
		var mp := str(opt.get("map", "0:0")).split(":")
		var err: int = node.start_server(self, port, bots, int(mp[0]), int(mp[1]) if mp.size() > 1 else 0, int(opt.get("max", 8)), opt.has("enet"))
		print("MPSERVER ", node.status, " err=", err)
	elif opt.has("connect"):
		var err2: int = node.start_client(self, str(opt.connect), str(opt.get("name", "Player")), opt.has("enet"))
		print("MPCLIENT ", node.status, " err=", err2)

## Joins an online match (a dedicated server or a player's host). Returns the connection node, or null when it can't start.
func net_join(url: String, pname: String, token := "", use_enet := false, party := "", mode := "") -> Node:
	var old := get_node_or_null("MPNode")
	if old != null: old.free()
	var node = preload("res://net/mp_node.gd").new()
	node.name = "MPNode"
	add_child(node)
	node.token = token
	node.party = party
	node.requested_mode = mode
	if node.start_client(self, url, pname, use_enet) != OK:
		node.queue_free()
		return null
	return node

## Hosts a casual match on this PC (ENet, desktop only); this player is nation 1. Returns the node or null.
func net_host_local(port := 8070, bots := 40, max_humans := 8) -> Node:
	if OS.has_feature("web"): return null
	var old := get_node_or_null("MPNode")
	if old != null: old.free()
	var node = preload("res://net/mp_node.gd").new()
	node.name = "MPNode"
	add_child(node)
	if node.start_local_host(self, port, bots, max_humans) != OK:
		node.queue_free()
		return null
	return node

func _process(dt: float) -> void:
	_rail_bfs_left = 40
	_rail_calc_left = 40
	_rail_frame += 1
	var _t0 := Time.get_ticks_usec()
	map_t += dt
	if map_mat: map_mat.set_shader_parameter("t_anim", fmod(map_t, 1000.0))
	_process_inner(dt)
	_audio_diag_tick(dt)
	_fp["process"] = Time.get_ticks_usec() - _t0
	_pf_add("frames", 1.0); _pf_add("process", _fp.process); _pf_add("dt", dt); _pf["dt_max"] = maxf(_pf.get("dt_max", 0.0), dt)
	if _sfx_log and _fp.process > 60000: print("SLOW process ", _fp)
	if _webprof_on:
		_webprof_acc += dt
		if _webprof_acc >= 2.0:
			_webprof_acc = 0.0
			var line := _pf_line()
			print("FRAMESTATS ", line)
			if OS.has_feature("web"):
				JavaScriptBridge.eval("window._fcStats = %s" % JSON.stringify({"line": line, "fps": Engine.get_frames_per_second()}), true)
	for kz in ["ai_prot", "ai_boat", "ai_mop", "ai_inv"]: _fp[kz] = 0
	if bench: _bench_step(dt, Time.get_ticks_usec() - _t0)

func _bench_step(dt: float, us: int) -> void:
	if bench_i == -1:
		_start_game()
		var st := _find_spawn_tile(W / 2, H / 2)
		_place_start(st); deploy_t = 0.0
		bench_i = 0; bench_t = -2.0
		return
	if state == "play": peace = 1e9
	bench_t += dt
	if bench_t < 0: return
	if bench_t > 0.0 and bench_frames == 0: bench_ticks0 = ticks_done
	bench_frames += 1; bench_us += us; bench_max = maxi(bench_max, us)
	if bench_t >= 6.0:
		var tk := ticks_done - bench_ticks0
		print("BENCH fps=%.0f speed=%dx frames=%d avg_ms=%.2f max_ms=%.2f sim_ticks_per_s=%.1f (target %.0f) land_player=%d attacks=%d boats=%d" % [bench_frames / bench_t, int(SPEEDS[bench_i]), bench_frames, bench_us / 1000.0 / bench_frames, bench_max / 1000.0, tk / bench_t, 10.0 * SPEEDS[bench_i], nations[PLAYER].land, attacks.size(), boats.size()])
		print("   prof ms: attacks=%.0f economy=%.0f boats=%.0f ai=%.0f ai_max=%.1f naval=%.0f traders=%d" % [prof.atk / 1000.0, prof.eco / 1000.0, prof.boat / 1000.0, prof.ai / 1000.0, prof.ai_max / 1000.0, prof.get("naval", 0) / 1000.0, traders.size()])
		for k in prof: prof[k] = 0
		bench_i += 1
		if bench_i >= SPEEDS.size():
			get_tree().quit(); return
		set_speed(bench_i)
		bench_t = 0.0; bench_frames = 0; bench_us = 0; bench_max = 0

func _pace_step() -> void:
	# headless pacing test: --pace=<map_i>,<runs>[,growth,atk,gold,airate]
	if _pace.has("init"):
		var a := ""
		for x in OS.get_cmdline_user_args():
			if x.begins_with("--pace="): a = x.substr(7)
		var p := a.split(",")
		_pace = {"map": int(p[0]), "runs": int(p[1]), "run": 0, "started": false}
		if p.size() >= 6:
			sim_rules.growth_mult = float(p[2]); sim_rules.attack_speed_mult = float(p[3])
			sim_rules.gold_mult = float(p[4]); sim_rules.ai_rate_mult = float(p[5])
	if not _pace.started:
		map_tab = 0; map_i = _pace.map
		_start_game()
		_place_start(_find_spawn_tile(W / 2, H / 3)); deploy_t = 0.0
		state = "play"; peace = 1e9
		_pace.started = true
		return
	for k in 300:
		var t0 := Time.get_ticks_usec()
		_tick_attacks()
		var t1 := Time.get_ticks_usec()
		_ai(0.1)
		var t2 := Time.get_ticks_usec()
		sim_naval.tick()
		var t3 := Time.get_ticks_usec()
		_economy(0.1); ticks_done += 1
		sim_ars.tick(); sim_ws.tick(); _trains_tick(); _requests_tick(); _tick_missiles(SimArsenal.DT_TICK)
		var t4 := Time.get_ticks_usec()
		_tick_boats(0.1); _tick_trade(0.1)
		var t5 := Time.get_ticks_usec()
		for kk in ["atk", "ai", "nav", "eco", "units"]: if not _pace.has(kk): _pace[kk] = 0
		_pace.atk += t1 - t0; _pace.ai += t2 - t1; _pace.nav += t3 - t2; _pace.eco += t4 - t3; _pace.units += t5 - t4
		if _sfx_log and sim_atk.tick >= 1800: print("SFXLOG done 3min"); get_tree().quit(); return
		if OS.get_cmdline_user_args().has("--prof") and sim_atk.tick % 1200 == 0:
			print("   scan ms/tick=%.2f scans/tick=%.1f" % [sim_ai.scan_us / 1200000.0, sim_ai.scan_n / 1200.0]); sim_ai.scan_us = 0; sim_ai.scan_n = 0
			print("PROF t=%dmin ms/tick atk=%.2f ai=%.2f naval=%.2f eco=%.2f units=%.2f attacks=%d" % [sim_atk.tick / 600, _pace.atk / 1200000.0, _pace.ai / 1200000.0, _pace.nav / 1200000.0, _pace.eco / 1200000.0, _pace.units / 1200000.0, attacks.size()])
			for kk in ["atk", "ai", "nav", "eco", "units"]: _pace[kk] = 0
			if sim_atk.tick >= 6000: get_tree().quit(); return
		var win := win_threshold_tiles()
		var best := 0; var bid := 0
		for id in range(1, nations.size()):
			if nations[id].alive and nations[id].land > best: best = nations[id].land; bid = id
		if best >= win or sim_atk.tick >= 60 * 600:
			print("PACE map=%s run=%d minutes=%.1f winner=%s share=%.2f alive=%d" % [MAPS[map_i][0], _pace.run, sim_atk.tick / 600.0, nations[bid].name, float(best) / maxf(1.0, land_total), nations.filter(func(n): return n is Dictionary and n.get("alive", false) and n.get("land", 0) > 0).size()])
			_pace.run += 1; _pace.started = false
			if _pace.run >= _pace.runs: get_tree().quit()
			return
		if sim_atk.tick % 3000 == 0:
			print("  t=%dmin lead=%.2f" % [sim_atk.tick / 600, float(best) / maxf(1.0, land_total)])

func _drain_sim_intents() -> void:
	if sim_intents != null and state == "play" and net_host == null and not net_remote:
		for command in sim_intents.take():
			NetIntents.apply(self, PLAYER, command)

# These updates depend on the frame clocks. Keep their sequence and RNG draw
# timing while separating them from the fixed tick and the match-end UI.
func _advance_sim_frame(dt: float, tdt: float, advance_effects := true) -> void:
	var u0 := Time.get_ticks_usec()
	_fp["missiles"] = 0; u0 = Time.get_ticks_usec()
	_tick_trade(tdt); _fp["ships"] = Time.get_ticks_usec() - u0; u0 = Time.get_ticks_usec()
	_fp["trains"] = Time.get_ticks_usec() - u0; u0 = Time.get_ticks_usec()
	if advance_effects:
		_advance_frame_effects(dt, tdt)
	u0 = Time.get_ticks_usec()
	_tick_meta(dt, tdt); _fp["meta"] = Time.get_ticks_usec() - u0
	donate_troop_cd = maxf(0.0, donate_troop_cd - dt)
	donate_gold_cd = maxf(0.0, donate_gold_cd - dt)
	var _q1 := Time.get_ticks_usec()
	if ai_timer == 0.0 or rng.randf() < 0.2: _tick_alliances()
	_pf_add("alliances", Time.get_ticks_usec() - _q1)
	var b0 := Time.get_ticks_usec()
	_tick_boats(tdt)
	prof.boat += Time.get_ticks_usec() - b0
	_pf_add("boats", Time.get_ticks_usec() - b0)
	ai_timer += dt

func _advance_frame_effects(dt: float, tdt: float) -> void:
	var start := Time.get_ticks_usec()
	_tick_fx(dt, tdt)
	_fp["fx"] = Time.get_ticks_usec() - start
	_pf_add("fx", _fp.fx)

func _advance_or_hold_sim_frame(dt: float, tdt: float) -> bool:
	if _tick_stage >= 3:
		_advance_frame_effects(dt, tdt)
		_held_sim_frames.append(dt)
		_held_sim_frames.append(tdt)
		return false
	# Movement, arrival checks and RNG draws run once per original frame.
	for i in range(0, _held_sim_frames.size(), 2):
		_advance_sim_frame(_held_sim_frames[i], _held_sim_frames[i + 1], false)
	_held_sim_frames.clear()
	_advance_sim_frame(dt, tdt)
	return true

# A frame can end mid-attack or mid-AI pass. The next call resumes the same tick
# before taking another intent or running any of the remaining subsystems.
func _advance_fixed_ticks(tdt: float) -> void:
	tick_acc += tdt
	tick_acc = minf(tick_acc, 0.1 * MAX_TICKS_PER_FRAME)
	var nt := 0
	var loop_t0 := Time.get_ticks_usec()
	var sim_budget := _sim_frame_budget_us()
	# frame budget: the sim gets a slice of the frame; a long attacks pass is time-sliced over frames
	# (upstream runs a local step as a Coop job spread over frames), so the window never stalls and the
	# sim simply runs slower than the chosen speed when it can't keep up
	_begin_presentation_batch()
	while (tick_acc >= 0.1 or _tick_stage > 0) and nt < MAX_TICKS_PER_FRAME:
		if Time.get_ticks_usec() - loop_t0 > sim_budget: break
		if _tick_stage == 0:
			tick_acc -= 0.1
			nt += 1
			_drain_sim_intents()
			_rebuild_def_posts()
			if _attack_worker != null and state == "play" and net_host == null and not net_remote \
					and _attack_worker.submit(self):
				_tick_stage = 3
				break
			sim_atk.begin_tick()
			_tick_stage = 1
		var a0 := Time.get_ticks_usec()
		if _tick_stage != 4:
			if _tick_stage != 5 and not _advance_attacks_and_ai(loop_t0 + sim_budget):
				break
			if not _advance_naval(Time.get_ticks_usec() - loop_t0 > sim_budget / 2):
				break
			ticks_done += 1
			a0 = Time.get_ticks_usec()
			var prepared_economy := _prepared_economy
			_prepared_economy = null
			if _economy_worker != null and state == "play" and net_host == null and not net_remote:
				_economy_begin()
				if prepared_economy != null:
					_economy_worker_rows += _economy_finish(0.1, prepared_economy)
				elif _attack_worker == null and _economy_worker.submit(self, 0.1):
					_tick_stage = 4
				else:
					_economy_finish(0.1)
			else:
				_economy(0.1)
		if _tick_stage == 4:
			if not _economy_worker.ready():
				break
			_economy_worker_rows += _economy_finish(0.1, _economy_worker.take())
		_tick_stage = 0
		sim_ars.tick()
		_tick_missiles(SimArsenal.DT_TICK)  # SimNukes.nukes_tick: flight is counted in sim ticks
		_requests_tick()
		sim_ws.tick()
		_trains_tick()
		prof.eco += Time.get_ticks_usec() - a0
		_fp["t_eco"] = Time.get_ticks_usec() - a0; _pf_add("eco", _fp.t_eco)
		if net_host != null: net_host.on_tick()
		if (_attack_worker != null or _economy_worker != null or _naval_worker != null) and state == "play" and net_host == null and not net_remote: break
	_flush_presentation_batch()
	_fp["sim"] = Time.get_ticks_usec() - loop_t0; _fp["ticks"] = nt; _pf_add("sim", _fp.sim); _pf_add("ticks", nt)

func _advance_naval(defer_paths: bool) -> bool:
	if OS.has_environment("NO_TRADE") and _tick_stage != 5:
		_tick_stage = 0
		return true
	var start := Time.get_ticks_usec()
	var applied := false
	if _tick_stage == 5:
		if not _naval_worker.ready():
			return false
		defer_paths = _naval_worker.defer_paths
		applied = _naval_worker.take(self)
	elif _naval_worker != null and state == "play" and net_host == null and not net_remote and not team_mode:
		if _naval_worker.submit(self, defer_paths):
			_tick_stage = 5
			return false
	_tick_stage = 0
	if applied:
		_naval_worker_ticks += 1
	else:
		sim_naval.defer_paths = defer_paths
		sim_naval.tick()
		sim_naval.defer_paths = false
	var took := Time.get_ticks_usec() - start
	prof["naval"] = prof.get("naval", 0) + took
	_pf_add("naval", took)
	return true

func _advance_attacks_and_ai(deadline: int) -> bool:
	var a0 := Time.get_ticks_usec()
	if _tick_stage == 3:
		if not _attack_worker.ready():
			return false
		if _attack_worker.take(self):
			_attack_worker_applied += 1
			_tick_stage = 2
			_ai_place_budget = 24
			sim_ai.begin_tick()
		else:
			_rebuild_def_posts()
			sim_atk.begin_tick()
			_tick_stage = 1
	if _tick_stage == 1:
		var atk_done := sim_atk.run_slice(deadline)
		prof.atk += Time.get_ticks_usec() - a0
		_fp["t_atk"] = Time.get_ticks_usec() - a0; _pf_add("atk", _fp.t_atk)
		if not atk_done: return false
		_tick_stage = 2
		_ai_place_budget = 24
		sim_ai.begin_tick()
	# the AI pass is spread over frames too (same nations, same order)
	a0 = Time.get_ticks_usec()
	var ai_done := sim_ai.run_slice(deadline)
	var e_ai := Time.get_ticks_usec() - a0
	_fp["t_ai"] = e_ai; _pf_add("ai", e_ai)
	prof.ai += e_ai; prof.ai_max = maxi(prof.ai_max, e_ai)
	return ai_done

func _process_inner(dt: float) -> void:
	var _qp := Time.get_ticks_usec()
	_pump_previews()
	_pf_add("pre", Time.get_ticks_usec() - _qp)
	if not _pace.is_empty() or OS.get_cmdline_user_args().has("--pacetest") : _pace_step(); return
	boat_launched_frame = false
	if state == "pick":
		var picked: bool = (start_tile >= 0 and nations[PLAYER].land > 0) or (net_host != null and net_host.any_placed())
		if picked: deploy_t -= dt
		if picked:
			pick_title.text = "DEPLOYING IN %d" % ceili(maxf(deploy_t, 0.0))
			pick_sub.text = "Click anywhere else on land to switch your starting spot (timer won't reset)."
		else:
			pick_title.text = "CHOOSE YOUR STARTING LOCATION"
			pick_sub.text = "Click any unclaimed land to found your nation."
		pick_ring.set_meta("v", clampf(deploy_t / 5.0, 0, 1)); pick_ring.set_meta("n", ceili(maxf(deploy_t, 0.0)))
		pick_ring.visible = true; pick_ring.queue_redraw()
		if picked and deploy_t <= 0:
			state = "play"
			begin_shields()
			if audio_dir != null: audio_dir.begin_match(); audio_dir.set_music_mood("calm")
			_play_music()
			_focus_player_smooth(2.6)
			var dl := 0.0
			for n in hud_nodes:
				var nd: Control = n
				get_tree().create_timer(dl).timeout.connect(func(): _fade_in(nd, Vector2(0, 12 if nd.position.y > 600 else -12)))
				dl += 0.04
			_fade_out(pick_panel)
			if hud: hud.show_match()
	var rdt := dt
	var _q0 := Time.get_ticks_usec()
	_animate_labels(rdt)
	_pf_add("labels_anim", Time.get_ticks_usec() - _q0)
	_attract_tick(rdt)
	dt *= sim_speed
	if sim_paused: dt = 0.0
	var _at := _attract_active()
	if (state == "play" and not net_remote) or _at:
		# RoWorld runs 10 ticks per second at 1x (SPEED_BASE only slows the visual unit motion)
		var tdt := (0.0 if sim_paused else rdt) * sim_speed / SPEED_BASE
		if _at: tdt *= _attract_boost()
		elapsed += tdt
		_advance_fixed_ticks(tdt)
		if _advance_or_hold_sim_frame(dt, tdt):
			# RoWorld win: Sim.luau:1699  tiles >= WIN_SHARE * (contestable_count - fallout_count)
			var _q2 := Time.get_ticks_usec()
			var pl = nations[PLAYER]
			if _at:
				_attract_check()
			elif net_host != null:
				net_host.check_end()
			elif dominates(PLAYER):
				_game_over(true)
			elif pl.land <= 0 and not spectating:
				_game_over(false)
			elif ticks_done % 10 == 0:
				for id in range(2, nations.size()):
					if dominates(id):
						notify("%s controls 80%% of the land" % nations[id].name, "bad")
						if spectating and client != null:
							# the war ended while we watched: the result card, with no second award
							spectating = false; state = "over"; client.show_over_watched(id)
						else:
							_game_over(false)
						break
			_pf_add("dominates", Time.get_ticks_usec() - _q2)
	dt = rdt
	var _q3 := Time.get_ticks_usec()
	_pan(dt)
	_cam_tick(dt)
	if shake_amp > 0.05:
		shake_t += dt * 42.0
		shake_amp = maxf(0.0, shake_amp - shake_amp * 14.0 * dt - 4.0 * dt)
		cam.offset = Vector2(sin(shake_t * 1.9 + 0.5), cos(shake_t * 2.5)) * shake_amp
	elif cam.offset != Vector2.ZERO:
		shake_amp = 0.0
		cam.offset = Vector2.ZERO
	_publish_render_records()
	if dirty:
		var more := false
		var p0 := Time.get_ticks_usec()
		if _paint_pending(): more = _flush_paint_budget(_paint_budget_us())  # spread big repaints over frames (time budget)
		var up := 0
		# round robin from where the last frame stopped: scanning from chunk 0 every frame let the top
		# rows' constant repaints eat the whole per-frame budget, so the chunks below never uploaded
		# (a hard horizontal seam of stale map, worse on slow devices)
		var ncd := chunk_dirty.size()
		var cap_up := 8 if OS.has_feature("web") else 24
		for n in ncd:
			var k := (_up_cursor + n) % ncd
			if chunk_dirty[k] == 1:
				if net_dedicated:
					chunk_dirty[k] = 0  # (a server has no screen: skip the texture upload)
					continue
				if up >= cap_up: more = true; _up_cursor = k; break
				chunk_tex[k].update(chunk_img[k]); chunk_dirty[k] = 0; uploads += 1; up += 1; _pf_add("uploads", 1)
		dirty = more
		_pf_add("paint", Time.get_ticks_usec() - p0)
	_pf_add("cam_paint", Time.get_ticks_usec() - _q3)
	_pop_tick(rdt)
	ui_timer += dt
	if ui_timer > 0.25 and state != "menu":
		ui_timer = 0
		var h0 := Time.get_ticks_usec()
		_tick_music_mood()
		_update_hud()
		_pf_add("hud", Time.get_ticks_usec() - h0)
	var _q4 := Time.get_ticks_usec()
	_update_tooltip()
	var _q5 := Time.get_ticks_usec()
	_animate_ui(rdt)
	var _q6 := Time.get_ticks_usec()
	if hud: hud.process(rdt)
	var _q7 := Time.get_ticks_usec()
	if client: client.process(rdt)
	var _q8 := Time.get_ticks_usec()
	if note_box: _tick_notes(rdt)
	_tick_ally_card()
	var _q9 := Time.get_ticks_usec()
	_pf_add("tooltip", _q5 - _q4); _pf_add("anim_ui", _q6 - _q5); _pf_add("hud_proc", _q7 - _q6); _pf_add("client_proc", _q8 - _q7); _pf_add("notes", _q9 - _q8)
	ov_t += rdt
	if overlay and state != "menu":
		_last_cam = cam.position; _last_zoom = cam.zoom
		overlay.queue_redraw()
	if autoshot: _autoshot(dt)

func _animate_labels(dt: float) -> void:
	# (the nation springs only feed the fallback names in _draw_overlay_inner; NameLayer has its own)
	if names != null: return
	var records := _render_nations()
	var blend := 1.0 - exp(-4.0 * dt)
	for id in range(1, records.size()):
		var n: Dictionary = records[id]
		if n.land <= 0: continue
		var center := Vector2(n.sx / n.land + 0.5, n.sy / n.land + 0.5) * TS
		var size := sqrt(float(n.land))
		if not _fallback_label_motion.has(id):
			_fallback_label_motion[id] = {"center": center, "size": size}
		var motion: Dictionary = _fallback_label_motion[id]
		motion.center = motion.center.lerp(center, blend)
		motion.size = lerpf(motion.size, size, blend)

func set_speed(k: int) -> void:
	set_speed_x(SPEEDS[clampi(k, 0, SPEEDS.size() - 1)])

func set_speed_x(x: float) -> void:
	x = clampf(snappedf(x, 0.5), 0.5, 10.0)
	if net_host != null: x = minf(x, net_speed_cap)
	elif net_remote: x = 1.0  # a viewer's clock is the host's
	for sp in [1.0, 2.0, 5.0, 10.0]:  # snap points
		if absf(x - sp) <= 0.26: x = sp
	sim_speed = x * SPEED_BASE
	if speed_slider: speed_slider.set_value_no_signal(x)
	if speed_lbl: speed_lbl.text = ("%dx" % int(x)) if is_equal_approx(x, roundf(x)) else ("%.1fx" % x)
	_place_speed_readout()

func _shot(name: String) -> void:
	var im = get_viewport().get_texture().get_image()
	if im:
		DirAccess.make_dir_recursive_absolute(shots_dir)
		im.save_png(shots_dir + "/" + name)
		print("SAVED ", name, " ", im.get_size())

func warp_away() -> void:
	get_viewport().warp_mouse(Vector2(1580, 690))

func _focus_player(z: float) -> void:
	var n = nations[PLAYER]
	cam.zoom = Vector2(z, z); cam.position = Vector2(n.sx / maxf(1, n.land), n.sy / maxf(1, n.land)) * TS; _clamp_cam()

func _focus_player_smooth(z: float, dur := 0.42) -> void:
	if nations.size() <= PLAYER or nations[PLAYER].land <= 0: return
	if autoshot or bench:
		_focus_player(z)
		return
	var n = nations[PLAYER]
	var target_pos := Vector2(n.sx / maxf(1, n.land), n.sy / maxf(1, n.land)) * TS
	var tw := create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(cam, "position", target_pos, dur)
	tw.tween_property(cam, "zoom", Vector2(z, z), dur)
	tw.chain().tween_callback(_clamp_cam)

func _look27(tag: String) -> void:
	var tm := [1.0, 9.0, 10.0, 11.0, 11.2, 11.4, 11.6, 11.8, 12.0, 12.2, 16.0, 40.0]
	if _l27 >= tm.size() or shot_t < tm[_l27]: return
	match _l27:
		0:
			save.settings["qual_i"] = 3; apply_settings()
			_start_game()
			var st := -1
			for k in 5000:
				var i := rng.randi() % (W * H)
				if owner_map[i] == NEUTRAL and _coastal(i) and absi(i % W - W / 2) < 120: st = i; break
			_place_start(st); deploy_t = 0.0
			launch_attack(PLAYER, NEUTRAL, 0.9)
			set_speed(3)
		1:
			var n = nations[PLAYER]
			cam.position = Vector2(n.sx / maxf(1, n.land), n.sy / maxf(1, n.land)) * TS
			cam.zoom = Vector2(2.2, 2.2); _clamp_cam()
		2: _shot("27_%s_territory.png" % tag)
		3:
			var n = nations[PLAYER]
			var pc := Vector2(n.sx / maxf(1, n.land), n.sy / maxf(1, n.land))
			var tgt := -1
			for r in range(20, 120, 4):
				for k in 64:
					var t := Vector2i(pc + Vector2.from_angle(k * TAU / 64.0) * r)
					var ti := t.y * W + t.x
					if t.x > 0 and t.y > 0 and t.x < W and t.y < H and owner_map[ti] > 1: tgt = ti; break
				if tgt >= 0: break
			if tgt < 0: tgt = int(pc.y + 30) * W + int(pc.x + 30)
			_l27c = Vector2(tgt % W, tgt / W)
			detonate(PLAYER, _l27c, float(NUKE_R[7]), 1.0)
			cam.position = _l27c * TS; cam.zoom = Vector2(3.0, 3.0); _clamp_cam()
			fx_freeze = true
			for bl in blasts: bl.t = 0.35
		4: _shot("27_%s_nuke_impact.png" % tag)
		5: for bl in blasts: bl.t = 0.62
		6: _shot("27_%s_nuke_impact_late.png" % tag)
		7: for bl in blasts: bl.t = 2.5
		8: _shot("27_%s_nuke_debris.png" % tag)
		9: fx_freeze = false; blasts.clear()
		10: _shot("27_%s_fallout.png" % tag)
		11: _shot("27_%s_fallout_recede.png" % tag); get_tree().quit()
	_l27 += 1

func _texshot() -> void:
	var tm := [1.0, 4.0, 6.0, 7.0, 9.0, 10.0, 11.0]
	if _qs >= tm.size() or shot_t < tm[_qs]: return
	match _qs:
		0:
			_start_game()
			var st := -1
			for k in 5000:
				var i := rng.randi() % (W * H)
				if owner_map[i] == NEUTRAL and _coastal(i) and absi(i % W - W / 2) < 120: st = i; break
			_place_start(st); deploy_t = 0.0
			launch_attack(PLAYER, NEUTRAL, 0.9)
			set_speed(3)
		1:
			var n = nations[PLAYER]
			n.gold = 1e9
			var c := Vector2i(int(n.sx / maxf(1, n.land)), int(n.sy / maxf(1, n.land)))
			var kinds := [0, 1, 2, 3, 4, 5, 10, 14, 15]
			var placed := 0
			for r in range(0, 40):
				for dy in range(-r, r + 1, 6):
					for dx in range(-r, r + 1, 6):
						if placed >= kinds.size(): break
						var t := (c.y + dy) * W + c.x + dx
						if t < 0 or t >= W * H or owner_map[t] != PLAYER or struct_at.has(t): continue
						var ok := true
						for s2 in structs:
							if Vector2(s2.tile % W, s2.tile / W).distance_to(Vector2(t % W, t / W)) < 6: ok = false
						if ok: _struct_add(kinds[placed], t, PLAYER); placed += 1
			spawn_warship(PLAYER); spawn_warship(PLAYER)
			save.settings["qual_i"] = 3; apply_settings()
		2:
			var n = nations[PLAYER]
			cam.position = Vector2(n.sx / maxf(1, n.land), n.sy / maxf(1, n.land)) * TS
			cam.zoom = Vector2(6, 6); _clamp_cam()
		3: _shot("26_structures_plates.png")
		4:
			if not warships.is_empty(): cam.position = warships[0].pos * TS
			elif not traders.is_empty(): cam.position = _boat_pos(traders[0])[0]
			cam.zoom = Vector2(7, 7); _clamp_cam()
		5: _shot("26_units_sprites.png"); cam.zoom = Vector2(2.5, 2.5); _clamp_cam()
		6: _shot("26_overview_buildbar.png"); get_tree().quit()
	_qs += 1
func _rw_stats(tag: String) -> void:
	var ids := []
	for id in range(1, nations.size()):
		if nations[id].alive and nations[id].land > 0: ids.append(id)
	ids.sort_custom(func(x, y): return nations[x].land > nations[y].land)
	var pl = nations[PLAYER]
	print("RWSTAT %s tick=%d alive=%d attacks=%d boats=%d player land=%d troops=%.0f cap=%.0f gold=%.0f" % [tag, sim_atk.tick, ids.size(), attacks.size(), boats.size(), pl.land, pl.troops, troop_cap(PLAYER), pl.gold])
	for k in mini(6, ids.size()):
		var n = nations[ids[k]]
		print("   #%d %s kind=%d land=%d troops=%.0f/%.0f gold=%.0f" % [k + 1, n.name, kind_of(ids[k]), n.land, n.troops, troop_cap(ids[k]), n.gold])

func _rw_full_view() -> void:
	cam.zoom = Vector2(1.5, 1.5); cam.position = Vector2(W, H) * TS / 2; _clamp_cam()

func _rw_start(mi: int, fx: float, fy: float) -> void:
	map_tab = 0; map_i = mi
	_start_game()
	var st := -1
	for r in range(0, 120, 2):
		for _k in 40:
			var x := clampi(int(W * fx) + rng.randi_range(-r, r), 4, W - 5)
			var y := clampi(int(H * fy) + rng.randi_range(-r, r), 4, H - 5)
			var ok := true
			for dy in range(-4, 5):
				for dx in range(-4, 5):
					if owner_map[(y + dy) * W + x + dx] != NEUTRAL: ok = false
			if ok: st = y * W + x; break
		if st >= 0: break
	_place_start(st)
	_rw_full_view()

func _rwshot() -> void:
	var tm := [1.0, 2.0, 3.0, 3.5, 60.0, 61.0, 120.0, 121.0, 122.0, 123.0, 150.0, 151.0]
	if _rws >= tm.size() or shot_t < tm[_rws]: return
	match _rws:
		0: play_dialog.visible = true; _set_map_tab(0)
		1: _shot("28_map_select_real_maps.png"); play_dialog.visible = false; _rw_start(0, 0.50, 0.30)
		2: _shot("28_world_spawn_phase.png"); _rw_stats("spawn")
		3: deploy_t = 0.0; launch_attack(PLAYER, NEUTRAL, 0.5); set_speed(1)
		4: _rw_full_view(); _shot("28_world_t1.png"); _rw_stats("t1"); launch_attack(PLAYER, NEUTRAL, 0.5)
		5:
			var n = nations[PLAYER]
			cam.position = Vector2(n.sx / maxf(1, n.land), n.sy / maxf(1, n.land)) * TS
			cam.zoom = Vector2(5, 5); _clamp_cam()
		6: _shot("28_player_closeup.png"); _rw_full_view()
		7: _shot("28_world_t2.png"); _rw_stats("t2")
		8: _rw_start(1, 0.45, 0.5)
		9: _shot("28_europe_spawn.png"); deploy_t = 0.0; set_speed(1)
		10: _rw_full_view(); _shot("28_europe_t1.png"); _rw_stats("europe")
		11: get_tree().quit()
	_rws += 1

func _r29_mid() -> Array:
	var k: int = R29_KINDS[_r29_kind]
	var out := []
	for ms in missiles:
		if ms.dur <= 0.0: continue
		var ok: bool = (ms.get("branched", false) and not ms.get("mirv_bus", false)) if k == 9 else (ms.k == k or (k == 12 and ms.get("branched", false)))
		if ok and ms.t / ms.dur >= 0.35 and ms.t / ms.dur <= 0.7: out.append(ms)
	return out

func _rw29() -> void:
	match _r29:
		0:
			if shot_t < 1.0: return
			play_dialog.visible = true; _set_map_tab(0)
		1:
			if shot_t < 2.0: return
			_shot("29_ui_map_select_rounded.png"); play_dialog.visible = false
			_rw_start(0, 0.50, 0.30)
		2:
			if shot_t < 3.0: return
			_shot("29_world_no_antarctica_spawn.png"); _rw_stats("spawn")
			deploy_t = 0.0
		3:
			if shot_t < 3.6: return
			launch_attack(PLAYER, NEUTRAL, 0.6); set_speed(1)
			_r29_t = shot_t
		4:
			if shot_t < _r29_t + 40.0: return
			_rw_full_view(); _shot("29_world_t1.png"); _rw_stats("t1")
			var ports := 0; var placed := []
			for st in structs:
				if st.k == 1: ports += 1
			print("RW29 ports=%d traders=%d boats=%d" % [ports, traders.size(), boats.size()])
			# placement test: city twice on the same click -> second snaps away or upgrades
			var n = nations[PLAYER]
			n.gold = 5e6
			var c := int(n.sy / maxf(1, n.land)) * W + int(n.sx / maxf(1, n.land))
			for k in [0, 0, 1, 2]:
				var site := sim_struct.place_site(PLAYER, k, c)
				var ok := try_build(k, c)
				placed.append("k%d ok=%s site=%d upg=%s reason=%s" % [k, str(ok), site.tile, str(site.upgrade != null), site.reason])
			print("RW29 placement ", placed)
			cam.position = Vector2(c % W, c / W) * TS; cam.zoom = Vector2(6, 6); _clamp_cam()
		5:
			if shot_t < _r29_t + 41.0: return
			_shot("29_ui_hud_rounded_buildings.png")
			_r29_t = shot_t
		6:
			if shot_t < _r29_t + 40.0: return
			_rw_full_view(); _shot("29_world_trade_t2.png"); _rw_stats("t2")
			print("RW29 traders=%d boats=%d" % [traders.size(), boats.size()])
			god_mode = true
			var n = nations[PLAYER]
			var c := -1
			for i in W * H:
				if owner_map[i] == PLAYER and not struct_at.has(i): c = i; break
			_struct_add(5, c, PLAYER); struct_at[c].bt = 0.0
			_r29_kind = 0; _r29_shot = -1
			set_speed(0)
		7:
			# launch the next kind toward a target ~130 tiles east of the silo
			var silo_t := -1
			for st in structs:
				if st.k == 5 and st.o == PLAYER: silo_t = st.tile
			var tx := clampi(silo_t % W + 130, 0, W - 1); var ty := clampi(silo_t / W + 10, 0, H - 1)
			var tgt := -1
			for r in range(0, 60):
				for dx in range(-r, r + 1):
					var i := clampi(ty + r / 2, 0, H - 1) * W + clampi(tx + dx, 0, W - 1)
					if owner_map[i] > 0 and owner_map[i] != PLAYER: tgt = i; break
				if tgt >= 0: break
			missiles.clear(); blasts.clear()
			var k: int = R29_KINDS[_r29_kind]
			print("RW29 launch ", R29_NAMES[k], " ok=", launch_nuke(PLAYER, k, tgt))
			save.settings["qual_i"] = 3; apply_settings()
			_r29_t = shot_t
		8:
			if _r29_mid().is_empty():
				if shot_t - _r29_t > 60.0: print("RW29 timeout ", _r29_kind); _r29 = 10
				return
			sim_speed = 0.0
			_r29_shot = 0
		9:
			var mids := _r29_mid()
			var nm: String = R29_NAMES[R29_KINDS[_r29_kind]]
			var focus := Vector2(W, H) * TS / 2
			if not mids.is_empty():
				var acc := Vector2.ZERO
				for ms in mids: acc += _missile_world_pos(ms, ms.t / ms.dur)
				focus = acc / mids.size()
			var zooms := [1.8, 3.5, 7.0]
			if _r29_shot < 3:
				cam.zoom = Vector2.ONE * zooms[_r29_shot]; cam.position = focus; _clamp_cam()
				_r29_shot += 10  # wait a frame before capturing
				return
			if _r29_shot >= 10 and _r29_shot < 13:
				var zi := _r29_shot - 10
				_shot("29_trail_%s_ultra_z%d.png" % [nm, zi + 1])
				_r29_shot = zi + 1
				if _r29_shot < 3: return
				save.settings["qual_i"] = 2; apply_settings()
				cam.zoom = Vector2.ONE * 3.5; cam.position = focus; _clamp_cam()
				_r29_shot = 20
				return
			if _r29_shot == 20:
				_r29_shot = 21; return
			if _r29_shot == 21:
				_shot("29_trail_%s_high_z2.png" % nm)
			set_speed(0)
			_r29_kind += 1
			if _r29_kind < R29_KINDS.size():
				_r29 = 7; return
		10:
			get_tree().quit(); return
	_r29 += 1

func _qualshot() -> void:
	var tm := [1.0, 3.0, 4.0, 4.6, 5.4, 6.0, 6.8, 9.0, 9.35, 9.6, 9.95, 10.2, 10.55, 11.0, 11.12, 11.5]
	if _qs >= tm.size() or shot_t < tm[_qs]: return
	match _qs:
		0:
			_start_game()
			var st := -1
			for k in 5000:
				var i := rng.randi() % (W * H)
				if owner_map[i] == NEUTRAL and _coastal(i) and absi(i % W - W / 2) < 120: st = i; break
			_place_start(st); deploy_t = 0.0
			launch_attack(PLAYER, NEUTRAL, 0.9)
			set_speed(3)
		1:
			var n = nations[PLAYER]
			cam.position = Vector2(n.sx / maxf(1, n.land), n.sy / maxf(1, n.land)) * TS
			cam.zoom = Vector2(9, 9); _clamp_cam()
			save.settings["qual_i"] = 0; apply_settings()
		2: _shot("22_quality_low.png"); save.settings["qual_i"] = 1; apply_settings()
		3: _shot("22b_quality_medium.png"); save.settings["qual_i"] = 2; apply_settings()
		4: _shot("22c_quality_high.png"); save.settings["qual_i"] = 3; apply_settings()
		5: _shot("23_quality_ultra.png"); _open_settings()
		6: _shot("24_settings_slider.png"); if settings_dlg: settings_dlg.visible = false
		7, 9, 11:
			var hq := _q()
			var n = nations[PLAYER]
			var c := Vector2(n.sx / maxf(1, n.land), n.sy / maxf(1, n.land)) * TS
			cam.zoom = Vector2(4, 4); cam.position = c; _clamp_cam()
			blasts.append({"pos": c + Vector2(14, 6), "r": 6.0 * TS, "t": 0.0, "dur": 1.6, "seed": 99173})
			# follow a boat/trader/warship if one exists
			var tgt = null
			if not warships.is_empty(): tgt = warships[0].pos * TS
			elif not boats.is_empty(): tgt = _boat_pos(boats[0])[0]
			elif not traders.is_empty(): tgt = _boat_pos(traders[0])[0]
			if tgt != null: cam.position = tgt; cam.zoom = Vector2(5, 5); _clamp_cam(); blasts[-1].pos = tgt + Vector2(30, 0)
			if hq != 0: pass
		8: _shot("25_anim_ultra.png"); save.settings["qual_i"] = 1; apply_settings()
		10: _shot("25_anim_medium.png"); save.settings["qual_i"] = 0; apply_settings()
		12: _shot("25_anim_low.png"); save.settings["qual_i"] = 3; apply_settings()
		13:
			if not boats.is_empty():
				cam.position = _boat_pos(boats[0])[0]; cam.zoom = Vector2(7, 7); _clamp_cam()
				print("boat dir ", _boat_pos(boats[0])[1], " q ", _q())
			blasts.append({"pos": cam.position + Vector2(10, 4), "r": 5.0 * TS, "t": 0.5, "dur": 1.6, "seed": 5511})
		14: _shot("25_anim_ultra_ships_blast.png")
		15: get_tree().quit()
	_qs += 1
func _autoshot(dt: float) -> void:
	shot_t += dt
	if "--qualshot" in OS.get_cmdline_user_args():
		_qualshot(); return
	if "--rwshot" in OS.get_cmdline_user_args():
		_rwshot(); return
	if "--rw29" in OS.get_cmdline_user_args():
		_rw29(); return
	if "--texshot" in OS.get_cmdline_user_args():
		_texshot(); return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--look27="):
			_look27(a.substr(9)); return
	if _pre == 0 and shot_t > 1.0 and client != null: client.title.finish_show()
	if _pre == 0 and shot_t > 2.0:
		_shot("01_menu.png"); play_dialog.visible = true; _set_map_tab(0); _pre = 1; return
	if _pre == 1 and shot_t > 2.6:
		_shot("02_play_solo.png"); _set_map_tab(1); _pre = 2; return
	if _pre == 2 and shot_t > 3.2:
		_shot("02b_random_maps.png"); _set_map_tab(0); play_dialog.visible = false; _pre = 3; shot_t = 0.7; _step = 1; return
	if _pre < 3: return
	var plan := [0.6, 1.0, 2.6, 3.0, 14.0, 14.5, 15.5, 16.0, 17.0, 17.5, 19.5, 20.0, 21.0, 22.5, 23.0, 26.0, 27.0, 28.0, 29.0, 30.2, 31.0, 31.8, 32.6, 33.4, 34.2, 35.0, 35.8, 36.6, 37.4, 38.2, 39.0, 39.8, 40.6, 41.4]
	if _step >= plan.size() or shot_t < plan[_step]: return
	match _step:
		0: _shot("01_menu.png")
		1:
			_start_game()
			var st := -1
			for k in 5000:
				var i := rng.randi() % (W * H)
				if owner_map[i] == NEUTRAL and _coastal(i) and absi(i % W - W / 2) < 120: st = i; break
			_place_start(st)
			set_speed(3)
			get_viewport().warp_mouse(_screen_of(Vector2(st % W + 6, st / W + 4) * TS))
		2:
			_shot("03_pick_deploy.png")
			deploy_t = 0.0
		3: launch_attack(PLAYER, NEUTRAL, 0.75)
		4:
			peace = elapsed  # end peace early so AI also targets the player / sends boats
			var bb: Rect2i = nations[PLAYER].bb.grow(2).intersection(Rect2i(0, 0, W, H))
			var tgt := -1
			for y in range(bb.position.y, bb.end.y):
				for x in range(bb.position.x, bb.end.x):
					var o := owner_map[y * W + x]
					if o > 1 and _adj_to(y * W + x, PLAYER) and (tgt < 0 or nations[o].troops > nations[tgt].troops): tgt = o
			if tgt > 0: print("land attack on tribe ", tgt, " ok=", launch_attack(PLAYER, tgt, 0.2))
			else: print("no bordering tribe")
			launch_attack(PLAYER, NEUTRAL, 0.3)
		5:
			var ok := false
			var pc: Vector2i = nations[PLAYER].bb.get_center()
			for k in 6000:
				var i := rng.randi() % (W * H)
				if owner_map[i] >= 0 and owner_map[i] != PLAYER and _coastal(i) and absi(i % W - pc.x) > 30 and absi(i % W - pc.x) < 260:
					ok = launch_boat(PLAYER, i, 0.25)
					if ok: _pboat = boats[boats.size() - 1]; break
			print("player boat ", ok, " route pts ", (_pboat.pts.size() if _pboat else 0))
		6:
			if _pboat and _pboat in boats:
				_pboat.d = maxf(float(_pboat.d), 0.4 * float(_pboat.cum[_pboat.cum.size() - 1]))  # well out to sea: the wake shows
				var bp := _boat_pos(_pboat)
				cam.position = bp[0]; cam.zoom = Vector2(3.0, 3.0); _clamp_cam()
				print("boat progress ", int(_pboat.d), "/", int(_pboat.cum[_pboat.cum.size() - 1]))
		7: _shot("06_boat_curve.png")
		8:
			set_speed(3)
			var ai_b := 0
			for bt in boats: if bt.a != PLAYER: ai_b += 1
			print("AI boats at sea ", ai_b, " total boats ", boats.size())
			cam.zoom = Vector2(1.25, 1.25); cam.position = Vector2(W, H) * TS / 2; _clamp_cam()
		9: _shot("07_ai_boats_speed.png")
		10:
			_focus_player(3.0)
			var bb3: Rect2i = nations[PLAYER].bb.grow(2).intersection(Rect2i(0, 0, W, H))
			var tg := -1
			for y in range(bb3.position.y, bb3.end.y):
				for x in range(bb3.position.x, bb3.end.x):
					var o := owner_map[y * W + x]
					if o > 1 and _adj_to(y * W + x, PLAYER) and (tg < 0 or nations[o].troops > nations[tg].troops): tg = o
			if tg > 0: print("front attack on ", tg, " ok=", launch_attack(PLAYER, tg, 0.15))
			var cnt := 0
			for at in attacks:
				if at.a == PLAYER or at.t == PLAYER: cnt += 1
			print("player-involved attacks ", cnt)
			var best := -1
			for id in range(2, nations.size()):
				var nn = nations[id]
				if nn.alive and nn.land > 30:
					var sp := _screen_of(Vector2(nn.sx / nn.land, nn.sy / nn.land) * TS)
					if sp.x > 400 and sp.x < 1200 and sp.y > 150 and sp.y < 650: best = id; break
			if best > 0:
				var nn = nations[best]
				get_viewport().warp_mouse(_screen_of(Vector2(nn.sx / nn.land, nn.sy / nn.land) * TS))
		11: _shot("08_front.png")
		12:
			_focus_player(3.0)
			var n = nations[PLAYER]
			n.gold = 6e7
			_claim_blob(PLAYER, int(n.sy / n.land) * W + int(n.sx / n.land), 26)  # test harness: give room for buildings
			_focus_player(2.2)
			var placed := 0
			for kk in [5, 1, 1, 4, 10, 0, 2, 0, 3, 0, 2]:
				for tries in 4000:
					var bb2: Rect2i = n.bb
					var ti := (bb2.position.y + rng.randi() % maxi(1, bb2.size.y)) * W + bb2.position.x + rng.randi() % maxi(1, bb2.size.x)
					if try_build(kk, ti): placed += 1; print("  built ", build_data[kk][1]); break
			for st in structs:
				st.bt = 0.0
			for id in range(2, nations.size()):
				if is_prot(id) and nations[id].alive and owned_count(id, 1) == 0:
					var bbp: Rect2i = nations[id].bb
					for tries in 600:
						var ti := (bbp.position.y + rng.randi() % maxi(1, bbp.size.y)) * W + bbp.position.x + rng.randi() % maxi(1, bbp.size.x)
						if owner_map[ti] == id and _coastal(ti): _struct_add(1, ti, id); struct_at[ti].bt = 0.0; break
			print("buildings placed ", placed, " warship ", try_build(6, -1))
			tip_slot = -1; build_sel = -1
			warp_away()
		13: _shot("05_buildings.png")
		14:
			# nukes at the two nearest other nations
			var n = nations[PLAYER]
			var pc := Vector2(n.sx, n.sy) / maxf(1, n.land)
			var cands := []
			for id in range(2, nations.size()):
				var nn = nations[id]
				if nn.alive and nn.land > 20: cands.append([pc.distance_to(Vector2(nn.sx, nn.sy) / nn.land), id])
			cands.sort()
			var shots_done := 0
			for c in cands.slice(0, 2):
				for st in structs:
					if st.o == PLAYER and st.k == 5: st.cd = 0.0
				var nn = nations[c[1]]
				var ti := int(nn.sy / nn.land) * W + int(nn.sx / nn.land)
				var kk := 9 if shots_done == 0 else 7
				print("nuke ", build_data[kk][1], " at ", nn.name, " (land=", nn.land, ") ok=", try_build(kk, ti))
				shots_done += 1
			# alliance: ally with a protagonist, then force the expiry warning
			for id in range(2, nations.size()):
				if is_prot(id) and nations[id].alive:
					form_alliance(PLAYER, id)
					allies[_akey(PLAYER, id)] = sim_atk.tick + 250
					break
		15:
			var tgt := Vector2.ZERO
			if not blasts.is_empty(): tgt = blasts[0].pos
			var fo := 0
			for i in W * H: if fallout[i] == 1: fo += 1
			if tgt == Vector2.ZERO:
				for i in range(0, W * H, 7):
					if fallout[i] == 1: tgt = Vector2(i % W, i / W) * TS; break
			# Also showcase in-flight nukes on parabolic ballistic arcs with 3x thicker (4.5px) host-country-colored trails
			var n = nations[PLAYER]
			var pc := Vector2(n.sx / maxf(1, n.land), n.sy / maxf(1, n.land))
			var ft := tgt / TS if tgt != Vector2.ZERO else pc + Vector2(36, 12)
			# 1. Standard 1.0x (4.5px) Atom Bomb trail
			missiles.append({"o": PLAYER, "k": 7, "from": pc, "to": ft + Vector2(20, -8), "t": 16.0, "dur": 25.0, "r": float(NUKE_R[7]), "mirv": false, "branched": false})
			# 2. MIRV landed at the aimed point `ft` (detonating there) and branching 6 sub-warheads outward from `ft` with 0.5x (2.25px) trails
			detonate(PLAYER, ft, 6.0, 1.0)
			for m in 6:
				var ang := -PI * 0.85 + float(m) * (PI * 1.7 / 5.0)
				var sub_to := ft + Vector2.from_angle(ang) * (16.0 + float(m % 2) * 8.0)
				missiles.append({"o": PLAYER, "k": 9, "from": ft, "to": sub_to, "t": 13.5 + m * 0.7, "dur": 22.0, "r": float(NUKE_R[9]), "mirv": true, "branched": true})
			var rival_o := 2
			for id in range(2, nations.size()):
				if is_prot(id) and nations[id].alive: rival_o = id; break
			missiles.append({"o": rival_o, "k": 11, "from": ft + Vector2(-42, 16), "to": ft + Vector2(-4, 6), "t": 18.5, "dur": 25.0, "r": 36.0, "mirv": false, "branched": false})
			var b_center: Vector2 = tgt if tgt != Vector2.ZERO else (pc + Vector2(22, 6)) * TS
			blasts.append({"pos": b_center, "r": 16.0 * TS, "t": 0.32, "dur": 1.45, "seed": 424242})
			blasts.append({"pos": b_center + Vector2(36, -18) * TS, "r": 9.0 * TS, "t": 0.14, "dur": 1.45, "seed": 777111})
			print("fallout tiles ", fo, " missiles ", missiles.size(), " blasts ", blasts.size(), " notes ", notes.size())
			cam.zoom = Vector2(2.1, 2.1); cam.position = (pc * TS + b_center) * 0.5; _clamp_cam()
			overlay.queue_redraw()
		16: _shot("10_nukes_fallout_notes.png")
		17:
			print("ally card visible ", ally_card.visible, " notes ", notes.size(), " warships ", warships.size(), " traders ", traders.size(), " structs ", structs.size())
			_shot("11_alliance_card.png")
		18:
			save.unlocked = ["mega", "reinf", "air", "rail"]
			var n = nations[PLAYER]
			n.gold = 6e7
			var built := false
			for tries in 4000:
				var bb2: Rect2i = n.bb
				var ti := (bb2.position.y + rng.randi() % maxi(1, bb2.size.y)) * W + bb2.position.x + rng.randi() % maxi(1, bb2.size.x)
				if try_build(14, ti): built = true; break
			var fired := 0
			for st in structs:
				if st.k == 14 and st.o == PLAYER:
					st.bt = 0.0
					if launch_sortie_legacy(st): fired += 1
			for pl in planes: pl.dur = 40.0; pl.t = 14.0
			var pc := Vector2(n.sx, n.sy) / maxf(1, n.land)
			var best := -1; var bd := 1e9
			for id in range(2, nations.size()):
				var nn = nations[id]
				if nn.alive and nn.land > 20:
					var dd := pc.distance_to(Vector2(nn.sx, nn.sy) / nn.land)
					if dd < bd: bd = dd; best = id
			for st in structs:
				if st.o == PLAYER and st.k == 5: st.cd = 0.0
			if best > 0:
				var nn = nations[best]
				print("railgun ok=", fire_railgun(PLAYER, int(nn.sy / nn.land) * W + int(nn.sx / nn.land)))
				for bm in beams: bm.t = -3.0
			print("airfield built ", built, " sorties ", fired, " planes ", planes.size())
			if not planes.is_empty():
				_focus_player(2.4)
		19: _shot("12_airstrike_railgun.png")
		20:
			# Showcase railways, moving gold trains, in-place Lv2/Lv3 upgrades, construction ring, and exponential price ladder
			var n = nations[PLAYER]
			n.gold = 9e7
			_claim_blob(PLAYER, int(n.sy / maxf(1, n.land)) * W + int(n.sx / maxf(1, n.land)), 26)
			for kk in [0, 2, 0, 2, 1, 3, 5, 4, 10]:
				if owned_count(PLAYER, kk) < (2 if kk in [0, 2] else 1):
					for tries in 3000:
						var bb2: Rect2i = n.bb
						var ti := (bb2.position.y + rng.randi() % maxi(1, bb2.size.y)) * W + bb2.position.x + rng.randi() % maxi(1, bb2.size.x)
						if owner_map[ti] == PLAYER and not struct_at.has(ti) and try_build(kk, ti): break
			var upgraded := 0
			for st in structs:
				if st.o == PLAYER:
					st.bt = 0.0
					if st.k in [0, 2, 4, 5, 10]:
						try_build(st.k, st.tile)
						upgraded += 1
						if st.k in [0, 2] and upgraded <= 3:
							try_build(st.k, st.tile)
					st.bt = 0.0
			# Show one structure actively constructing with progress ring
			# Also guarantee one Factory -> coastal Port/City across water to showcase the straight steel bridge alongside curved land tracks
			var fac_st = null
			for st in structs:
				if st.o == PLAYER and st.k == 2: fac_st = st; break
			if fac_st != null:
				var fp := Vector2(fac_st.tile % W + 0.5, fac_st.tile / W + 0.5)
				for k_ang in 36:
					var ang := float(k_ang) * TAU / 36.0
					var w_seen := false
					for dist_r in range(8, 38):
						var p := fp + Vector2.from_angle(ang) * float(dist_r)
						var tx := int(p.x); var ty := int(p.y)
						if tx < 2 or ty < 2 or tx >= W - 2 or ty >= H - 2: break
						var ti := ty * W + tx
						if owner_map[ti] == WATER:
							w_seen = true
						elif w_seen and owner_map[ti] >= 0 and not struct_at.has(ti):
							var spans_chk := _water_crossing_spans(fp, Vector2(tx + 0.5, ty + 0.5))
							if spans_chk.size() == 1:
								_set_owner(ti, PLAYER)
								_struct_add(1, ti, PLAYER)
								struct_at[ti].bt = 0.0
								# Force a straight bridge entry in path_cache so it renders the steel bridge across the inlet
								var lo_b := mini(fac_st.tile, ti); var hi_b := maxi(fac_st.tile, ti)
								var lp0 := Vector2(lo_b % W + 0.5, lo_b / W + 0.5)
								var hp0 := Vector2(hi_b % W + 0.5, hi_b / W + 0.5)
								var sp0 := _water_crossing_spans(lp0, hp0)
								if sp0.size() >= 1:
									var b_s: Vector2 = sp0[0][0]; var b_e: Vector2 = sp0[0][1]
									var b_pts := PackedVector2Array([lp0, b_s, b_e, hp0])
									var b_cum := PackedFloat32Array([0.0])
									for m in range(1, b_pts.size()): b_cum.append(b_cum[m - 1] + b_pts[m].distance_to(b_pts[m - 1]))
									path_cache["r%d:%d" % [lo_b, hi_b]] = [b_pts, b_cum, [[b_s, b_e]]]
								break
					if path_cache.size() > 0:
						var has_br := false
						for ck in path_cache:
							if String(ck).begins_with("r") and path_cache[ck].size() >= 3 and path_cache[ck][2].size() > 0: has_br = true; break
						if has_br: break
			for st in structs:
				if st.o == PLAYER: st.bt = 0.0
			trains.clear()
			for st in structs:
				if st.o == PLAYER and st.k == 2:
					spawn_train_from(st)
					spawn_train_from(st)
			for st in structs:
				if st.o == PLAYER and st.k == 3:
					st.bt = 1.6; st.bmax = 5.0; break
			for m in trains.size():
				trains[m].dur = 10.0; trains[m].t = 3.0 + m * 2.2
			# Verify capturing enemy military infrastructure (SAM / Silo / Artillery) via land conquest
			var enemy_id := 2
			for id in range(2, nations.size()):
				if nations[id].alive: enemy_id = id; break
			var cap_tile := -1
			for tries in 500:
				var bb3: Rect2i = n.bb
				var ti := (bb3.position.y + rng.randi() % maxi(1, bb3.size.y)) * W + bb3.position.x + rng.randi() % maxi(1, bb3.size.x)
				if owner_map[ti] == PLAYER and not struct_at.has(ti):
					cap_tile = ti; break
			var cap_ok := false
			if cap_tile >= 0:
				owner_map[cap_tile] = enemy_id
				nations[PLAYER].land -= 1; nations[enemy_id].land += 1
				_struct_add(4, cap_tile, enemy_id)  # Enemy SAM Launcher Lv2
				struct_at[cap_tile].level = 2; struct_at[cap_tile].bt = 0.0; _sv += 1
				_set_owner(cap_tile, PLAYER)        # Player conquers tile -> claims SAM Launcher Lv2!
				cap_ok = struct_at.has(cap_tile) and struct_at[cap_tile].o == PLAYER
			var ppos := Vector2(n.sx / maxf(1, n.land), n.sy / maxf(1, n.land)) * TS
			add_float(ppos + Vector2(18, -12), "+10K", GOLD_C)
			add_float(ppos + Vector2(-24, 10), "+35K", GOLD_C)
			_focus_player(2.6)
			_update_hud()
			overlay.queue_redraw()
			print("trains active ", trains.size(), " upgraded ", upgraded, " captured_enemy_struct=", cap_ok)
		21: _shot("16_trains_rails_upgrades.png")
		22:
			# Showcase 3-tier terrain, smooth frontlines, right-click Diplomacy & Embargo popup, and 42% peak growth indicator
			var n = nations[PLAYER]
			n.troops = troop_cap(PLAYER) * 0.42
			_update_hud()
			var target_id := -1
			for id in range(2, nations.size()):
				if nations[id].alive and is_prot(id):
					target_id = id; break
			if target_id < 0:
				for id in range(2, nations.size()):
					if nations[id].alive and nations[id].land > 15:
						target_id = id; break
			if target_id > 0:
				var tn = nations[target_id]
				var tc := Vector2(tn.sx / maxf(1, tn.land), tn.sy / maxf(1, tn.land)) * TS
				cam.zoom = Vector2(2.0, 2.0); cam.position = tc; _clamp_cam()
				_open_diplo(target_id, Vector2(820, 320))
			overlay.queue_redraw()
		23: _shot("17_diplomacy_embargo_terrain.png")
		24:
			if diplo_panel: diplo_panel.visible = false
			_open_settings()
		25:
			_shot("20_settings_graphics.png")
			if settings_dlg: settings_dlg.visible = false
			console_unlocked = false
			toggle_console()
			console_pass_in.text = "5516"
			_update_console_fps(0.0055)
		26:
			_shot("21_tab_locked_fps.png")
			unlock_console("5516")
			run_console_cmd("help")
			run_console_cmd("gold = 99999999")
			run_console_cmd("boat_speed = 6.0")
			run_console_cmd("NUKE_R[7] = 7")
			run_console_cmd("vars")
			print("tab console visible=", console_panel.visible, " unlocked=", console_unlocked)
		27:
			_shot("19_tab_console.png")
		28:
			if console_panel and console_panel.visible: toggle_console()
			stats.elims = maxi(stats.elims, 3)
			_game_over(true)
		29:
			print("stars after match ", save.stars)
			_shot("13_victory.png")
		30:
			end_dlg.visible = false
			_to_menu()
			save.stars = maxi(save.stars, 9000)
			if stars_lbl: stars_lbl.text = _fmt_int(save.stars)
		31: _shot("14_menu_stars.png")
		32:
			_open_shop()
			# Test unlocking Artillery (2,500 stars) directly in the unified Shop/Stars modal
			var before_s: int = save.stars
			var u_ok := unlock_arsenal_item("art")
			print("shop unlock art ok=", u_ok, " stars ", before_s, " -> ", save.stars)
		33:
			_shot("15_arsenal.png")
			_shot("18_unified_shop.png")
			get_tree().quit()
	_step += 1

func _draw_overlay() -> void:
	var _dt0 := Time.get_ticks_usec()
	_draw_overlay_inner()
	var dus := Time.get_ticks_usec() - _dt0
	_pf_add("draw", dus)
	if _sfx_log and dus > 40000: print("SLOW draw %.0f ms" % (dus / 1000.0))

func _draw_overlay_inner() -> void:
	var records := _render_nations()
	if state == "menu" or records.size() < 2: return
	var f := ThemeDB.fallback_font
	var z := cam.zoom.x
	for id in range(1, records.size()):
		if names != null: break  # (client/map/name_layer.gd draws the names)
		var n: Dictionary = records[id]
		if not n.alive or n.land < 4: continue
		var motion: Dictionary = _fallback_label_motion.get(id, {})
		var c: Vector2 = motion.get("center", Vector2(n.sx / n.land + 0.5, n.sy / n.land + 0.5) * TS)
		var sp := _screen_of(c)
		if sp.x < -100 or sp.y < -50 or sp.x > 1700 or sp.y > 950: continue
		var fs := int(float(motion.get("size", sqrt(float(n.land)))) * TS * z * 0.28)
		if fs < 8: continue
		fs = mini(fs, 64)
		var nm: String = n.name if id != PLAYER else "You"
		var w := 400.0
		f.draw_string_outline(overlay.get_canvas_item(), sp + Vector2(-w / 2, 0), nm, HORIZONTAL_ALIGNMENT_CENTER, w, fs, maxi(2, fs / 6), Color(1, 1, 1, 0.65))
		overlay.draw_string(f, sp + Vector2(-w / 2, 0), nm, HORIZONTAL_ALIGNMENT_CENTER, w, fs, Color(0.08, 0.1, 0.16))
		overlay.draw_string(f, sp + Vector2(-w / 2, fs * 0.95), UITheme.fmt_troops(n.troops), HORIZONTAL_ALIGNMENT_CENTER, w, int(fs * 0.8), Color(0.08, 0.1, 0.16, 0.85))
	# structures
	var _w0 := Time.get_ticks_usec()
	_draw_world_fx(z)
	_pf_add("wfx", Time.get_ticks_usec() - _w0)
	if build_sel >= 0:
		var mt := _mouse_tile()
		if mt >= 0:
			var ok: bool = build_req(build_sel, mt) == "" and nations[PLAYER].gold >= build_cost(PLAYER, build_sel)
			var mp := get_viewport().get_mouse_position()
			var rr := {3: sim_rules.defense_range, 4: sim_rules.sam_range(1), 10: sim_rules.artillery_range(), 14: (0.0 if strike_only else sim_rules.airfield_range())}.get(build_sel, 0.0) as float  # (14: the Airfield's reach, shown before it is built)
			if build_sel in NUKES: rr = sim_rules.nuke_radii(SimRules.NUKE_KIND_OF[build_sel]).y if build_sel == 9 else float(NUKE_R[build_sel])  # (MapView.set_aim: the kind's outer radius; MIRV its spread)
			var strike_aim := _is_strike_click(build_sel, mt, PLAYER)
			_feed_ranges(mt, strike_aim)
			if strike_aim: rr = sim_rules.strike_radius(SimRules.N_AIRSTRIKE if build_sel == 14 else SimRules.N_SLUG)
			if build_sel == 14 and ranges == null:
				for st in structs:
					if st.o == PLAYER and st.k == 14 and st.get("bt", 0.0) <= 0.0:
						var spa := _screen_of(Vector2(st.tile % W + 0.5, st.tile / W + 0.5) * TS)
						overlay.draw_arc(spa, sim_rules.airfield_range() * TS * z, 0, TAU, 96, Color(0.4, 0.8, 1.0, 0.7), 1.6, true)
			if rr > 0 and not (ranges != null and build_sel in [3, 4, 10, 14] and not strike_aim):  # (RangeLayer draws the build ring)
				var cc := Color(1, 0.3, 0.25) if (build_sel in NUKES or strike_aim) else Color(0.3, 0.6, 1)
				overlay.draw_circle(mp, rr * TS * z, Color(cc, 0.12))
				overlay.draw_arc(mp, rr * TS * z, 0, TAU, 64, Color(cc, 0.85), 2.0)
			if build_sel in NUKES:
				var tpw := Vector2(mt % W + 0.5, mt / W + 0.5)
				var inr := not silo_for(PLAYER, build_sel, tpw).is_empty()
				var tgt := _tex("ui_icons/target.png")
				if tgt: overlay.draw_texture_rect(tgt, Rect2(mp - Vector2(14, 14), Vector2(28, 28)), false, Color(1, 0.3, 0.25) if inr else Color(0.5, 0.5, 0.5, 0.8))
				if icbm_mode:
					overlay.draw_string(f_bold, mp + Vector2(18, -14), "ICBM  +10%%  (%s)  ·  20%% evade, +20%% speed, -20%% cooldown" % _fmt(nuke_cost(build_sel)), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 0.8, 0.5))
			if build_sel == 2:
				for st in structs:
					if st.o == PLAYER and st.k == 2:
						var sp1 := _screen_of(Vector2(st.tile % W + 0.5, st.tile / W + 0.5) * TS)
						overlay.draw_circle(sp1, FACTORY_RANGE * TS * z, Color(0.95, 0.85, 0.4, 0.06))
						overlay.draw_arc(sp1, FACTORY_RANGE * TS * z, 0, TAU, 96, Color(0.95, 0.85, 0.4, 0.8), 2.0, true)
				var spm := FACTORY_RANGE * TS * z
				if ranges == null: overlay.draw_arc(mp, spm, 0, TAU, 96, Color(0.95, 0.85, 0.4, 0.55), 1.5, true)
			if build_sel in NUKES or strike_aim or (strike_only and (build_sel == 14 or build_sel == 15)):
				overlay.draw_line(mp + Vector2(-10, 0), mp + Vector2(10, 0), Color(1, 0.3, 0.25), 2)
				overlay.draw_line(mp + Vector2(0, -10), mp + Vector2(0, 10), Color(1, 0.3, 0.25), 2)
			else:
				if build_sel == 6 and unit_layer != null:
					var gc: Color = nations[PLAYER].color if ok else Color(0.9, 0.2, 0.2)
					unit_layer.sprite(overlay, UnitLayer.COL_WARSHIP, Color(gc, 0.7), mp, unit_layer.sprite_px(), true)
				elif not (struct_layer != null and struct_layer.draw_ghost(overlay, build_sel, mp, ok)):
					_map_icon(mp, build_sel, Color(0.3, 0.9, 0.4) if ok else Color(0.95, 0.3, 0.3), 0.8)
	elif _rl_fed:
		_feed_ranges(-1, false)
	# attack fronts: upstream FrontLayer.luau (plain stroked troop text on the local player's fronts)
	# (attack-front troop labels: client/map/front_layer.gd)
	# boats with curved routes
	for bt in ([] if client != null else boats):
		var bp := _boat_pos(bt)
		var pts: PackedVector2Array = bt.pts
		var col: Color = nations[bt.a].color
		# no route line: the ship leaves a wake trail behind it instead
		var p0 := _screen_of(bp[0])
		if bt.get("air", false):
			_plane_glyph(p0, _sdir(bt, bp[1]), col, 1.0, false); continue
		_wake_trail(bt, bp[0], maxf(1.6, _ship_px(true) * 0.28))
		var dir: Vector2 = _sdir(bt, bp[1])
		var nrm := Vector2(-dir.y, dir.x)
		var sc := clampf(cam.zoom.x * 3.0, 5.0, 12.0) * SHIP_CIVIL_SCALE
		_wake(p0, dir, maxf(2.5, _ship_px(true) * 5.0 / 26.0))  # upstream: transports leave a wake (UnitLayer)
		if not _ship_sprite(p0, 0, col, true):
			var hull := PackedVector2Array([p0 + dir * sc, p0 + dir * sc * 0.2 + nrm * sc * 0.45, p0 - dir * sc * 0.8 + nrm * sc * 0.4, p0 - dir * sc * 0.8 - nrm * sc * 0.4, p0 + dir * sc * 0.2 - nrm * sc * 0.45])
			overlay.draw_colored_polygon(hull, col.darkened(0.3))
			overlay.draw_polyline(hull + PackedVector2Array([hull[0]]), Color(1, 1, 1, 0.9), 1.2)
		# upstream UnitLayer.luau draws no troop label on transport boats

func _icon(p: Vector2, k: int, col: Color, a: float, ci: CanvasItem = null, r := 11.0, bg := true) -> void:
	if ci == null: ci = overlay
	var u := r / 11.0
	var w := Color(1, 1, 1, a) if bg else Color(col, a)
	var dark := Color(0.1, 0.12, 0.2, a)
	if bg:
		ci.draw_circle(p, r + 2 * u, Color(1, 1, 1, a * 0.9))
		ci.draw_circle(p, r, Color(col.darkened(0.35), a))
	else:
		u *= 1.25
	if UI_TEX.has(k):
		var ut := _tex(UI_TEX[k])
		if ut != null:
			var s2 := r * (1.5 if bg else 1.7)
			ci.draw_texture_rect(ut, Rect2(p - Vector2(s2, s2) / 2, Vector2(s2, s2)), false, w)
			return
	var P := func(arr: Array) -> PackedVector2Array:
		var out := PackedVector2Array()
		for v in arr: out.append(p + v * u)
		return out
	match k:
		0:  # city: skyline
			ci.draw_rect(Rect2(p + Vector2(-7, -1) * u, Vector2(4, 7) * u), w)
			ci.draw_rect(Rect2(p + Vector2(-2, -7) * u, Vector2(4, 13) * u), w)
			ci.draw_rect(Rect2(p + Vector2(3, -3) * u, Vector2(4, 9) * u), w)
		1:  # port: mast + sail + wave
			ci.draw_line(p + Vector2(-1, -7) * u, p + Vector2(-1, 3) * u, w, 2 * u)
			ci.draw_colored_polygon(P.call([Vector2(0, -6), Vector2(6, 2), Vector2(0, 2)]), w)
			ci.draw_arc(p + Vector2(0, 1) * u, 6.5 * u, 0.35, PI - 0.35, 10, w, 2 * u)
		2:  # factory: saw roof + chimney
			ci.draw_colored_polygon(P.call([Vector2(-7, 6), Vector2(-7, -1), Vector2(-3, -4), Vector2(-3, -1), Vector2(1, -4), Vector2(1, -1), Vector2(7, -1), Vector2(7, 6)]), w)
			ci.draw_rect(Rect2(p + Vector2(4, -8) * u, Vector2(3, 7) * u), w)
		3:  # defense post: shield
			ci.draw_colored_polygon(P.call([Vector2(-6, -6), Vector2(6, -6), Vector2(6, 0), Vector2(0, 7), Vector2(-6, 0)]), w)
			ci.draw_line(p + Vector2(0, -5) * u, p + Vector2(0, 5) * u, dark, 2 * u)
		4:  # SAM: interceptor on launcher
			ci.draw_colored_polygon(P.call([Vector2(0, -8), Vector2(2.5, -3), Vector2(2.5, 3), Vector2(-2.5, 3), Vector2(-2.5, -3)]), w)
			ci.draw_rect(Rect2(p + Vector2(-6, 4) * u, Vector2(12, 3) * u), w)
		5:  # silo: dome over shaft
			ci.draw_arc(p + Vector2(0, 1) * u, 6 * u, PI, TAU, 12, w, 2 * u)
			ci.draw_rect(Rect2(p + Vector2(-6, 1) * u, Vector2(12, 5) * u), w)
			ci.draw_line(p + Vector2(0, -3) * u, p + Vector2(0, 4) * u, dark, 2 * u)
		6:  # warship: hull + tower
			ci.draw_colored_polygon(P.call([Vector2(-8, 1), Vector2(8, 1), Vector2(5, 5), Vector2(-6, 5)]), w)
			ci.draw_rect(Rect2(p + Vector2(-2, -5) * u, Vector2(5, 6) * u), w)
			ci.draw_line(p + Vector2(3, -3) * u, p + Vector2(8, -4) * u, w, 1.5 * u)
		7:  # atom bomb: core + orbit
			ci.draw_circle(p, 3 * u, w)
			ci.draw_arc(p, 7 * u, 0, TAU, 20, w, 1.5 * u)
		8:  # hydrogen bomb: core + two orbits
			ci.draw_circle(p, 2.5 * u, w)
			ci.draw_arc(p, 5 * u, 0, TAU, 16, w, 1.2 * u)
			ci.draw_arc(p, 8 * u, 0, TAU, 20, w, 1.2 * u)
		9:  # MIRV: three warheads
			for dx in [-5, 0, 5]:
				ci.draw_colored_polygon(P.call([Vector2(dx, -6 + absi(dx) * 0.4), Vector2(dx + 2, 0), Vector2(dx - 2, 0)]), w)
			ci.draw_line(p + Vector2(-6, 4) * u, p + Vector2(6, 4) * u, w, 1.5 * u)
		10:  # artillery: barrel + wheel
			ci.draw_line(p + Vector2(-5, 3) * u, p + Vector2(7, -5) * u, w, 3 * u)
			ci.draw_circle(p + Vector2(-2, 4) * u, 3 * u, w)
		11:  # mega nuke: big core, thick ring
			ci.draw_circle(p, 4.5 * u, w)
			ci.draw_arc(p, 8 * u, 0, TAU, 24, w, 2.5 * u)
		12:  # scattershot: center + five satellites
			ci.draw_circle(p, 3 * u, w)
			for m in 5:
				ci.draw_circle(p + Vector2.from_angle(m * TAU / 5 - PI / 2) * 7 * u, 1.6 * u, w)
		13:  # reinforcements: plus + chevron
			ci.draw_rect(Rect2(p + Vector2(-1.5, -7) * u, Vector2(3, 10) * u), w)
			ci.draw_rect(Rect2(p + Vector2(-5, -3.5) * u, Vector2(10, 3) * u), w)
			ci.draw_polyline(P.call([Vector2(-5, 7), Vector2(0, 4), Vector2(5, 7)]), w, 1.5 * u)
		14:  # airfield: little plane
			ci.draw_colored_polygon(P.call([Vector2(0, -8), Vector2(1.5, -3), Vector2(8, 1), Vector2(8, 3), Vector2(1.5, 1), Vector2(1, 5), Vector2(3.5, 7), Vector2(-3.5, 7), Vector2(-1, 5), Vector2(-1.5, 1), Vector2(-8, 3), Vector2(-8, 1), Vector2(-1.5, -3)]), w)
		15:  # railgun: twin rails + bolt
			ci.draw_line(p + Vector2(-7, 5) * u, p + Vector2(5, -7) * u, w, 1.8 * u)
			ci.draw_line(p + Vector2(-5, 7) * u, p + Vector2(7, -5) * u, w, 1.8 * u)
			ci.draw_circle(p + Vector2(7, -7) * u, 2 * u, w)
		_:
			ci.draw_circle(p, 4 * u, w)

func _badge(p: Vector2, t: String, col: Color, left: bool, center := false) -> void:
	var f := ThemeDB.fallback_font
	var fs := 14
	var sz := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var x := p.x - sz.x / 2 - 5 if center else (p.x - sz.x - 10 if left else p.x)
	var r := Rect2(Vector2(x, p.y - sz.y + 2), sz + Vector2(10, 4))
	overlay.draw_rect(r, col)
	overlay.draw_string(f, Vector2(x + 5, p.y + 1), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)

func _pan(dt: float) -> void:
	if console_panel != null and console_panel.visible: return
	var v := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT): v.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): v.x += 1
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP): v.y -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN): v.y += 1
	if _minput_on(): return  # (MapInput pans)
	if _mcam_on():
		if v != Vector2.ZERO: mcam.pan(v, dt)
		return
	cam.position += v * 900.0 * dt / cam.zoom.x
	_clamp_cam()


# ---- the ported map camera drives the Camera2D (smooth zoom, drag inertia, focus glides) ----
# Screenshot and benchmark runs place the Camera2D themselves and are left alone.
func _mcam_on() -> bool:
	return mcam != null and not _mc_off and not autoshot and not bench

func _cam_tick(dt: float) -> void:
	if cam == null or W <= 0 or H <= 0: return
	if mcam == null:
		mcam = MapCamera.new(W, H, get_viewport_rect().size)
		_mc_off = "--uishot" in OS.get_cmdline_user_args()
	if not _mcam_on(): return
	if mcam.W != W or mcam.H != H:
		mcam.set_map(W, H); _mc_pos = Vector2.INF
	mcam.set_viewport(get_viewport_rect().size)
	if cam.position != _mc_pos or cam.zoom != _mc_zoom:
		# something else placed the camera (a match start, the console): take it from there
		mcam.halt()
		mcam.scale = mcam.clamp_scale(cam.zoom.x * TS); mcam.target_scale = mcam.scale
		mcam.look_at(cam.position.x / TS, cam.position.y / TS)
	mcam.attract = state == "menu"
	if _minput_on():
		minput.tick(dt)
		dragging = minput.is_dragging()
		var hs := minput.hold_state()
		client.hold_ring.set_hold(hs[0], hs[1])
	mcam.tick(FrameClock.dt(dt))
	cam.zoom = Vector2.ONE * (mcam.scale / TS)
	cam.position = Vector2(mcam.cu, mcam.cv) * TS
	_mc_pos = cam.position; _mc_zoom = cam.zoom

func _clamp_cam() -> void:
	var half := get_viewport_rect().size / cam.zoom / 2.0
	var m := Vector2(W, H) * TS
	# map bounds incl. Antarctica: only enough slack (screen px) that the top bar / bottom command bar
	# don't hide the first and last rows; never past the map edge by more than that
	var lo := half - Vector2(24, 64) / cam.zoom
	var hi := m - half + Vector2(24, 128) / cam.zoom
	cam.position.x = clampf(cam.position.x, lo.x, hi.x) if lo.x < hi.x else m.x / 2
	cam.position.y = clampf(cam.position.y, lo.y, hi.y) if lo.y < hi.y else m.y / 2

func _zoom_at(f: float, screen: Vector2) -> void:
	if _mcam_on():
		mcam.zoom_by(f, mcam.globe_hit(screen)); return
	var before := get_global_mouse_position()
	cam.zoom = (cam.zoom * f).clamp(Vector2(0.6, 0.6), Vector2(12, 12))
	cam.force_update_scroll()
	var after := get_canvas_transform().affine_inverse() * screen
	cam.position += before - after
	_clamp_cam()

var _rl_fed := false

## The range rings of what is being placed or aimed (RangeLayer: the SAM / post / airfield / artillery / factory
## ring before it is built, the warship's 130 tiles, the hostile SAMs covering a nuke's aim). The client feeds
## the layer from its touch ghost; with a mouse nothing did, so no ring showed before placing.
func _feed_ranges(mt: int, strike_aim: bool) -> void:
	if ranges == null or (client != null and client.ctx.touch):
		return
	var kind := ""
	var det := ""
	if mt >= 0 and build_sel >= 0:
		if build_sel in NUKES:
			kind = "nuke"
			det = {7: "atom", 8: "hydrogen", 9: "mirv", 11: "mega", 12: "scatter"}.get(build_sel, "")
		elif strike_aim:
			kind = "nuke"
			det = "airstrike" if build_sel == 14 else "slug"
		elif build_sel == 6:
			kind = "warship"
			det = "warship"
		else:
			det = {2: "factory", 3: "defense", 4: "sam", 10: "artillery", 14: "airfield"}.get(build_sel, "")
			if det != "": kind = "build"
	if kind == "":
		if _rl_fed:
			_rl_fed = false
			ranges.set_aim("", -1)
		return
	_rl_fed = true
	ranges.set_aim(kind, mt, det, 1)

func _screen_of(world: Vector2) -> Vector2:
	return get_canvas_transform() * world

func _mouse_tile() -> int:
	var p := get_global_mouse_position() / TS
	var x := int(floor(p.x)); var y := int(floor(p.y))
	if x < 0 or y < 0 or x >= W or y >= H:
		return -1
	return y * W + x

func _attack_at_cursor() -> void:
	var t := _mouse_tile()
	if t < 0: return
	var o: int = owner_map[t]
	if o < 0 or o == PLAYER: return
	# Once your country touches someone else's land, it must ONLY be raided via land; if there is NO land border, use ships!
	if o > 0:
		if _shares_land_border(PLAYER, o):
			launch_attack(PLAYER, o, SHARES[share_i])
		else:
			launch_boat(PLAYER, t, SHARES[share_i])
	else:
		if _shares_land_border(PLAYER, NEUTRAL, t):
			launch_attack(PLAYER, NEUTRAL, SHARES[share_i])
		else:
			launch_boat(PLAYER, t, SHARES[share_i])

# ---- the ported pointer input (clicks, drags, long press, pinch, wheel) ----
func _minput_on() -> bool:
	return minput != null and _mcam_on() and client != null

func _make_minput() -> void:
	minput = MapInput.new(mcam)
	minput.active = func() -> bool:
		return state != "menu" and client.ctx.world.input_enabled and not (console_panel != null and console_panel.visible)
	minput.tile_at = func(pos: Vector2) -> int: return client.ctx.tile_at(pos)
	minput.over_gui = func(_pos: Vector2) -> bool: return get_viewport().gui_get_hovered_control() != null
	minput.tile_clicked.connect(_map_click)
	minput.tile_context.connect(_map_context)

func _map_click(tile: int) -> void:
	if state == "play" and build_sel >= 0 and client.interact.aim_kind == "": try_build(build_sel, tile)
	elif state == "pick" or state == "play": client.on_click_tile(tile)

func _map_context(tile: int, pos: Vector2) -> void:
	if build_sel >= 0: build_sel = -1
	elif client.cancel_selection(): pass
	elif sel_ws != null: sel_ws = null
	elif state == "play": client.on_context_at(tile, pos)

func _unhandled_input(e: InputEvent) -> void:
	_try_unlock_web_audio(e)
	if _mcam_on() and client != null and minput == null: _make_minput()
	if _minput_on() and not (e is InputEventKey):
		minput.input(e)
		return
	if e is InputEventMouseButton:
		if e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(1.15, e.position)
		elif e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(1.0 / 1.15, e.position)
		elif e.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			if e.pressed:
				lpress = true; dragging = false; drag_from = e.position
			else:
				if lpress and not dragging and e.button_index == MOUSE_BUTTON_LEFT:
					if state == "play" and build_sel >= 0 and (client == null or client.interact.aim_kind == ""): try_build(build_sel, _mouse_tile())
					elif (state == "pick" or state == "play") and client != null: client.on_click()
					elif state == "pick":
						_place_start(_mouse_tile())
					elif state == "play":
						if _warship_click(): pass
						else: _attack_at_cursor()
				elif lpress and not dragging and e.button_index == MOUSE_BUTTON_RIGHT:
					if build_sel >= 0: build_sel = -1
					elif client != null and client.cancel_selection(): pass
					elif sel_ws != null: sel_ws = null
					elif state == "play":
						if client != null: client.on_context()
						else: _right_click()
				lpress = false; dragging = false
				if mcam != null and mcam.dragging: mcam.end_drag()
	if e is InputEventMouseMotion and lpress:
		if dragging or e.position.distance_to(drag_from) > 6:
			dragging = true
			if _mcam_on():
				if not mcam.dragging: mcam.begin_drag()
				mcam.drag_by(e.relative)
			else:
				cam.position -= e.relative / cam.zoom.x
				_clamp_cam()
	if console_panel != null and console_panel.visible and e is InputEventKey:
		return
	if e is InputEventKey and e.pressed and client != null and client.on_key(e.keycode, e.echo):
		return
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_Q: _set_share(share_i - 1)
			KEY_E: _set_share(share_i + 1)
			KEY_SPACE:
				if state == "play":
					if client != null: client.on_primary_key()
					else: _attack_at_cursor()
			KEY_BACKSPACE:
				for k in range(attacks.size() - 1, -1, -1):
					if attacks[k].a == PLAYER:
						retreat(attacks[k]); break
			KEY_TAB: toggle_console()
			KEY_M: hud_toggle_music()
			KEY_HOME:
				if client != null and state != "menu" and nations.size() > PLAYER: client.ctx.world.focus_owner(PLAYER)
			KEY_I: if state == "play": set_icbm(not icbm_mode)
			KEY_H:
				if client != null: client.toggle_help()
				else: help_panel.visible = not help_panel.visible
			KEY_ESCAPE:
				if arsenal_dlg != null and arsenal_dlg.visible: _close_shop()
				elif client != null and client.help.is_open: client.toggle_help()
				elif client != null and client.pause.is_open: client.pause.close()
				elif client != null and client.map_picker.is_open: client.map_picker.close()
				elif client != null and state == "menu" and client.title.solo_menu_open(): client.title.close_solo_menu()
				elif hud != null and hud.menu_open(): hud.close_menu()
				elif client != null and client.interact.escape(): pass
				elif build_sel >= 0: build_sel = -1
				elif sel_ws != null: sel_ws = null
				elif hud != null and (state == "play" or state == "pick"): hud.open_menu()
				else: _to_menu()
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9:
				select_build(e.keycode - KEY_1)
			KEY_0: select_build(9)
			KEY_KP_1, KEY_KP_2, KEY_KP_3, KEY_KP_4, KEY_KP_5, KEY_KP_6, KEY_KP_7, KEY_KP_8, KEY_KP_9:
				select_build(e.keycode - KEY_KP_1)
			KEY_KP_0: select_build(9)
			KEY_R: select_build(13)
			KEY_MINUS, KEY_KP_SUBTRACT: set_speed_x(sim_speed / SPEED_BASE - 0.5)
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD: set_speed_x(sim_speed / SPEED_BASE + 0.5)


# Upstream's land-gain "bubble" pops (AudioDirector.pop): every 0.1 s the player's gained tiles go to the director.
var _pop_clock := 0.0
var _pop_land := -1
func _pop_tick(rdt: float) -> void:
	_pop_clock += rdt
	if _pop_clock < 0.1: return
	_pop_clock = 0.0
	if state != "play" or audio_dir == null or PLAYER >= nations.size():
		_pop_land = -1
		return
	var land := int(nations[PLAYER].land)
	if _pop_land >= 0 and land > _pop_land:
		var lin: float = sim_rules.k_lin if sim_rules != null else 1.0
		var tiles := float(land - _pop_land) * lin * lin
		var prog := clampf(float(land) / maxf(float(land_total), 1.0) / 0.8, 0.0, 1.0)
		audio_dir.pop(tiles, prog)
	_pop_land = land


# ---- title-screen attract mode (upstream: a live AI-only world behind the title, started as a time-lapse) ----
var _attract_t := 0.0
var _attract_wait := 0.0
const ATTRACT_LAPSE_S := 8.0    # real seconds of time-lapse at the start of each demo world
const ATTRACT_LAPSE_X := 5.0
const ATTRACT_MAX_S := 300.0    # a demo world is replaced after this long

func _attract_allowed() -> bool:
	return not (DisplayServer.get_name() == "headless" or autoshot or bench) \
		and bool(save.get("settings", {}).get("attract_on", true)) and not _loading

func _attract_active() -> bool:
	return attract_on and state == "menu"

func _attract_boost() -> float:
	if _attract_t < 3.0: return 20.0  # fast opening so nations are visible within ~2 s
	return ATTRACT_LAPSE_X if _attract_t < ATTRACT_LAPSE_S else 1.0

func _attract_tick(rdt: float) -> void:
	if state != "menu":
		attract_on = false
		_attract_wait = 0.0
		return
	if attract_on:
		_attract_t += rdt
		return
	if not _attract_allowed(): return
	_attract_wait += rdt
	if _attract_wait >= 0.6 and (client == null or not client.arsenal.is_open):
		_attract_begin()

# A fresh AI-only world behind the title: no player nation, nobody to notify or make sounds for.
func _attract_begin() -> void:
	_attract_wait = 0.0
	attract_on = true
	_attract_t = 0.0
	attract_building = true
	_start_game()  # (sets state "pick" and the pick UI: put the menu state back)
	attract_building = false
	state = "menu"
	if pick_panel: pick_panel.visible = false
	if menu_panel:
		if menu_panel.has_meta("fade_tw"):
			var tw: Tween = menu_panel.get_meta("fade_tw")
			if tw and tw.is_valid(): tw.kill()
		menu_panel.visible = true; menu_panel.modulate.a = 1.0
	nations[PLAYER].alive = false
	nations[PLAYER].land = 0
	peace = 0.0
	set_speed(0)
	sim_paused = false
	attract_on = true
	if hud: hud.show_match()

func _attract_check() -> void:
	if _attract_t > ATTRACT_MAX_S:
		_attract_begin(); return
	if ticks_done % 50 != 0: return
	for id in range(2, nations.size()):
		if nations[id].alive and dominates(id):
			_attract_begin(); return
