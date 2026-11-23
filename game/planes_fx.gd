extends "res://game/draw_helpers.gd"
# World effects and notes (cargo/transport planes are not in vanilla / upstream)

func _airfields_of(o: int) -> Array:
	var out := []
	for st in structs:
		if st.k == 14 and st.o == o and float(st.get("bt", 0.0)) <= 0.0: out.append(st)
	return out

func _tile_px(t: int) -> Vector2:
	return Vector2(t % W + 0.5, t / W + 0.5) * TS

func _air_path(t0: int, t1: int) -> Array:
	var pts := PackedVector2Array([_tile_px(t0), _tile_px(t1)])
	return [pts, PackedFloat32Array([0.0, pts[0].distance_to(pts[1])])]

# Vanilla: cargo / transport planes are not in upstream RoWorld. Stubs only.
func launch_plane(_a: int, _click: int, _share: float) -> bool:
	return false

func _tick_air_cargo(_dt: float) -> void:
	return

func _plane_glyph(p: Vector2, dir: Vector2, col: Color, scale: float, cargo: bool) -> void:
	var s := clampf(cam.zoom.x * 3.0, 6.0, 13.0) * scale
	var nrm := Vector2(-dir.y, dir.x)
	var sh := Vector2(2, 3)
	var body := PackedVector2Array([p + dir * s * 1.2, p + nrm * s * 0.18, p - dir * s * 0.9 + nrm * s * 0.12, p - dir * s, p - dir * s * 0.9 - nrm * s * 0.12, p - nrm * s * 0.18])
	var wing := PackedVector2Array([p + dir * s * 0.25, p - dir * s * 0.35 + nrm * s * 1.0, p - dir * s * 0.55 + nrm * s * 0.95, p - dir * s * 0.1, p - dir * s * 0.55 - nrm * s * 0.95, p - dir * s * 0.35 - nrm * s * 1.0])
	var tail := PackedVector2Array([p - dir * s * 0.75, p - dir * s * 1.05 + nrm * s * 0.45, p - dir * s * 1.15, p - dir * s * 1.05 - nrm * s * 0.45])
	for poly in [wing, body, tail]:
		var sp := PackedVector2Array()
		for v in poly: sp.append(v + sh)
		overlay.draw_colored_polygon(sp, Color(0, 0, 0, 0.28))
	var base: Color = GOLD_C.darkened(0.1) if cargo else Color(0.92, 0.94, 0.98)
	overlay.draw_colored_polygon(wing, base)
	overlay.draw_colored_polygon(tail, base)
	overlay.draw_colored_polygon(body, col.lightened(0.15))
	overlay.draw_polyline(body + PackedVector2Array([body[0]]), Color(0.05, 0.07, 0.12, 0.9), 1.0)

var _capfx_idx := PackedInt32Array()
func _draw_capture_fx() -> void:
	if cap_fx.is_empty(): return
	var dur := 0.7
	var tz := TS * cam.zoom.x
	var vr := Rect2(Vector2(-tz, -tz), get_viewport_rect().size + Vector2(tz, tz) * 2)
	# (perf) one triangle-array command for all flashes instead of a draw_rect each (up to CAP_FX_MAX
	# a frame during the land grab); same quads, colours and order
	var xf := get_canvas_transform()
	var Wl := W
	var tsl: float = TS
	var now: float = map_t
	var dead := PackedInt32Array()
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	var d := Vector2(tz, tz)
	var dx := Vector2(tz, 0.0)
	var dy := Vector2(0.0, tz)
	for i: int in cap_fx:
		var e: Array = cap_fx[i]
		var u: float = (now - float(e[0])) / dur
		if u >= 1.0: dead.append(i); continue
		var p: Vector2 = xf * (Vector2(i % Wl, i / Wl) * tsl)
		if not vr.has_point(p): continue
		var c: Color = e[1]
		var k := 1.0 - u
		var cc := Color(c.lightened(0.55 * k), 0.6 * k * k)
		pts.append(p); pts.append(p + dx); pts.append(p + d)
		pts.append(p); pts.append(p + d); pts.append(p + dy)
		for _v in 6: cols.append(cc)
	for i in dead: cap_fx.erase(i)
	if pts.is_empty(): return
	var n := pts.size()
	if _capfx_idx.size() < n:
		var m0 := _capfx_idx.size()
		_capfx_idx.resize(n)
		for j in range(m0, n): _capfx_idx[j] = j
	RenderingServer.canvas_item_add_triangle_array(overlay.get_canvas_item(), _capfx_idx.slice(0, n), pts, cols)

