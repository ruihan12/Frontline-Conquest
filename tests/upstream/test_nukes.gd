# Port of tests/simsys_nukes.luau (costs, radii, speeds, SAM, MIRV, arc) plus the kept ICBM toggle.
extends RefCounted

const R := preload("res://sim/rules.gd")

func _read_main() -> String:
	return preload("res://tests/upstream/_harness.gd").game_src()

func _has(src: String, pat: String) -> bool:
	return src.find(pat) >= 0

func run(H) -> void:
	H.section("simsys_nukes / munitions constants", "simsys_nukes.luau")
	var r: SimRules = R.new(1.0)

	# costs
	H.expect_eq(SimRules.NUKE_COST[SimRules.N_ATOM], 750000.0, "atom costs 750K")
	H.expect_eq(SimRules.NUKE_COST[SimRules.N_HYDROGEN], 5000000.0, "hydrogen costs 5M")
	H.expect_eq(SimRules.NUKE_COST[SimRules.N_MIRV], 25000000.0, "MIRV base cost 25M")
	H.expect_eq(SimRules.NUKE_COST[SimRules.N_MEGA], 2500000.0, "mega costs 2.5M")
	H.expect_eq(SimRules.NUKE_COST[SimRules.N_SCATTER], 3750000.0, "scatter costs 3.75M")
	H.expect_eq(SimRules.NUKE_COST[SimRules.N_SHELL], 0.0, "shell is free (battery is the price)")
	H.expect_eq(SimRules.NUKE_COST[SimRules.N_AIRSTRIKE], 0.0, "airstrike is free (airfield is the price)")
	H.expect_eq(SimRules.NUKE_COST[SimRules.N_SLUG], 0.0, "slug is free (railgun is the price)")
	H.expect_eq(SimRules.MIRV_COST_STEP, 15000000.0, "upstream MIRV_COST_STEP constant is 15M")

	# inner/outer full-size radii stored in Rules (source numbers)
	var atom: Vector2 = r.nuke_radii_full_scaled(SimRules.N_ATOM)
	H.expect(abs(atom.x - 12.0) < 1e-5 and abs(atom.y - 30.0) < 1e-5, "Rules atom radii 12 / 30 (full-size, k_lin=1)", "inner=%s outer=%s" % [str(atom.x), str(atom.y)])
	var hyd: Vector2 = r.nuke_radii_full_scaled(SimRules.N_HYDROGEN)
	H.expect(abs(hyd.x - 80.0) < 1e-5 and abs(hyd.y - 100.0) < 1e-5, "Rules hydrogen radii 80 / 100", "inner=%s outer=%s" % [str(hyd.x), str(hyd.y)])
	var wh: Vector2 = r.nuke_radii_full_scaled(SimRules.N_WARHEAD)
	H.expect(abs(wh.x - 12.0) < 1e-5 and abs(wh.y - 18.0) < 1e-5, "Rules warhead radii 12 / 18", "inner=%s outer=%s" % [str(wh.x), str(wh.y)])
	var mega: Vector2 = r.nuke_radii_full_scaled(SimRules.N_MEGA)
	H.expect(abs(mega.x - 24.0) < 1e-5 and abs(mega.y - 60.0) < 1e-5, "Rules mega = 2× atom inner / outer (24 / 60)", "inner=%s outer=%s" % [str(mega.x), str(mega.y)])
	var sc: Vector2 = r.nuke_radii_full_scaled(SimRules.N_SCATTER)
	H.expect(abs(sc.x - 12.0) < 1e-5 and abs(sc.y - 30.0) < 1e-5, "Rules scatter crater = atom (12 / 30)", "inner=%s outer=%s" % [str(sc.x), str(sc.y)])

	# speeds (source table)
	H.expect_eq(SimRules.NUKE_SPEED_FULL[SimRules.N_ATOM], 10.0, "atom speed 10 full-size tiles/tick")
	H.expect_eq(SimRules.NUKE_SPEED_FULL[SimRules.N_HYDROGEN], 10.0, "hydrogen speed 10")
	H.expect_eq(SimRules.NUKE_SPEED_FULL[SimRules.N_MIRV], 15.0, "MIRV bus speed 15")
	H.expect_eq(SimRules.NUKE_SPEED_FULL[SimRules.N_WARHEAD], 22.0, "warhead speed 22")
	H.expect_eq(SimRules.NUKE_SPEED_FULL[SimRules.N_MEGA], 10.0, "mega speed 10")
	H.expect_eq(SimRules.NUKE_SPEED_FULL[SimRules.N_SCATTER], 10.0, "scatter speed 10")
	H.expect_eq(SimRules.NUKE_SPEED_FULL[SimRules.N_SHELL], 6.0, "shell speed 6")
	H.expect_eq(SimRules.NUKE_SPEED_FULL[SimRules.N_AIRSTRIKE], 8.0, "airstrike speed 8")
	H.expect_eq(SimRules.NUKE_SPEED_FULL[SimRules.N_SLUG], 80.0, "slug speed 80")

	H.expect_eq(SimRules.NUKE_INTERCEPT_P[SimRules.N_MIRV], 0.0, "MIRV bus intercept probability 0 (can't be intercepted)")
	H.expect_eq(SimRules.NUKE_INTERCEPT_P[SimRules.N_ATOM], 1.0, "atom can be intercepted")
	H.expect_eq(SimRules.NUKE_INTERCEPT_P[SimRules.N_SHELL], 0.0, "shells are not SAM-able")
	H.expect_eq(SimRules.NUKE_INTERCEPT_P[SimRules.N_AIRSTRIKE], 0.0, "air strikes are not SAM-able")
	H.expect_eq(SimRules.MIRV_WARHEADS, 350, "MIRV_WARHEADS 350 (upstream cap)")
	H.expect_eq(SimRules.SILO_COOLDOWN_TICKS, 90, "silo cooldown 9 s (90 ticks)")
	H.expect_eq(SimRules.SAM_COOLDOWN_TICKS, 90, "SAM cooldown 9 s")
	H.expect_eq(SimRules.SAM_MISSILE_SPEED_FULL, 12.0, "SAM missile 12 full-size tiles/tick")
	H.expect_eq(r.sam_ticks_to(12.0), 1, "SAM manhattan time: 12 tiles / 12 per tick = 1")
	H.expect_eq(SimRules.NUKE_GRUDGE_TICKS, 3000, "nuke grudge 3000 ticks")
	H.expect_eq(SimRules.SCATTER_MIN, 4, "scatter 4–6 warheads (min)")
	H.expect_eq(SimRules.SCATTER_MAX, 6, "scatter 4–6 warheads (max)")
	H.expect_near(r.scatter_near(), 28.0, 1e-9, "scatter near 28 full-size tiles")
	H.expect_near(r.scatter_far(), 46.0, 1e-9, "scatter far 46 full-size tiles")

	# warhead death factor
	H.expect_near(SimRules.warhead_death(0.0, 10000.0), 0.0, 1e-9, "warhead_death: no loss at 0 troops")
	# below 3% of max: excess 0
	H.expect_near(SimRules.warhead_death(200.0, 10000.0), 0.0, 1e-9, "warhead_death: no loss below 3% of cap")
	var excess = 10000.0 - 0.03 * 10000.0
	var want_full = 500.0 * (1.0 - exp(-2.0 * excess / 10000.0))
	H.expect_near(SimRules.warhead_death(10000.0, 10000.0), want_full, 1e-6, "warhead_death at cap = 500*(1-e^(-2*0.97))")

	# SAM range / reload are upstream's (no port multipliers)
	H.expect_near(r.sam_range(1), 70.0, 1e-6, "sam_range(1) = 150 - 480/6 = 70 full-size tiles")
	H.expect_near(r.sam_range(3), 90.0, 1e-6, "sam_range(3) = 150 - 480/8 = 90")
	H.expect_eq(SimRules.RELOAD_TICKS[4], 90, "SAM reload 90 ticks")
	H.expect_eq(SimRules.RELOAD_TICKS[5], 90, "silo reload 90 ticks")

	# radii in our tiles (Rules.nuke_radii) on a resampled map (k_lin 1.115)
	var r2: SimRules = R.new(1.115)
	H.expect_near(r2.nuke_radii(SimRules.N_ATOM).y, 30.0 / 1.115, 1e-4, "atom outer 30 / k_lin")
	H.expect_near(r2.nuke_radii(SimRules.N_HYDROGEN).x, 80.0 / 1.115, 1e-4, "hydrogen inner 80 / k_lin")
	H.expect_near(r2.nuke_radii(SimRules.N_WARHEAD).y, 18.0 / 1.115, 1e-4, "warhead outer 18 / k_lin")
	H.expect_eq(r2.nuke_radii(SimRules.N_MIRV).y, float(int(1500.0 / 1.115)), "MIRV radii: (0, MIRV_SPREAD = trunc(1500 / k_lin))")

	# Rules.nuke_arc / nuke_arc_at / nuke_arc_ticks
	H.section("Rules.nuke_arc", "Rules.luau 853-916")
	var sp := Vector2(10.5, 200.5)
	var dp := Vector2(310.5, 200.5)
	var arc: Dictionary = r.nuke_arc(400, sp, dp)
	H.expect((arc.pts as PackedVector2Array).size() == SimRules.NUKE_ARC_SAMPLES + 1, "arc has NUKE_ARC_SAMPLES + 1 points")
	H.expect(SimRules.nuke_arc_at(arc, 0.0).distance_to(sp) < 1e-4 and SimRules.nuke_arc_at(arc, 1.0).distance_to(dp) < 1e-4, "arc runs silo -> target")
	var mid: Vector2 = SimRules.nuke_arc_at(arc, 0.5)
	# control points raised by max(300/3, 50) = 100: the Bezier apex is 0.75 * 100 above the chord
	H.expect_near(mid.y, 200.5 - 75.0, 0.05, "arc apex: 3/4 of max(dist/3, 50) toward the top of the map")
	H.expect_near(mid.x, 160.5, 0.05, "arc apex is halfway across")
	var len: float = arc.length
	H.expect(len > 300.0 and len < 360.0, "arc length is longer than the chord", "len=%.2f" % len)
	H.expect_eq(r.nuke_arc_ticks(arc, SimRules.N_ATOM), int(ceil(len / 10.0)), "atom flight ticks = ceil(arc length / 10)")
	H.expect_eq(r.nuke_arc_ticks(arc, SimRules.N_MIRV), int(ceil(len / 15.0)), "MIRV bus flight ticks = ceil(arc length / 15)")
	H.expect_eq(r.nuke_arc_ticks(arc, SimRules.N_WARHEAD), int(ceil(len / 22.0)), "warhead flight ticks = ceil(arc length / 22)")
	H.expect_eq(r2.nuke_arc_ticks(arc, SimRules.N_ATOM), int(ceil(len * 1.115 / 10.0)), "flight ticks scale with k_lin")
	var short: Dictionary = r.nuke_arc(400, Vector2(50.5, 300.5), Vector2(80.5, 300.5))
	H.expect_near(SimRules.nuke_arc_at(short, 0.5).y, 300.5 - 37.5, 0.05, "short shots still rise by the 50 full-size tile minimum")
	var top: Dictionary = r.nuke_arc(400, Vector2(50.5, 5.5), Vector2(950.5, 5.5))
	H.expect(SimRules.nuke_arc_at(top, 0.5).y >= -1e-4, "arc control points are clamped to the map top")
	var flat: Dictionary = r.munition_arc(400, sp, dp, SimRules.N_SLUG)
	H.expect_near(float(flat.length), 300.0, 1e-4, "flat munitions fly a straight line")

	# --- vanilla nukes + the kept ICBM toggle, checked in the game source ---
	H.section("vanilla nukes (game source)", "simsys_nukes.luau")
	var src = _read_main()
	H.expect(src != "", "game source readable", "")
	H.expect(not _has(src, "NUKE_RANGE_SCALE") and not _has(src, "NUKE_RANGE_FRAC"), "no custom nuke range (upstream launch_range 0 for bombs)")
	H.expect(_has(src, "NUKE_SPEED_X := 0.9"), "nukes fly at 0.9x upstream NUKE_SPEED_FULL (owner request)", "kept custom")
	H.expect(not _has(src, "7.0 * BLAST_S"), "no custom x2.8 blast radii (upstream NUKE_OUTER_FULL / k_lin)")
	H.expect(not _has(src, "_nuke_pill"), "no nuke countdown pill (upstream has none)")
	H.expect(_has(src, "ICBM_FEE_PCT := 0.10") or _has(src, "ICBM_FEE_PCT := 0.1"), "ICBM +10% cost", "kept custom")
	H.expect(_has(src, "icbm_mode"), "ICBM toggle present", "kept custom")
	H.expect(_has(src, "func _split_mirv(") and _has(src, "SimRules.MIRV_WARHEADS"), "MIRV splits into up to 350 warheads at the aim (SimNukes._split_mirv)")
	H.expect(_has(src, "fx_layer.nuke("), "detonations use upstream FxLayer.nuke")

	H.expect_eq(SimRules.nuke_cost_named("mirv", 0), 25000000.0, "first MIRV is 25M")
	H.expect_eq(SimRules.nuke_cost_named("mirv", 1), 40000000.0, "second MIRV is 40M (+15M step)")
	H.expect(src.find("MIRV_COST_STEP") >= 0 and src.find("mirvs_launched") >= 0, "main.nuke_cost applies MIRV_COST_STEP * mirvs_launched", "")
	H.intentional("ICBM toggle (key I): +10% of the player's bomb price; upstream silos already reach the whole map", "kept custom")
