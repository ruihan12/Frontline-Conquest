# The small ported map modules: WakeRoute, TrailBudget, ViewRules, FrameClock.
#   godot --headless --path . --script tests/test_map_modules.gd
extends SceneTree

var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	var w := 100
	# an L-shaped path: 30 tiles east, then 30 south
	var path := PackedInt32Array()
	for x in range(10, 41): path.append(10 * w + x)
	for y in range(11, 41): path.append(y * w + 40)
	var rs := WakeRoute.runs(path, w)
	_check(rs.size() == 2 and rs[0][1] == 30, "an L is two runs meeting at its corner (%s)" % str(rs))
	var route := WakeRoute.build(path, w, 1.0)
	_check(route.n > 4, "the corner is rounded into pieces (%d points)" % route.n)
	_check(is_equal_approx(route.xs[0], 10.5) and is_equal_approx(route.ys[route.n - 1], 40.5), "the route keeps the path's ends")
	var mono := true
	for i in range(1, route.n):
		if route.ss[i] < route.ss[i - 1] - 1e-4: mono = false
	_check(mono, "distance along the route never runs backwards")
	var mid := WakeRoute.at(route, 30.0)
	_check(mid[0] < 40.5 and mid[1] > 10.5, "at the corner the ship is inside the turn (%.2f, %.2f)" % [mid[0], mid[1]])
	var start := WakeRoute.at(route, 0.0)
	var fin := WakeRoute.at(route, 999.0)
	_check(is_equal_approx(start[0], 10.5) and is_equal_approx(fin[1], 40.5), "before and after the route it sits on the ends")
	# with land inside the corner the curve is tried smaller, until it hugs the path
	var blocked := WakeRoute.build(path, w, 1.0, func(t: int) -> bool: return path.has(t))
	var bmid := WakeRoute.at(blocked, 30.0)
	_check(bmid[0] > mid[0] and bmid[1] < mid[1], "land inside the corner makes a tighter curve (%.2f, %.2f)" % [bmid[0], bmid[1]])
	var none := WakeRoute.build(path, w, 1.0, func(_t: int) -> bool: return false)
	_check(none.n == 3, "with no water at all the corner stays sharp (%d points)" % none.n)
	var st := WakeRoute.build(PackedInt32Array([5 * w + 5, 5 * w + 6, 5 * w + 7]), w, 1.0)
	_check(st.n == 2, "a straight path is one leg")

	_check(TrailBudget.allowance(1) == [160, true], "one munition keeps its whole trail")
	_check(TrailBudget.allowance(100) == [8, false], "a hundred share the budget and lose MIRV rings")
	_check(TrailBudget.allowance(2000)[0] == 0, "past the budget there are no trail dots")

	var rules := SimRules.new()
	ViewRules.use(rules)
	_check(ViewRules.sam_range(1) > 0.0 and ViewRules.sam_range(3) >= ViewRules.sam_range(1), "SAM range grows with level")
	_check(ViewRules.nuke_radii(Defs.N_HYDROGEN).y > ViewRules.nuke_radii(Defs.N_ATOM).y, "a hydrogen bomb is bigger than an atom bomb")
	_check(ViewRules.intercept_p(Defs.N_MIRV) == 0.0, "a MIRV cannot be intercepted")
	_check(ViewRules.range_d2(50 * w + 10, 50 * w + 99, w, 100) < 13.0 * 13.0, "range wraps around the map's edge")
	_check(ViewRules.build_ticks(Defs.S_CITY) > 0, "build times are read from the rules")
	ViewRules.use(null)

	FrameClock.film = {"t": 12.5, "dt": 0.04}
	_check(FrameClock.now() == 12.5 and FrameClock.dt(0.5) == 0.04, "a film steps the clock itself")
	FrameClock.film = {}
	_check(FrameClock.dt(0.5) == 0.5 and FrameClock.now() > 0.0, "otherwise it is the real clock")
	# FxLayer's pure parts
	_check(FxLayer.format_gold(999.0) == "999" and FxLayer.format_gold(12345.0) == "12.3K" and FxLayer.format_gold(2500000.0) == "2.5M", "gold is shortened to K and M")
	var r1 := FxLayer.seeded_random(1234)
	_check(r1 >= 0.0 and r1 < 1.0 and r1 == FxLayer.seeded_random(1234) and r1 != FxLayer.seeded_random(1235), "seeded_random repeats for a seed")
	var plan := FxLayer.debris_plan(5000, 70.0, 1.0)
	_check(plan.size() == 2 + 2 + 1 + 1 and str(plan) == str(FxLayer.debris_plan(5000, 70.0, 1.0)), "an atom bomb leaves 6 debris sprites, the same every time (%d)" % plan.size())
	var far := 0.0
	for d in plan: far = maxf(far, Vector2(d.du, d.dv).length())
	_check(far <= 35.5, "debris stays within half the look radius")
	_check(FxLayer.banner_color(Color(0.1, 0.1, 0.2)).r > 0.3 and FxLayer.banner_color(Color(0.9, 0.5, 0.2)) == Color(0.9, 0.5, 0.2), "a dark banner colour is lifted")
	_check(StructureLayer.icon_scale(1.0) == 0.3 and StructureLayer.icon_scale(3.0) == 1.0 and StructureLayer.icon_scale(14.0) == 2.0 and is_equal_approx(StructureLayer.icon_scale(1.5), 0.5), "structure icons: dots, full size, growing")
	_check(StructureLayer.border_color(Color(0.5, 0.5, 0.5)).is_equal_approx(Color(0.375, 0.375, 0.375)), "border colour is 0.125 darker in lightness")
	# RoadLayer: an L of rail from (10,10) east to (14,10) then south to (14,13)
	var rp := PackedVector2Array([Vector2(10.5, 10.5), Vector2(14.5, 10.5), Vector2(14.5, 13.5)])
	var rt := RoadLayer.tiles_of(rp, 100)
	_check(rt.size() == 8 and rt[0] == 1010 and rt[7] == 1314, "an L of rail passes 8 tiles (%d)" % rt.size())
	var rruns := RoadLayer.build_runs(rt, 100, 12)
	_check(rruns.size() == 2 and rruns[0].x1 == 14 and rruns[1].y1 == 13, "two straight runs meet at the corner")
	var rk := RoadLayer.rail_kinds(rt, 100)
	_check(rk[0] == RoadLayer.H and rk[2] == RoadLayer.H and rk[4] == RoadLayer.BL + 0 or rk[4] == RoadLayer.TR or rk[4] == RoadLayer.TL, "the corner tile is a turn (%d)" % rk[4])
	var rpieces := RoadLayer.build_pieces(rt, 100, 12)
	_check(rpieces.size() == 3 and rpieces[0].kind == RoadLayer.H and rpieces[2].kind == RoadLayer.V, "stretch, turn, stretch (%d pieces)" % rpieces.size())
	_check(RoadLayer.build_runs(RoadLayer.tiles_of(PackedVector2Array([Vector2(0.5, 0.5), Vector2(40.5, 0.5)]), 100), 100, 12).size() == 4, "a long run is cut every 12 tiles")
	# FalloutGlow: hot blocks glow green, cold ones barely, the noise is repeatable, the blur keeps mass
	var gn := FalloutGlow.noise_of(100.5, 100.5, 1.0, 50.0)
	_check(gn == FalloutGlow.noise_of(100.5, 100.5, 1.0, 50.0) and gn[0] >= 0.0 and gn[0] <= 1.0, "block noise repeats and stays in 0..1")
	var hot_c := FalloutGlow.extract(1.0, 50.0, [0.8, 0.7], false, 0.1, 0.1)
	_check(hot_c.a > 0.9 and hot_c.g > hot_c.r and hot_c.g > hot_c.b, "a fresh block glows green (%s)" % str(hot_c))
	_check(FalloutGlow.extract(0.0, 50.0, [0.8, 0.7], false, 0.1, 0.1).a == 0.0, "a cooled block has no glow")
	var src := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0])
	var dst := PackedFloat32Array(); dst.resize(20)
	FalloutGlow.blur_line(src, dst, 0, 1, 5)
	_check(is_equal_approx(dst[8], 0.375) and is_equal_approx(dst[4], 0.25) and is_equal_approx(dst[0], 0.0625), "the 5-tap blur weighs 0.0625 .25 .375 .25 .0625")
	# MapSurface: colour helpers and the border rule
	var dk := MapSurface.darken(Color(0.5, 0.5, 0.5), 0.125)
	_check(dk.is_equal_approx(Color(0.375, 0.375, 0.375)), "darken lowers HSL lightness by 0.125")
	_check(MapSurface.saturate(Color(1, 0, 0), 0.0).is_equal_approx(Color(0.299, 0.299, 0.299)), "saturation 0 is the luma grey")
	_check(is_equal_approx(MapSurface.contrast(0.5, 1.25), 0.5) and MapSurface.contrast(0.9, 1.25) > 0.9 and MapSurface.contrast(0.1, 1.25) < 0.1, "contrast x1.25 about mid-grey")
	var hsl := MapSurface.rgb_to_hsl(Color(0.2, 0.6, 0.4))
	_check(MapSurface.hsl_to_rgb(hsl.x, hsl.y, hsl.z).is_equal_approx(Color(0.2, 0.6, 0.4)), "rgb -> hsl -> rgb round trip")
	print("MAP_MODULES_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(0 if fails == 0 else 1)