func _world_fx_anim(z: float) -> void:
	pass

func _draw_world_fx(z: float) -> void:
	var _c0 := Time.get_ticks_usec()
	_pf_add("w_cap", Time.get_ticks_usec() - _c0); _c0 = Time.get_ticks_usec()
	_draw_meta_fx(z)
	_pf_add("w_meta", Time.get_ticks_usec() - _c0)
	# railways: factories to nearby owned/allied cities, ports, and factories
	var drawn_rails := {}
	var rail_edges := []
	var vr := Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size).grow(FACTORY_RANGE * 2.0 * TS * z)
	for st in structs:
		if not (st.k in RAIL_KINDS) or st.get("bt", 0.0) > 0.0: continue
		if not vr.has_point(_screen_of(Vector2(st.tile % W + 0.5, st.tile / W + 0.5) * TS)): continue
		var nbrs := _rail_neighbors(st)
		for c in nbrs:
			var rkey := "%d:%d" % [mini(st.tile, c.tile), maxi(st.tile, c.tile)]
			if drawn_rails.has(rkey): continue
			drawn_rails[rkey] = true
			if client != null:
				rail_edges.append([st.tile, c.tile])
				continue
			var rcol := GOLD_C if c.o != st.o else Color(0.95, 0.95, 0.98, 0.88)
			_draw_railway(st, c, rcol)
	if client != null:
		# railroads, coloured by the land under them: client/map/road_layer.gd
		if road_layer == null: road_layer = RoadLayer.new(self)
		road_layer.draw(overlay, rail_edges)
	_pf_add("w_rail", Time.get_ticks_usec() - _c0)
	# moving gold trains strictly following the drawn canonical railway tracks
	for tr in ([] if client != null else trains):
		if not _has_rail_link(tr.src, tr.dst): continue
		var f: float = clampf((tr.t + tick_acc * 10.0) / maxf(0.01, tr.dur), 0.0, 1.0)
		var rp := _rail_pos(tr.src, tr.dst, f)
		var sp := _screen_of(rp[0] * TS)
		var dir: Vector2 = rp[1]
		var tot_tiles: float = rp[2]
		var nrm := Vector2(-dir.y, dir.x)
		var col: Color = nations[tr.o].color
		# cargo car follows the track behind the locomotive
		var f_car: float = clampf(f - 2.6 / maxf(4.0, tot_tiles), 0.0, 1.0)
		var rp_car := _rail_pos(tr.src, tr.dst, f_car)
		var car_c := _screen_of(rp_car[0] * TS)
		var cdir: Vector2 = rp_car[1]
		var cnrm := Vector2(-cdir.y, cdir.x)
		overlay.draw_line(sp, car_c, Color(0.1, 0.1, 0.14), 2.0)
		var car := PackedVector2Array([car_c + cdir * 3.5 + cnrm * 3.2, car_c - cdir * 3.5 + cnrm * 3.2, car_c - cdir * 3.5 - cnrm * 3.2, car_c + cdir * 3.5 - cnrm * 3.2])
		if not _unit_sprite(car_c, 11, GOLD_C, 11.0, cdir.angle()):
			overlay.draw_colored_polygon(car, GOLD_C.darkened(0.1))
		var qq := _q()
		if qq >= 1:
			var f_car2: float = clampf(f - 5.0 / maxf(4.0, tot_tiles), 0.0, 1.0)
			var rp2 := _rail_pos(tr.src, tr.dst, f_car2)
			var c2 := _screen_of(rp2[0] * TS); var d2: Vector2 = rp2[1]; var n2 := Vector2(-d2.y, d2.x)
			overlay.draw_line(car_c, c2, Color(0.1, 0.1, 0.14), 2.0)
			overlay.draw_colored_polygon(PackedVector2Array([c2 + d2 * 3.5 + n2 * 3.2, c2 - d2 * 3.5 + n2 * 3.2, c2 - d2 * 3.5 - n2 * 3.2, c2 + d2 * 3.5 - n2 * 3.2]), col.darkened(0.15))
		if qq >= 2:
			var np_: int = 4 if qq == 2 else 8
			for k in np_:
				var ph := fmod(map_t * 1.3 + float(k) / np_ + float(hash(tr.src) % 97) * 0.37, 1.0)
				var sp_p := sp + dir * 2.0 - dir * ph * 16.0 + Vector2(0, -ph * 10.0) + nrm * sin(ph * 6.0 + k) * 2.0
				overlay.draw_circle(sp_p, 1.6 + ph * 3.6, Color(0.92, 0.92, 0.95, 0.5 * (1.0 - ph)))
		# locomotive
		var loco := PackedVector2Array([sp + dir * 7, sp + dir * 3 + nrm * 4, sp - dir * 6 + nrm * 4, sp - dir * 6 - nrm * 4, sp + dir * 3 - nrm * 4])
		if not _unit_sprite(sp, 9, col, 12.0, dir.angle()):
			overlay.draw_colored_polygon(loco, col.lightened(0.15))
			overlay.draw_polyline(loco + PackedVector2Array([loco[0]]), Color(0.08, 0.08, 0.12), 1.5)
			overlay.draw_circle(sp + dir * 2, 2.2, GOLD_C)
	if client != null:
		# structure plates, level numbers and progress bars: client/map/structure_layer.gd
		if struct_layer == null: struct_layer = StructureLayer.new(self)
		struct_layer.draw(overlay)
		# ships, wakes, trains, shells and SAM missiles: client/map/unit_layer.gd
		if unit_layer == null: unit_layer = UnitLayer.new(self)
		unit_layer.draw(overlay)
		client.ctx.world.draw_markers(overlay)  # the spawn ring (client/map/map_view.gd)
	for st in ([] if client != null else structs):
		var t: int = st.tile
		var sp := _screen_of(Vector2(t % W + 0.5, t / W + 0.5) * TS)
		var bt: float = st.get("bt", 0.0)
		var cd: float = float(st.get("cd", 0.0))
		_map_icon(sp, st.k, nations[st.o].color, 0.55 if bt > 0.0 else 1.0)
		if bt > 0.0:
			var bmax: float = maxf(0.01, float(st.get("bmax", 2.0)))
			var prog: float = clampf(1.0 - bt / bmax, 0.0, 1.0)
			overlay.draw_arc(sp, 12.5, -PI / 2, -PI / 2 + TAU * prog, 24, ORANGE_Y, 2.6, true)
		elif cd > 0.0 and st.k in [4, 5, 14, 15]:
			var cmax: float = maxf(0.1, float(st.get("cmax", 9.0)))
			var rprog: float = clampf(1.0 - cd / cmax, 0.0, 1.0)
			var ccol := CYAN if st.k == 14 else RED
			overlay.draw_arc(sp, 12.0, 0, TAU, 24, Color(0, 0, 0, 0.55), 2.8, true)
			overlay.draw_arc(sp, 12.0, -PI / 2, -PI / 2 + TAU * rprog, 24, ccol, 2.4, true)
		var lvl := int(st.get("level", 1))
		if lvl > 1:
			var badge_p := sp + Vector2(6, -11)
			overlay.draw_rect(Rect2(badge_p, Vector2(22, 12)), Color(0.06, 0.08, 0.15, 0.92))
			overlay.draw_rect(Rect2(badge_p, Vector2(22, 12)), GOLD_C, false, 1.0)
			f_bold.draw_string(overlay.get_canvas_item(), badge_p + Vector2(2, 10), "Lv%s" % _fmt_hud(float(lvl)), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, GOLD_C)
	# trade ships: clear gold-hulled cargo ships with wake and sea-lane line (with smooth heading interpolation)
	for tr in ([] if client != null else traders):
		var bp := _boat_pos(tr)
		var p0 := _screen_of(bp[0])
		if p0.x < -40 or p0.y < -40 or p0.x > 1640 or p0.y > 940: continue
		var raw_dir: Vector2 = bp[1]
		if raw_dir == Vector2.ZERO: raw_dir = Vector2.RIGHT
		var dir: Vector2 = _sdir(tr, raw_dir)
		var nrm := Vector2(-dir.y, dir.x)
		var ocol: Color = nations[tr.o].color if (tr.o > 0 and tr.o < nations.size()) else GOLD_C
		if tr.get("air", false):
			_plane_glyph(p0, dir, ocol, 0.85, true); continue
		_wake_trail(tr, bp[0], maxf(1.4, _ship_px(true) * 0.24))
		if _ship_sprite(p0, 1, ocol, true): continue  # old look: no chevron wake on trade ships
		_wake(p0, dir, 6.0 * SHIP_CIVIL_SCALE)
		overlay.draw_line(p0 - dir * 10.5, p0 - dir * 3.0, Color(1, 1, 1, 0.55), 2.2)
		var hull := PackedVector2Array([
			p0 + dir * 7.5,
			p0 + dir * 2.5 + nrm * 3.8,
			p0 - dir * 6.5 + nrm * 3.4,
			p0 - dir * 6.5 - nrm * 3.4,
			p0 + dir * 2.5 - nrm * 3.8
		])
		overlay.draw_colored_polygon(hull, GOLD_C.darkened(0.22))
		overlay.draw_polyline(hull + PackedVector2Array([hull[0]]), Color(0.10, 0.08, 0.04, 0.95), 1.4)
		overlay.draw_circle(p0 + dir * 1.5, 2.3, GOLD_C.lightened(0.25))
		overlay.draw_circle(p0 - dir * 2.8, 2.0, ocol.lightened(0.15))
	# warships
	for ws in ([] if client != null else warships):
		var dp: Vector2 = ws.get("dp", ws.pos)
		var mv: Vector2 = ws.pos - dp
		dp = ws.pos if _q() == 0 or mv.length() > 6.0 else dp + mv * clampf(1.0 - exp(-8.0 * get_process_delta_time()), 0.0, 1.0)
		ws["dp"] = dp
		var p := _screen_of(dp * TS)
		var col: Color = nations[ws.o].color
		_wake_trail(ws, dp * TS, maxf(1.8, _ship_px() * 0.3))
		if sel_ws != null and is_same(sel_ws, ws):
			overlay.draw_arc(p, 15.0, 0, TAU, 32, Color(1, 1, 1, 0.9), 2.0, true)
			if ws.tgt.distance_to(ws.pos) > 1.5:
				var tp := _screen_of(ws.tgt * TS)
				overlay.draw_arc(tp, 6.0, 0, TAU, 20, Color(1, 1, 1, 0.8), 1.6, true)
				overlay.draw_circle(tp, 2.0, Color(1, 1, 1, 0.8))
		var hd := _sdir(ws, mv if mv.length() > 0.02 else Vector2.ZERO)
		var hn := Vector2(-hd.y, hd.x)
		if _ship_sprite(p, 2, col):  # old look: no wake on warships
			if ws.vet > 0:
				var hs := _ship_px() * 0.5
				for v in ws.vet: overlay.draw_circle(p + Vector2(-8 + v * 4, -hs - 3), 1.6, GOLD_C)
			continue
		if mv.length() > 0.02: _wake(p, hd, 7.0)
		var hull := PackedVector2Array([p + hd * 11 + hn * 0, p + hd * 6 + hn * 4, p - hd * 9 + hn * 4, p - hd * 10, p - hd * 9 - hn * 4, p + hd * 6 - hn * 4])
		overlay.draw_colored_polygon(hull, col.darkened(0.2))
		overlay.draw_colored_polygon(PackedVector2Array([p + hd * 3 + hn * 2.5, p - hd * 4 + hn * 2.5, p - hd * 4 - hn * 2.5, p + hd * 3 - hn * 2.5]), col.lightened(0.3))
		overlay.draw_polyline(hull + PackedVector2Array([hull[0]]), col.darkened(0.6), 1.5)
		if ws.vet > 0:
			for v in ws.vet: overlay.draw_circle(p + Vector2(-8 + v * 4, -12), 1.6, GOLD_C)
	# nukes: upstream UnitLayer (trail, sprite, target ring), client/map/unit_layer.gd draw_nukes
	if unit_layer == null: unit_layer = UnitLayer.new(self)
	unit_layer.draw_nukes(overlay)
	var rw_fx := _qual() >= 2
	if rw_fx: _draw_rw_blasts(z)
	for b in ([] if rw_fx else blasts):
		var bdur: float = maxf(0.2, float(b.get("dur", 1.35)))
		var u: float = clampf(b.t / bdur, 0.0, 1.0)
		var sp := _screen_of(b.pos)
		var rad: float = maxf(8.0, float(b.r) * z)
		var bseed: int = int(b.get("seed", 1337))
		# 1. Persistent ground scorch & glowing magma crater ring
		var scorch_a: float = clampf((1.0 - u) * 0.78, 0.0, 0.78)
		overlay.draw_circle(sp, rad * 0.72, Color(0.08, 0.06, 0.05, scorch_a * 0.75))
		overlay.draw_arc(sp, rad * 0.62, 0, TAU, 36, Color(0.95, 0.32, 0.08, scorch_a * 0.85), maxf(1.8, rad * 0.08), true)
		# 2. Multi-layered rolling fireball core that cools into billowing ash/smoke puffs
		var fb_prog: float = pow(u, 0.36)
		var fb_r: float = rad * (0.28 + 0.68 * fb_prog)
		var core_a: float = clampf(1.0 - pow(u, 1.25), 0.0, 1.0)
		# Perimeter smoke/fire puffs (8 deterministic puffs around the fireball)
		for m in 8:
			var ang: float = float(m) * TAU / 8.0 + float((bseed >> (m % 6)) & 7) * 0.18 + u * 0.55
			var pd: float = fb_r * (0.58 + 0.28 * float((bseed >> ((m + 3) % 7)) & 3) / 3.0)
			var pr: float = fb_r * (0.26 + 0.12 * sin(float(m * 3 + bseed)))
			var puff_p: Vector2 = sp + Vector2.from_angle(ang) * pd
			var puff_col := Color(0.95, 0.38, 0.10, core_a * 0.75).lerp(Color(0.20, 0.18, 0.17, core_a * 0.68), clampf((u - 0.25) * 1.4, 0.0, 1.0))
			overlay.draw_circle(puff_p, maxf(2.0, pr), puff_col)
		# Outer crimson-orange plasma fireball
		overlay.draw_circle(sp, fb_r * 0.88, Color(0.96, 0.30, 0.08, core_a * 0.72).lerp(Color(0.24, 0.21, 0.19, core_a * 0.55), clampf((u - 0.40) * 1.6, 0.0, 1.0)))
		# Mid bright gold-orange plasma core
		if u < 0.78:
			var mid_a: float = clampf(1.0 - u / 0.78, 0.0, 1.0)
			overlay.draw_circle(sp, fb_r * 0.58, Color(1.0, 0.68, 0.18, mid_a * 0.85))
			overlay.draw_circle(sp, fb_r * 0.32, Color(1.0, 0.95, 0.72, mid_a * 0.92))
		# 3. Initial blinding white-hot thermal flash (u < 0.22)
		if u < 0.22:
			var fl_a: float = clampf(1.0 - u / 0.22, 0.0, 1.0)
			overlay.draw_circle(sp, rad * (0.65 + 0.55 * (u / 0.22)), Color(1.0, 0.98, 0.88, fl_a * 0.82))
		# 4. Dual supersonic shockwave rings (primary outer white/amber wave + secondary pressure wave)
		var sw1_r: float = rad * (0.25 + 1.25 * pow(u, 0.45))
		var sw1_a: float = clampf((1.0 - u) * 0.92, 0.0, 1.0)
		overlay.draw_arc(sp, maxf(3.0, sw1_r), 0, TAU, 56, Color(1.0, 0.88, 0.62, sw1_a), maxf(2.0, 3.8 * (1.0 - u * 0.6)), true)
		if u > 0.06:
			var u2: float = clampf((u - 0.06) / 0.94, 0.0, 1.0)
			var sw2_r: float = rad * (0.20 + 0.98 * pow(u2, 0.62))
			var sw2_a: float = clampf((1.0 - u2) * 0.72, 0.0, 1.0)
			overlay.draw_arc(sp, maxf(2.5, sw2_r), 0, TAU, 48, Color(1.0, 0.50, 0.18, sw2_a), maxf(1.5, 2.6 * (1.0 - u2 * 0.5)), true)
		# 5. Radial debris / ember sparks streaking outward
		if u < 0.82:
			var sp_a: float = clampf(1.0 - u / 0.82, 0.0, 1.0)
			var sp_prog: float = pow(u / 0.82, 0.52)
			var nsp: int = [6, 12, 20, 32][_q()]
			for s_i in nsp:
				var sang: float = float(s_i) * TAU / float(nsp) + float((bseed >> (s_i % 8)) & 15) * 0.09
				var spd_mult: float = 0.75 + 0.55 * float((bseed >> ((s_i + 2) % 9)) & 7) / 7.0
				var r_out: float = rad * (0.25 + 1.15 * sp_prog * spd_mult)
				var r_in: float = maxf(2.0, r_out - rad * 0.18 * (1.0 - 0.5 * sp_prog))
				var dir_v := Vector2.from_angle(sang)
				overlay.draw_line(sp + dir_v * r_in, sp + dir_v * r_out, Color(1.0, 0.78, 0.28, sp_a * 0.90), 1.8)
				overlay.draw_circle(sp + dir_v * r_out, 1.6, Color(1.0, 0.95, 0.75, sp_a))
	if _q() >= 2 and not rw_fx:
		for b in blasts:
			var bd: float = maxf(0.2, float(b.get("dur", 1.35)))
			var u2: float = clampf(b.t / bd, 0.0, 1.0)
			if u2 < 0.15: continue
			var sp2 := _screen_of(b.pos); var rd: float = maxf(8.0, float(b.r) * z)
			var ns: int = 6 if _q() == 2 else 12
			var bs: int = int(b.get("seed", 7))
			for k in ns:
				var v := (u2 - 0.15) / 0.85
				var ang := float(k) * TAU / ns + float((bs >> (k % 7)) & 3) * 0.4
				var pp := sp2 + Vector2.from_angle(ang) * rd * (0.3 + 0.5 * v) + Vector2(0, -rd * 0.7 * v * (0.6 + 0.1 * (k % 4)))
				overlay.draw_circle(pp, rd * (0.12 + 0.22 * v), Color(0.28, 0.26, 0.25, 0.42 * (1.0 - v)))
	for s2 in shells:
		var sp := _screen_of(s2.pos)
		overlay.draw_circle(sp, 3 + s2.t * 10, Color(1, 0.6, 0.2, 0.7 * (1.0 - s2.t / 0.5)))
	for fl in floats:
		var a: float = clampf(1.0 - fl.t / 1.4, 0.0, 1.0)
		var sp := _screen_of(fl.pos) - Vector2(0, fl.t * 22.0)
		f_bold.draw_string_outline(overlay.get_canvas_item(), sp + Vector2(-30, 0), fl.text, HORIZONTAL_ALIGNMENT_CENTER, 60, 13, 3, Color(0, 0, 0, 0.85 * a))
		f_bold.draw_string(overlay.get_canvas_item(), sp + Vector2(-30, 0), fl.text, HORIZONTAL_ALIGNMENT_CENTER, 60, 13, Color(fl.col.r, fl.col.g, fl.col.b, a))

