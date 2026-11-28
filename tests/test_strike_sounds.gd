# Artillery shells, air strikes and railgun slugs sound as upstream (owner report 2026-11-28: artillery played
# the nuke explosion). Upstream UIAdvisor.on_nuke_launched / on_nuke_detonated for the Arsenal's kinds: a shell
# plays shell_fire when fired and shell_hit when it lands (on screen); an air strike sam_launch at pitch 0.85
# and the SAM hit (sam_intercept) at 0.8; a slug shell_fire at 0.6 and sam_intercept at 1.25. Never the nuke
# launch sting or the nuclear blast. On the Luau path and on the GDScript fallback (NO_LUAU_SIM), the player
# fires each kind with the camera on it; the audio director's log must hold exactly those sounds.
#   godot --headless --path . -s res://tests/test_strike_sounds.gd
extends SceneTree

var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	_run()


func _events(ad) -> Array:
	var out := []
	for r in ad.play_log: out.append(r)
	for r in ad.blocked_log: out.append(r)
	return out


func _find(evs: Array, canon: String) -> Dictionary:
	for r in evs:
		if str(r.canonical) == canon: return r
	return {}


func _one(luau: bool) -> void:
	if luau: OS.unset_environment("NO_LUAU_SIM")
	else: OS.set_environment("NO_LUAU_SIM", "1")
	var name := "Luau" if luau else "GDScript"
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	m.rng.seed = 5516; seed(5516)
	hs.start(0, 0, Vector2(0.5, 0.38), 0, -1.0)
	m.peace = 0.0
	for t in 60: m._sim_tick_whole()
	var ad = m.audio_dir
	_check(ad != null, "%s: the audio director is there" % name)
	if ad == null: return
	# a player tile and an enemy land tile a few tiles away
	var W: int = m.W
	var from := -1
	var to := -1
	for i in range(0, m.owner_map.size(), 3):
		if m.owner_map[i] != m.PLAYER: continue
		for d in [6, -6, 6 * W, -6 * W, 8, -8]:
			var j: int = i + d
			if j >= 0 and j < m.owner_map.size() and m.owner_map[j] > 0 and m.owner_map[j] != m.PLAYER and not m.allied(m.PLAYER, m.owner_map[j]):
				from = i; to = j; break
		if from >= 0: break
	_check(from >= 0, "%s: found a player tile next to enemy land" % name)
	if from < 0: return
	m.cam.position = Vector2(from % W + 0.5, from / W + 0.5) * m.TS
	m.cam.zoom = Vector2(4, 4)
	m.cam.force_update_scroll()
	await process_frame
	var cases := [[SimRules.N_SHELL, "shell", "shell_fire", -1.0, "shell_hit", -1.0],
		[SimRules.N_AIRSTRIKE, "air strike", "sam_launch", 0.85, "sam_intercept", 0.8],
		[SimRules.N_SLUG, "slug", "shell_fire", 0.6, "sam_intercept", 1.25]]
	for c in cases:
		ad.clear_logs()
		ad._last_start_ms.clear(); ad._last_full_ms.clear()
		m.sim_ars._spawn_munition(int(c[0]), m.PLAYER, from, to)
		var fired := _find(_events(ad), str(c[2]))
		_check(not fired.is_empty(), "%s %s: fired sound is %s (%s)" % [name, c[1], c[2], str(_events(ad).map(func(r): return r.canonical))])
		if not fired.is_empty() and float(c[3]) > 0.0 and fired.get("reason", "") == "play":
			_check(is_equal_approx(float(fired.pitch), float(c[3])), "%s %s: fired pitch %.2f" % [name, c[1], float(fired.pitch)])
		ad._last_start_ms.clear(); ad._last_full_ms.clear()
		for t in 80:
			m._sim_tick_whole()
			if m.sim_ars.munitions.is_empty(): break
		var evs := _events(ad)
		var hit := _find(evs, str(c[4]))
		_check(not hit.is_empty(), "%s %s: impact sound is %s (%s)" % [name, c[1], c[4], str(evs.map(func(r): return r.canonical))])
		if not hit.is_empty() and float(c[5]) > 0.0 and hit.get("reason", "") == "play":
			_check(is_equal_approx(float(hit.pitch), float(c[5])), "%s %s: impact pitch %.2f" % [name, c[1], float(hit.pitch)])
		_check(_find(evs, "nuke_explosion").is_empty() and _find(evs, "nuke_launch").is_empty(),
			"%s %s: no nuke launch or nuke explosion sound" % [name, c[1]])
	m.queue_free()
	await process_frame
	await process_frame


func _run() -> void:
	if LuauVM.available():
		await _one(true)
	else:
		_check(false, "extension loaded")
	await _one(false)
	OS.unset_environment("NO_LUAU_SIM")
	print("STRIKE_SOUNDS_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
