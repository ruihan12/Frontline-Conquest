# Crates: roll rules (never a duplicate, odds scale up), opening for Stars, equip, a skin on the map, the window.
#   godot --headless --path . -s res://tests/test_crates.gd
extends SceneTree

var fails := 0

func _ok(cond: bool, what: String) -> void:
	if not cond:
		fails += 1
	print(("  ok   " if cond else "  FAIL ") + what)

func _init() -> void:
	# pure rules
	var owned := {}
	var od := CosmeticsRules.odds(owned)
	var sum := 0.0
	for e in od: sum += float(e.odds)
	_ok(absf(sum - 1.0) < 1e-6, "odds sum to 1")
	_ok(CosmeticsRules.all().size() == RWCosmetics.SKINS.size() + RWCosmetics.FLAGS.size(), "catalog = skins + flags")
	var rng := RandomNumberGenerator.new(); rng.seed = 7
	var got := {}
	var dup := false
	for _i in CosmeticsRules.all().size():
		var id := CosmeticsRules.roll(owned, rng.randf(), rng.randf())
		if id == "" or owned.has(id): dup = true; break
		owned[id] = true
		got[id] = true
	_ok(not dup and owned.size() == CosmeticsRules.all().size(), "rolling to the end gives every item exactly once")
	_ok(CosmeticsRules.roll(owned, 0.3, 0.3) == "", "nothing left: no roll")
	# legendary odds drop out once all legendaries are owned
	var o2 := {}
	for it in CosmeticsRules.all():
		if it.rarity == "legendary": o2[it.id] = true
	for e in CosmeticsRules.odds(o2):
		if e.rarity.id == "legendary": _ok(float(e.odds) == 0.0, "no legendary odds once all are owned")
	var s1 := 0.0
	for e in CosmeticsRules.odds(o2): s1 += float(e.odds)
	_ok(absf(s1 - 1.0) < 1e-6, "the other rarities scale up to 1")
	# in the game
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	hs.start(0, 0, Vector2(0.5, 0.38), 0, -1.0)
	var s = m.client.ctx.session
	m.save.stars = 5000
	m.save.cosmetics.owned = {}
	_ok(s.open_crate(), "opens a crate with enough Stars")
	_ok(int(m.save.stars) == 5000 - CosmeticsRules.CRATE_COST, "costs %d Stars" % CosmeticsRules.CRATE_COST)
	_ok(m.save.cosmetics.owned.size() == 1 and s.last_crate_item != "", "one item added: %s" % s.last_crate_item)
	m.save.stars = 10
	_ok(not s.open_crate(), "refuses without Stars")
	_ok(not s.equip("skin", "stripes") or m.save.cosmetics.owned.has("stripes"), "cannot wear an unowned skin")
	# a skin on the map: give the player land, then compare a masked and an unmasked tile
	m.save.cosmetics.owned["checker"] = true
	_ok(s.equip("skin", "checker"), "equips an owned skin")
	_ok(m.skin_of(m.PLAYER) != null and m.skin_of(m.PLAYER + 1) == null, "skin_of: the player only")
	var W: int = m.W
	m.nations[m.PLAYER].color = Color(0.2, 0.5, 0.9)
	for y in range(100, 108):
		for x in range(100, 108):
			m.owner_map[y * W + x] = m.PLAYER
	m.surface._pal.clear()
	var a: Color = m.surface.tile_color(103 * W + 103)  # (x>>1, y>>1) = (51, 51): '#' at (1, 1) of the 2x2 mask
	var b: Color = m.surface.tile_color(103 * W + 105)  # (52, 51): '.' at (0, 1)
	_ok(not a.is_equal_approx(b), "skin tiles differ from plain tiles on the map")
	m.save.cosmetics.skin = ""
	m.surface._pal.clear()
	var c1: Color = m.surface.tile_color(103 * W + 103)
	var c2: Color = m.surface.tile_color(103 * W + 105)
	_ok(c1.is_equal_approx(c2) or not c1.is_equal_approx(a), "taking the skin off restores the plain fill")
	# the window
	var cr = m.client.crates
	cr.open()
	for _i in 4: await process_frame
	_ok(cr.is_open and cr.visible, "Crates window opens")
	cr.close()
	print("CRATES_TEST ", "PASS" if fails == 0 else "FAIL", " fails=", fails)
	quit(1 if fails > 0 else 0)