func _rw_frame(tex: Texture2D, kind: String, fr: int, center: Vector2, px: float, mod := Color.WHITE) -> void:
	var d: Array = RW_FX[kind]
	var up := 4.0
	var src := Rect2(fr * d[1] * up, d[0] * up, d[1] * up, d[2] * up)
	var sz := Vector2(d[1], d[2]) * px
	overlay.draw_texture_rect_region(tex, Rect2(center - sz * 0.5, sz), src, mod)

func _draw_rw_blasts(z: float) -> void:
	var tex := _tex("map_fx/map_fx.png", 4)
	for b in blasts:
		var sp := _screen_of(b.pos)
		var rad: float = maxf(6.0, float(b.r) * z)
		var t: float = b.t
		var kind: String = b.get("kind", "nuke")
		if tex == null:
			overlay.draw_circle(sp, rad * 0.6, Color(1, 0.6, 0.2, clampf(1.0 - t, 0.0, 1.0))); continue
		if kind == "sam":
			var fr := int(t / 0.08)
			if fr < 9: _rw_frame(tex, "sam", fr, sp, maxf(1.0, rad * 2.0 / 40.0))
			continue
		var dur: float = float(b.get("dur", 6.0))
		var tile_px := rad / maxf(1.0, float(b.r) / TS)   # screen px per map tile
		var px := rad * 2.4 / 60.0                          # sprite pixel size: explosion ~2.4x the blast radius wide
		# debris (under the fireball once it has burnt down)
		var u := t / dur
		var fade := clampf(u / 0.1, 0.0, 1.0) * clampf((1.0 - u) / 0.2, 0.0, 1.0)
		if fade > 0.0 and t > 0.35:
			var bs: int = int(b.get("seed", 1))
			var area := PI * pow(float(b.r) / TS * 0.5, 2.0)
			var plan := [["fire", 1.0 / 25.0], ["smoke", 1.0 / 28.0], ["big_smoke", 1.0 / 70.0], ["smoke_fire", 1.0 / 70.0]]
			var k := 0
			for pl in plan:
				var cnt := maxi(1, int(round(area * float(pl[1]) * 3.0)))
				var d: Array = RW_FX[pl[0]]
				for m in cnt:
					k += 1
					var hh := absi(int(bs * 0x9E37 + k * 0x85EB)) 
					var ang := float(hh % 1000) / 1000.0 * TAU
					var rr := sqrt(float((hh / 1000) % 1000) / 1000.0) * rad * 0.5
					var fr := (int(t / float(d[4])) + hh % 7) % int(d[3])
					_rw_frame(tex, pl[0], fr, sp + Vector2.from_angle(ang) * rr, maxf(0.6, tile_px * 0.5), Color(1, 1, 1, fade))
		var fr2 := int(t / 0.07)
		if fr2 < 12: _rw_frame(tex, "nuke", fr2, sp, px)
		if t < 1.5:
			var su := t / 1.5
			overlay.draw_arc(sp, rad * 1.5 * pow(su, 0.6), 0, TAU, 64, Color(1, 1, 1, 0.85 * (1.0 - su)), maxf(1.0, 2.0 * (1.0 - su)), true)

