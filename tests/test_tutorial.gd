# The ported tutorial: starts its match, walks the first steps.
#   godot --headless --path . --script tests/test_tutorial.gd
extends SceneTree

var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	var m = load("res://main.tscn").instantiate()
	root.add_child(m)
	for _f in 3: await process_frame
	var c = m.client
	var tut = c.tutorial
	c.ctx.set_setting("tips_seen", {})
	c.start_tutorial()
	_check(tut.active and c.coach.muted, "tutorial begins and mutes the coach")
	var guard := 0
	while (m.state != "pick" or m._loading) and guard < 4000:
		await process_frame
		guard += 1
	_check(m.state == "pick", "the tutorial's match is built (state %s)" % m.state)
	for _f in 5: await process_frame
	_check(tut._spot >= 0, "a start is suggested")
	_check(c.ctx.ratio_max <= 0.5 + 1e-6, "the Attack bar is capped at 50%")
	c.ctx.send({"type": "spawn", "tile": tut._spot})
	m.deploy_t = 0.0; m.state = "play"; m.peace = 0.0
	m._claim_blob(m.PLAYER, tut._spot, 40)
	m.nations[m.PLAYER].troops = 4000.0
	for _f in 80: await process_frame
	_check(tut._i == 2, "step 2 (expand) after spawning (at %d)" % tut._i)
	_check(tut._card.visible, "the step card shows")
	if DisplayServer.get_name() != "headless":
		m.shots_dir = "/workspace/shots/ui_match/raw_1600"
		m._shot("6_tutorial.png")
	# take neutral land
	c.interact.enabled = true
	var W: int = m.W
	var neutral := -1
	for t in m.owner_map.size():
		if m.owner_map[t] != m.PLAYER: continue
		for d in [1, -1, W, -W]:
			var q: int = t + d
			if q >= 0 and q < m.owner_map.size() and m.owner_map[q] == m.NEUTRAL and m.terrain_ok(q) if m.has_method("terrain_ok") else (q >= 0 and q < m.owner_map.size() and m.owner_map[q] == m.NEUTRAL):
				neutral = q
		if neutral >= 0: break
	c.interact._last_click_tile = -1
	c.interact.on_click(neutral)
	for _f in 80: await process_frame
	_check(tut._i == 3, "step 3 (grow) after the first order (at %d)" % tut._i)
	tut.stop("skipped")
	_check(not tut.active and not c.coach.muted and c.ctx.ratio_max >= 1.0, "skip ends it and frees the bar")
	_check(str(c.ctx.setting("tutorial", "")) == "skipped", "the outcome is remembered")
	c.ctx.set_setting("tutorial", "")
	print("TUTORIAL_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(0 if fails == 0 else 1)