func _draw_notes() -> void:
	var y := 0.0
	for nt in notes:
		var a := clampf((7.0 - nt.t) / 0.6, 0.0, 1.0) * clampf(nt.t / 0.15, 0.0, 1.0)
		var lines := _wrap(nt.text, f_bold, 15, 290)
		var h := 22.0 + lines.size() * 20.0
		var r := Rect2(0, y, 370, h)
		note_box.draw_style_box(_flat(Color(0.07, 0.085, 0.15, 0.94 * a), 5, Color(1, 1, 1, 0.08 * a), 1), r)
		note_box.draw_rect(Rect2(0, y, 4, h), Color(nt.col, a))
		var c := Vector2(30, y + h / 2)
		note_box.draw_circle(c, 13, Color(nt.col, 0.18 * a))
		note_box.draw_arc(c, 13, 0, TAU, 24, Color(nt.col, 0.6 * a), 1.5, true)
		match nt.kind:
			"good":
				note_box.draw_polyline(PackedVector2Array([c + Vector2(-6, 0), c + Vector2(-2, 4), c + Vector2(6, -5)]), Color(nt.col, a), 2.2)
			"bad":
				note_box.draw_rect(Rect2(c + Vector2(-1.2, -7), Vector2(2.4, 9)), Color(nt.col, a))
				note_box.draw_circle(c + Vector2(0, 5.5), 1.5, Color(nt.col, a))
			_:
				note_box.draw_circle(c + Vector2(0, -5), 1.5, Color(nt.col, a))
				note_box.draw_rect(Rect2(c + Vector2(-1.2, -2), Vector2(2.4, 8)), Color(nt.col, a))
		var ly := y + 11 + 15
		for ln in lines:
			f_bold.draw_string(note_box.get_canvas_item(), Vector2(56, ly), ln, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(TEXT, a))
			ly += 20
		y += h + 8

