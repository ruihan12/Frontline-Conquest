extends "res://game/state.gd"

const ConquestBorders = preload("res://sim/conquest_borders.gd")
# Map generation, rendering data, tiles and ownership

## Phones and tablets: the window fills the whole screen (stretch aspect "expand") at a touch-friendly scale
## instead of a letterboxed 16:9 strip. The UI lays itself out from the real viewport size (client_hud.gd layout()).
const PHONE_SHORT_SIDE_MIN := 400.0
const PHONE_SHORT_SIDE_MAX := 600.0
# held upright the phone strip (numbers, attack bar, Build) needs about 540 logical px of width
const PHONE_PORTRAIT_MIN := 540.0


func _fit_viewport() -> void:
	var w := get_window()
	if w == null:
		return
	w.size_changed.connect(_fit_scale)
	_fit_scale()


## CSS px of the browser window's short side on a touch device, or 0 on anything else.
func _touch_short_css() -> float:
	if OS.has_feature("web"):
		var v = JavaScriptBridge.eval("((navigator.maxTouchPoints||0)>0 && matchMedia('(pointer:coarse)').matches) ? Math.min(window.innerWidth, window.innerHeight) : 0", true)
		return float(v) if v != null else 0.0
	if OS.has_feature("mobile"):
		return minf(DisplayServer.screen_get_size().x, DisplayServer.screen_get_size().y) / maxf(1.0, DisplayServer.screen_get_scale())
	return 0.0


func _fit_scale() -> void:
	var w := get_window()
	var px := Vector2(w.size)
	if w == null or px.x < 10.0 or px.y < 10.0:
		return
	var css := _touch_short_css()
	if css <= 0.0:
		w.content_scale_factor = 1.0
		return
	var lo := PHONE_PORTRAIT_MIN if px.y > px.x else PHONE_SHORT_SIDE_MIN
	var target := clampf(css, lo, PHONE_SHORT_SIDE_MAX)  # logical px on the short side
	var base := minf(px.x / float(w.content_scale_size.x), px.y / float(w.content_scale_size.y))
	w.content_scale_factor = (minf(px.x, px.y) / target) / base

func _ready() -> void:
	if "--sim-worker-attacks" in OS.get_cmdline_user_args():
		_attack_worker = AttackWorker.new()
		_attack_worker.prepare_ai_scans = "--sim-worker-ai-scan" in OS.get_cmdline_user_args()
	if "--sim-worker-economy" in OS.get_cmdline_user_args():
		_economy_worker = EconomyWorker.new()
	if "--sim-worker-naval" in OS.get_cmdline_user_args():
		_naval_worker = NavalWorker.new()
	if _attack_worker != null or _economy_worker != null or _naval_worker != null or "--sim-queued-intents" in OS.get_cmdline_user_args():
		sim_intents = SimIntentQueue.new()
	if "--sim-snapshot" in OS.get_cmdline_user_args():
		tile_snapshot = TileSnapshot.new()
	_fit_viewport()
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	autoshot = "--autoshot" in OS.get_cmdline_user_args()
	_sfx_log = "--sfxlog" in OS.get_cmdline_user_args()
	bench = "--bench" in OS.get_cmdline_user_args()
	for x in OS.get_cmdline_user_args():
		if x.begins_with("--pace="): _pace = {"init": true}
	rng.randomize()
	for x in OS.get_cmdline_user_args():
		if x == "--server" or x == "--hostlocal" or x.begins_with("--connect="):
			call_deferred("_net_boot")  # defined in main.gd
	if autoshot or bench: save_path = "user://save_test.json"
	Engine.max_fps = 0  # uncapped
	load_save()
	RenderingServer.set_default_clear_color(Color(0.20, 0.42, 0.62))
	if autoshot: Engine.time_scale = 4.0
	# map split into chunk textures; only dirty chunks are uploaded each frame
	_rebuild_chunks()
	cam = Camera2D.new()
	add_child(cam)
	cam.position = Vector2(W, H) * TS / 2
	cam.zoom = Vector2(1.2, 1.2)
	_build_ui()
	set_icbm(bool(save.get("settings", {}).get("icbm", false)))
	ui.layer = 2
	var ol := CanvasLayer.new(); ol.layer = 1; add_child(ol)
	overlay = Control.new(); overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ol.add_child(overlay)
	overlay.draw.connect(_draw_overlay)
	if client != null:
		fx_layer = FxLayer.new(self, client.ctx.state)
		ol.add_child(fx_layer)
		names = NameLayer.new(self, client.ctx.state)
		ol.add_child(names)
		fronts = FrontLayer.new(self)
		ol.add_child(fronts)
		ranges = RangeLayer.new(self, client.ctx.state)
		ol.add_child(ranges)
		ol.move_child(ranges, 0)
		surface = MapSurface.new(self)
		fallout_glow = FalloutGlow.new(self)
		ol.add_child(fallout_glow)
		ol.move_child(fallout_glow, 0)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="): shots_dir = a.substr(8)
	gen_map()
	sim_atk = SimAttacks.new(self, sim_rules)
	sim_ai = SimAI.new(self, sim_rules)
	_tick_stage = 0
	sim_struct = SimStructures.new(self, sim_rules)
	sim_ars = SimArsenal.new(self, sim_rules)
	sim_ws = SimWarships.new(self, sim_rules)
	apply_settings(false)
	_init_audio()
	if "--maptest" in OS.get_cmdline_user_args(): _maptest.call_deferred()
	if "--rangetest" in OS.get_cmdline_user_args(): _rangetest.call_deferred()
	if "--rangetest2" in OS.get_cmdline_user_args(): _rangetest2.call_deferred()
	if "--idletest" in OS.get_cmdline_user_args(): _idletest.call_deferred()
	if "--bordershot" in OS.get_cmdline_user_args(): _bordershot.call_deferred()
	if "--stress" in OS.get_cmdline_user_args(): _stress.call_deferred()
	if "--hudshot" in OS.get_cmdline_user_args(): _hudshot.call_deferred()
	if "--uishot" in OS.get_cmdline_user_args(): _uishot.call_deferred()
	if "--dmgshot" in OS.get_cmdline_user_args(): _dmgshot.call_deferred()
	if "--shipshot" in OS.get_cmdline_user_args(): _shipshot.call_deferred()
	if "--audiotest" in OS.get_cmdline_user_args(): _audiotest.call_deferred()
	if "--regress" in OS.get_cmdline_user_args(): _regress.call_deferred()
	if "--porttest" in OS.get_cmdline_user_args(): _porttest.call_deferred()
	if "--portshot" in OS.get_cmdline_user_args(): _portshot.call_deferred()
	if "--speedshot" in OS.get_cmdline_user_args(): _speedshot.call_deferred()
	if _want_webprof(): _webprof_start.call_deferred()
	if _want_perfstart(): _perf_autostart.call_deferred()
	if "--hudfit" in OS.get_cmdline_user_args(): _hudfit.call_deferred()

func _map_material() -> ShaderMaterial:
	if map_mat == null:
		var sh := Shader.new(); sh.code = MAP_SHADER
		map_mat = ShaderMaterial.new(); map_mat.shader = sh
	return map_mat

func _sample_map_elev(k: int, x: float, y: float, n: FastNoiseLite, n2: FastNoiseLite, pa := INF, pb := INF) -> float:
	var m = MAPS[clampi(k, 0, MAPS.size() - 1)]
	var dx := (x - W / 2.0) / (W / 2.0)
	var dy := (y - H / 2.0) / (H / 2.0)
	var r2 := dx * dx + dy * dy
	var nx := x * 640.0 / W; var ny := y * 640.0 / W
	var va: float = pa if pa != INF else n.get_noise_2d(nx, ny)
	var vb: float = pb if pb != INF else n2.get_noise_2d(nx, ny)
	var nv: float = va + vb * (0.08 + float(m[2]))
	var shape := 0.25 - 0.35 * r2 - float(m[2])
	match k:
		1:  # Twin Continents: West & East landmasses separated by a central strait
			var d1 := (dx + 0.48) * (dx + 0.48) * 1.8 + dy * dy * 1.1
			var d2 := (dx - 0.48) * (dx - 0.48) * 1.8 + dy * dy * 1.1
			shape = 0.30 - minf(d1, d2) * 0.52 - exp(-dx * dx * 32.0) * 0.28
		2:  # Shattered Sea: Archipelago of island chains
			shape = 0.14 - 0.26 * r2 + 0.18 * sin(dx * 7.5) * cos(dy * 6.5)
		3:  # World Continents: Americas left, Eurasia + Africa right
			var amer := exp(-pow((dx + 0.52 + 0.12 * dy) / 0.26, 2.0) - pow(dy / 0.78, 2.0)) * 0.58
			var eura := exp(-pow((dx - 0.36) / 0.46, 2.0) - pow((dy + 0.26) / 0.48, 2.0)) * 0.62
			var afri := exp(-pow((dx - 0.14) / 0.24, 2.0) - pow((dy - 0.34) / 0.44, 2.0)) * 0.56
			var austr := exp(-pow((dx - 0.66) / 0.18, 2.0) - pow((dy - 0.55) / 0.20, 2.0)) * 0.48
			shape = maxf(maxf(amer, eura), maxf(afri, austr)) - 0.30 - 0.12 * r2
		4:  # Mediterranean: Land ring around a central elongated sea with peninsulas
			var sea := exp(-pow(dx / 0.68, 2.0) - pow((dy - 0.05) / 0.34, 2.0)) * 0.62
			var italy := exp(-pow((dx + 0.05 - dy * 0.3) / 0.09, 2.0) - pow((dy + 0.08) / 0.28, 2.0)) * 0.46
			var greece := exp(-pow((dx - 0.28) / 0.10, 2.0) - pow((dy + 0.06) / 0.25, 2.0)) * 0.42
			shape = 0.34 - sea + maxf(italy, greece) - 0.18 * r2
		5:  # Europe & Isles: Mainland south/east, Scandinavia north, British Isles west
			var main_eu := clampf((dx + 0.35) * 0.5 + (dy - 0.05) * 0.6, -0.3, 0.42)
			var scand := exp(-pow((dx - 0.05) / 0.24, 2.0) - pow((dy + 0.55) / 0.28, 2.0)) * 0.52
			var uk := exp(-pow((dx + 0.55) / 0.16, 2.0) - pow((dy + 0.12) / 0.26, 2.0)) * 0.48
			shape = maxf(main_eu, maxf(scand, uk)) - 0.08 - 0.22 * r2
		6:  # East Asia & Arc: Continental mainland west + curved island arc east
			var main_as := clampf(0.28 - (dx + 0.18) * 0.75, -0.4, 0.38) - 0.22 * dy * dy
			var arc_r := sqrt(pow(dx + 0.15, 2.0) + pow(dy, 2.0))
			var jpn := exp(-pow((arc_r - 0.72) / 0.11, 2.0)) * (0.52 if dx > 0.1 else 0.0)
			shape = maxf(main_as, jpn) - 0.04
		7:  # North America: Wide north tapering to southern isthmus + Gulf
			var width_y := 0.58 - 0.28 * (dy + 0.2)
			var cont := 0.36 - pow(dx / maxf(0.18, width_y), 2.0) * 0.32 - 0.18 * dy * dy
			var gulf := exp(-pow((dx - 0.12) / 0.24, 2.0) - pow((dy - 0.45) / 0.25, 2.0)) * 0.52
			shape = cont - gulf
		8:  # Middle East Crossroads: Landmass cut by Red Sea, Persian Gulf & Mediterranean edge
			var red_sea := exp(-pow((dx + 0.28 - dy * 0.35) / 0.09, 2.0) - pow((dy - 0.22) / 0.48, 2.0)) * 0.58
			var gulf2 := exp(-pow((dx - 0.25 - dy * 0.30) / 0.11, 2.0) - pow((dy - 0.10) / 0.32, 2.0)) * 0.54
			var med_w := exp(-pow((dx + 0.75) / 0.32, 2.0) - pow((dy + 0.25) / 0.42, 2.0)) * 0.55
			shape = 0.32 - red_sea - gulf2 - med_w - 0.14 * r2
		9:  # Ring Atoll: Circular ring continent around a lagoon with a central island
			var rad := sqrt(dx * dx * 0.85 + dy * dy * 1.15)
			var ring := exp(-pow((rad - 0.58) / 0.22, 2.0)) * 0.54
			var center_isle := exp(-pow(rad / 0.16, 2.0)) * 0.46
			shape = maxf(ring, center_isle) - 0.22
		10: # Inland Sea: Continent enclosing a deep inner sea with narrow straits
			var rad2 := sqrt(dx * dx * 0.75 + dy * dy * 1.1)
			var inner_sea := exp(-pow(rad2 / 0.42, 2.0)) * 0.62
			shape = 0.38 - 0.28 * r2 - inner_sea
		11: # Four Corners: 4 continents separated by a cross channel + central hub
			var ch_x := exp(-dx * dx * 38.0) * 0.44
			var ch_y := exp(-dy * dy * 28.0) * 0.44
			var hub := exp(-(dx * dx + dy * dy) * 26.0) * 0.55
			shape = 0.34 - maxf(ch_x, ch_y) + hub - 0.16 * r2
	return nv + shape

func _upstream_menu() -> Array:
	if _up_menu.is_empty(): _up_menu = UpstreamMaps.menu_entries()
	return _up_menu
func _real_map(k: int) -> Dictionary:
	return UpstreamMaps.real_map_at(k)
func _chunk_cols() -> int:
	return ceili(float(W) / CW)
func _rebuild_chunks() -> void:
	for sp in chunk_sp:
		if sp != null and is_instance_valid(sp):
			remove_child(sp)
			sp.queue_free()
	chunk_img.clear(); chunk_tex.clear(); chunk_sp.clear()
	var cols := _chunk_cols()
	var rows := ceili(float(H) / CH)
	for cy in rows:
		for cx in cols:
			var cw := mini(CW, W - cx * CW)
			var ch := mini(CH, H - cy * CH)
			var im := Image.create(maxi(cw, 1), maxi(ch, 1), false, Image.FORMAT_RGBA8)
			var tx := ImageTexture.create_from_image(im)
			var sp := Sprite2D.new(); sp.texture = tx; sp.centered = false
			sp.scale = Vector2(TS, TS); sp.position = Vector2(cx * CW, cy * CH) * TS
			sp.material = _map_material()
			sp.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST  # the map stays pixel-crisp (the UI default is linear)
			add_child(sp)
			chunk_img.append(im); chunk_tex.append(tx); chunk_sp.append(sp)
	chunk_dirty.resize(chunk_img.size()); chunk_dirty.fill(0)
func _set_map_size(w: int, h: int) -> void:
	if w < 1 or h < 1:
		return
	if w == W and h == H and not chunk_img.is_empty():
		return
	W = w
	H = h
	TILE_NORM = (640.0 * 352.0) / float(W * H)
	_DIRS4 = PackedInt32Array([1, -1, W, -W])
	_cached_map_bytes.clear()
	_gen_cache = {}
	_rebuild_chunks()
	if cam != null:
		cam.position = Vector2(W, H) * TS / 2
	if mcam != null:
		mcam.set_map(W, H)

func kind_of(id: int) -> int:
	if id < _kind_cache.size(): return _kind_cache[id]
	if id == PLAYER: return SimRules.KIND_HUMAN
	if id > 0 and id < nations.size() and nations[id].get("bot", false): return SimRules.KIND_HUMAN
	if id > 0 and id < nations.size() and nations[id].get("human", false): return SimRules.KIND_HUMAN  # a remote person (multiplayer host)
	if id > 0 and id < nations.size() and nations[id].get("prot", false): return SimRules.KIND_NATION
	return SimRules.KIND_TRIBE

func _rebuild_kind_cache() -> void:
	_kind_cache.resize(0)
	var kc := PackedInt32Array(); kc.resize(nations.size())
	for id in nations.size(): kc[id] = kind_of(id)
	_kind_cache = kc

# Upstream Sim.intent_attack / intent_attack_troops (Sim.luau:1288-1337): a LAND attack on the
# owner of `tile` with `ratio` of home troops, along the whole shared frontier. It never turns into
# a transport: the client picks attack vs boat (UIRules._primary) and sends "boat" itself. With no
# frontier the troops are refunded and the player is told to send a boat.
func intent_attack(id: int, tile: int, ratio: float) -> bool:
	if tile < 0 or tile >= W * H: return false
	if is_nan(ratio) or is_inf(ratio): return false
	var o := owner_map[tile]
	if o < 0 or o == id: return false
	if id <= 0 or id >= nations.size() or not nations[id].alive: return false
	var home: float = nations[id].troops
	var blocked: bool = (o > 0 and (allied(id, o) or not nations[o].alive)) or shielded(o)
	var ok := launch_attack(id, o, clampf(ratio, 0.01, 1.0))
	if not ok and not blocked and id == PLAYER and nations[id].troops >= home - 0.5 and home * clampf(ratio, 0.01, 1.0) >= 1.0:
		if o > 0:
			notify("You don't border %s — send a boat" % _nname(o), "info")
		else:
			notify("That land isn't next to yours — send a boat", "info")
	return ok

func _adj_any(tile: int, id: int) -> bool:
	return _adj_to(tile, id) or owner_map[tile] == id

func _get_handcrafted_map_bytes(k: int) -> PackedByteArray:
	return UpstreamMaps.codes_at(k)

func _map_sub(k: int, tab: int) -> String:
	var rm := _real_map(k)
	var nt := _tribes_for(tab, k)
	var sz := UpstreamMaps.size_of(UpstreamMaps.id_at(k))
	if not rm.is_empty():
		return "%d × %d  ·  %d nations + %d tribes" % [sz.x, sz.y, rm.nations.size(), nt]
	return "%d × %d  ·  %d tribes" % [sz.x, sz.y, nt]

# The upstream map id behind (tab, k). tab is only the picker's category filter; k indexes ORDER.
func _upstream_id_for(_tab: int, k: int) -> String:
	return UpstreamMaps.id_at(k)

# Sim.default_tribes for (tab, k): Rules.DEFAULT_TRIBES x the map's scale^2 (400 without one).
func _tribes_for(tab: int, k: int) -> int:
	var id := _upstream_id_for(tab, k)
	var s := 1.0
	if id != "" and FileAccess.file_exists(UpstreamMaps.DIR + id + ".json"):
		s = float(UpstreamMaps.meta(id).get("scale", 1.0))
	return int(floor(SimRules.DEFAULT_TRIBES * s * s + 0.5))

func _active_map_entry(k: int) -> Array:
	var tbl: Array = _upstream_menu()
	return tbl[clampi(k, 0, tbl.size() - 1)]

func _store_gen_cache() -> void:
	_gen_cache = {"key": "%d|%d|%d|%d" % [map_tab, map_i, (rand_seed_off if map_tab == 1 else 0), _qual()],
		"om": owner_map.duplicate(), "el": elev_map, "mt": mtn.duplicate(), "cd": coast_dist, "bc": base_col,
		"lt": land_total, "body": sim_naval.body, "cl": sim_naval.coast_list, "nav": sim_nav}
func _gt(lbl: String) -> void:
	var t := Time.get_ticks_usec()
	if "--maptest" in OS.get_cmdline_user_args() and _gt_t > 0: print("  phase %s %.0f ms" % [lbl, (t - _gt_t) / 1000.0])
	_gt_t = t

func gen_map() -> void:
	_stop_sim_workers()
	_reset_tile_snapshot()
	_gt_t = Time.get_ticks_usec()
	var mid := _upstream_id_for(map_tab, map_i)
	var msz := UpstreamMaps.size_of(mid)
	_set_map_size(msz.x, msz.y)
	var m := _active_map_entry(map_i)
	var seed_val: int = int(m[1]) + (rand_seed_off if map_tab == 1 else 0)
	var n := FastNoiseLite.new()
	n.seed = seed_val
	n.frequency = 0.006
	n.fractal_octaves = 6
	var n2 := FastNoiseLite.new()
	n2.seed = seed_val + 7
	n2.frequency = 0.025
	var n3 := FastNoiseLite.new()
	n3.seed = seed_val + 99
	n3.frequency = 0.04
	n3.fractal_octaves = 3
	owner_map.resize(W * H)
	base_col.resize(W * H)
	mtn.resize(W * H); mtn.fill(0)
	fallout.resize(W * H); fallout.fill(0); fallout_list.clear()
	fallout_t.resize(W * H); fallout_t.fill(0.0)
	if fallout_glow != null: fallout_glow.reset()
	var elev := PackedFloat32Array(); elev.resize(W * H)
	land_total = 0; _land_w = -1.0
	var raw_bytes := _get_handcrafted_map_bytes(map_i)
	var rmap := _real_map(map_i)
	snow_src = raw_bytes
	tile_bytes = UpstreamMaps.tiles(mid) if raw_bytes.size() == W * H else PackedByteArray()
	if tile_bytes.size() != W * H: tile_bytes = PackedByteArray()
	sim_rules.tile_norm = TILE_NORM
	sim_rules.set_k(float(rmap.k_lin) if not rmap.is_empty() else DEFAULT_K_LIN)
	real_nations = rmap.nations if not rmap.is_empty() else []
	var gkey := "%d|%d|%d|%d" % [map_tab, map_i, (rand_seed_off if map_tab == 1 else 0), _qual()]
	if _gen_cache.get("key", "") == gkey:
		owner_map = _gen_cache.om.duplicate(); elev_map = _gen_cache.el; mtn = _gen_cache.mt.duplicate()
		coast_dist = _gen_cache.cd; base_col = _gen_cache.bc; land_total = _gen_cache.lt
		if sim_naval == null: sim_naval = SimNaval.new(self, sim_rules)
		sim_naval.body = _gen_cache.body; sim_naval.coast_list = _gen_cache.cl; sim_naval.trade_cache.clear()
		sim_nav = _gen_cache.get("nav", null)
		if sim_nav == null or not sim_nav.ready: sim_nav = SimNavS.new(); sim_nav.build(sim_naval.body, W, H)
		_gt("cache")
		if _async_gen: await get_tree().process_frame
		_redraw_all()
		_gt("redraw")
		return
	if raw_bytes.size() == W * H:
		var jimg := n3.get_image(W, H, false, false, false).get_data()  # L8, noise*0.5+0.5
		for i in W * H:
			var code: int = raw_bytes[i]
			if code == 0:
				owner_map[i] = WATER
				elev[i] = -0.2
			else:
				owner_map[i] = NEUTRAL
				land_total += 1
				var jitter: float = (jimg[i] / 127.5 - 1.0) * 0.04
				if code == 4:  # snow: exactly plains for movement/conquest/spawns/building
					mtn[i] = 0; elev[i] = 0.10 + jitter
				elif code >= 3:
					mtn[i] = 2; elev[i] = 0.50 + jitter
				elif code == 2:
					mtn[i] = 1; elev[i] = 0.28 + jitter
				else:
					mtn[i] = 0; elev[i] = 0.10 + jitter
	else:
		# shape evaluated on a 1/4-res grid (normalised coords, same as the thumbnails), upscaled
		# bicubically in C++, plus fine C++ noise for coastline detail at full resolution
		var lw := W / 4; var lh := H / 4
		var lo := PackedFloat32Array(); lo.resize(lw * lh)
		for ly in lh:
			for lx in lw:
				lo[ly * lw + lx] = _sample_map_elev(map_i, (lx + 0.5) * 4.0, (ly + 0.5) * 4.0, n, n2)
			if _async_gen and (ly & 3) == 3:
				_load_progress(0.08 + 0.16 * float(ly) / float(lh))
				await get_tree().process_frame
		var limg := Image.create_from_data(lw, lh, false, Image.FORMAT_RF, lo.to_byte_array())
		limg.resize(W, H, Image.INTERPOLATE_CUBIC)
		var full := limg.get_data().to_float32_array()
		var nf := FastNoiseLite.new(); nf.seed = seed_val + 31; nf.frequency = 0.05; nf.fractal_octaves = 3
		var fimg := nf.get_image(W, H, false, false, false).get_data()
		for y in H:
			var row := y * W
			for x in W:
				var ii := row + x
				var v: float = full[ii] + (fimg[ii] / 127.5 - 1.0) * 0.035
				var o := NEUTRAL if v > 0.0 else WATER
				owner_map[ii] = o
				elev[ii] = v
				if o == NEUTRAL:
					if v > 0.40: mtn[ii] = 2
					elif v > 0.20: mtn[ii] = 1
					land_total += 1
			if _async_gen and (y & 31) == 31:
				_load_progress(0.26 + 0.04 * float(y) / float(H))
				await get_tree().process_frame
	elev_map = elev
	_gt("decode")
	if _async_gen: _load_progress(0.3); await get_tree().process_frame
	# distance to land / water (for coast glow & beaches)
	coast_dist.resize(W * H); coast_dist.fill(99)
	var q := PackedInt32Array(); q.resize(W * H); var qn := 0
	var N := W * H
	var dirs := PackedInt32Array([1, -1, W, -W])
	for i in N:
		if owner_map[i] != WATER:
			for d in dirs:
				var j: int = i + d
				if j >= 0 and j < N and owner_map[j] == WATER and coast_dist[j] == 99:
					coast_dist[j] = 1; q[qn] = j; qn += 1
	var qi := 0
	while qi < qn:
		var i: int = q[qi]; qi += 1
		var cd: int = coast_dist[i]
		if cd >= 12: continue
		for d in dirs:
			var j: int = i + d
			if j >= 0 and j < N and owner_map[j] == WATER and coast_dist[j] == 99:
				coast_dist[j] = cd + 1; q[qn] = j; qn += 1
	_gt("coast")
	if _async_gen: _load_progress(0.45); await get_tree().process_frame
	if sim_naval == null: sim_naval = SimNaval.new(self, sim_rules)
	if _async_gen and "--sim-worker-nav" in OS.get_cmdline_user_args():
		await _prepare_navigation_async()
	else:
		_prepare_navigation()
	_gt("bodies")
	if _async_gen: _load_progress(0.65); await get_tree().process_frame
	sim_naval.trade_cache.clear()
	_recompute_base_colors()

const NavigationJob = preload("res://sim/navigation_job.gd")
var _navigation_thread: Thread

func _prepare_navigation() -> void:
	sim_naval.compute_bodies()
	sim_nav = SimNavS.new()
	sim_nav.build(sim_naval.body, W, H)

func _prepare_navigation_async() -> void:
	var thread := Thread.new()
	# Ownership transfers with the job. The worker gets no game node or live array.
	var job := NavigationJob.new(owner_map.duplicate(), W, H, WATER)
	if thread.start(job.build) != OK:
		_prepare_navigation()
		return
	_navigation_thread = thread
	while thread.is_alive():
		await get_tree().process_frame
		if _navigation_thread != thread:
			return
	var result: Array = thread.wait_to_finish()
	_navigation_thread = null
	sim_naval.body = result[0]
	sim_naval.coast_list = result[1]
	sim_nav = result[2]

func _exit_tree() -> void:
	_stop_sim_workers()
	if sim_ars != null:
		sim_ars._join_blast_tasks()
	if _navigation_thread != null:
		_navigation_thread.wait_to_finish()
		_navigation_thread = null

func _recompute_base_colors() -> void:
	if owner_map.size() != W * H or elev_map.size() != W * H: return
	var cfg: Dictionary = save.get("settings", {})
	var qual_i := clampi(int(cfg.get("qual_i", 3)), 0, 3)
	var msaa_i := clampi(int(cfg.get("msaa_i", 2)), 0, 3)
	var m := _active_map_entry(map_i)
	var seed_val: int = int(m[1]) + (rand_seed_off if map_tab == 1 else 0)
	var n3 := FastNoiseLite.new()
	n3.seed = seed_val + 99
	n3.frequency = 0.04
	n3.fractal_octaves = 3
	var deep := Color(0.18, 0.39, 0.60) if qual_i >= 3 else Color(0.20, 0.42, 0.62)
	var shallow := Color(0.44, 0.69, 0.84) if qual_i >= 3 else Color(0.42, 0.66, 0.80)
	_qual_c = qual_i
	if qual_i >= 2:
		_rw_terrain_all()
		_gt("colors")
		_store_gen_cache()
		if _async_gen: _load_progress(0.85); await get_tree().process_frame
		_redraw_all()
		_gt("redraw")
		return
	for i in W * H:
		var x := i % W; var y := i / W
		var o := owner_map[i]
		var t: float = (n3.get_noise_2d(x, y) * 0.5 + 0.5) if qual_i >= 1 else 0.5
		var c: Color
		if o == WATER:
			var d_c: int = coast_dist[i] if coast_dist.size() == W * H else 99
			if qual_i == 0:
				# Low quality: flat ocean color
				c = Color(0.22, 0.44, 0.64)
			elif qual_i == 1:
				# Medium quality: 2-step coastal shelf
				c = shallow if d_c <= 2 else deep
			elif qual_i == 2:
				# High quality: smooth coastal shelf + subtle wave texture
				c = deep.lerp(shallow, clampf(1.0 - (d_c - 1) / 9.0, 0.0, 1.0) * 0.8) if d_c < 99 else deep
				c = c.darkened(0.04 * t)
			else:
				# Ultra quality: deep bathymetry + turquoise coral shallows + specular micro-shimmer
				var sh_f := clampf(1.0 - (d_c - 1) / 11.0, 0.0, 1.0)
				c = deep.lerp(shallow, pow(sh_f, 0.85) * 0.88) if d_c < 99 else deep.darkened(0.06)
				if d_c == 1: c = c.lerp(Color(0.56, 0.80, 0.88), 0.35)
				c = c.darkened(0.05 * t)
		else:
			var e := elev_map[i]
			if qual_i == 0:
				# Low quality: flat solid biome colors
				if mtn[i] == 2: c = Color(0.84, 0.84, 0.87)
				elif mtn[i] == 1: c = Color(0.78, 0.71, 0.52)
				else: c = Color(0.66, 0.78, 0.49)
			elif qual_i == 1:
				# Medium quality: basic elevation shading, no beaches
				if mtn[i] == 2: c = Color(0.72, 0.69, 0.65).lerp(Color(0.94, 0.94, 0.96), clampf((e - 0.42) * 4.0, 0.0, 1.0))
				elif mtn[i] == 1: c = Color(0.80, 0.73, 0.54).lerp(Color(0.72, 0.64, 0.46), t * 0.45)
				else: c = Color(0.70, 0.81, 0.52).lerp(Color(0.60, 0.73, 0.45), t * 0.45)
			else:
				# High & Ultra quality: full biome shading + snow peaks + sandy beaches + relief contrast
				if mtn[i] == 2:
					c = Color(0.62, 0.58, 0.53).lerp(Color(0.97, 0.97, 0.99), clampf((e - 0.40) * 5.2, 0.0, 1.0)).darkened(0.07 * t)
				elif mtn[i] == 1:
					c = Color(0.82, 0.75, 0.55).lerp(Color(0.73, 0.64, 0.45), t * 0.65).lerp(Color(0.68, 0.60, 0.46), clampf((e - 0.20) * 3.5, 0.0, 1.0))
				else:
					c = Color(0.72, 0.83, 0.54).lerp(Color(0.56, 0.72, 0.43), t * 0.65)
				var w_adj := 0
				for d in [1, -1, W, -W]:
					if (d == 1 and i % W == W - 1) or (d == -1 and i % W == 0): continue
					var j: int = i + d
					if j >= 0 and j < W * H and owner_map[j] == WATER: w_adj += 1
				if w_adj > 0:
					c = c.lerp(Color(0.92, 0.88, 0.71), 0.55 if qual_i == 2 else minf(0.78, 0.45 + 0.14 * w_adj))
		if qual_i >= 2: c = _rw_terrain(i)
		elif owner_map[i] != WATER and snow_src.size() == W * H and snow_src[i] == 4: c = SNOW_COL
		base_col[i] = c
	# Software Coastline & Border Anti-Aliasing pass scaled by msaa_i (0 = Off/Sharp, 1 = 2x, 2 = 4x, 3 = 8x)
	if msaa_i > 0 and qual_i < 2:
		var blend_w: float = [0.0, 0.16, 0.28, 0.40][msaa_i]
		var copy_col := base_col.duplicate()
		for i in W * H:
			var x := i % W; var y := i / W
			if x <= 0 or x >= W - 1 or y <= 0 or y >= H - 1: continue
			var o := owner_map[i]
			var diff_nb := false
			var acc_r := 0.0; var acc_g := 0.0; var acc_b := 0.0; var nb_cnt := 0
			for d in [1, -1, W, -W]:
				if (d == 1 and i % W == W - 1) or (d == -1 and i % W == 0): continue
				var j: int = i + d
				if owner_map[j] != o or mtn[j] != mtn[i]: diff_nb = true
				var nc: Color = copy_col[j]
				acc_r += nc.r; acc_g += nc.g; acc_b += nc.b; nb_cnt += 1
			if diff_nb and nb_cnt > 0:
				var avg_c := Color(acc_r / nb_cnt, acc_g / nb_cnt, acc_b / nb_cnt, 1.0)
				base_col[i] = copy_col[i].lerp(avg_c, blend_w)
	_gt("colors")
	_redraw_all()
	_gt("redraw")

# Fast whole-map version of _rw_terrain (same colours), locals only.
func _rw_terrain_all() -> void:
	if tile_bytes.size() == W * H:
		var tb := tile_bytes
		var lut := PackedColorArray(); lut.resize(256)
		for b in 256: lut[b] = terrain_pixel(b)
		var bc0 := PackedColorArray(); bc0.resize(W * H)
		for i in W * H: bc0[i] = lut[tb[i]]
		base_col = bc0
		return
	var om := owner_map; var cdist := coast_dist; var el := elev_map; var mt := mtn
	var N := W * H
	var bc := PackedColorArray(); bc.resize(N)
	var shore_w := Color8(int(0.7 * 0x47 + 76.5), int(0.7 * 0x85 + 76.5), int(0.7 * 0xB5 + 76.5))
	var sand := Color8(0xCC, 0xCB, 0x9E)
	var ocean := []
	for m in 11: ocean.append(Color8(0x47 - m, 0x85 - m, 0xB5 - m))
	var mtc := []
	for mm in 7: mtc.append(Color8(0xE6 + mm, 0xE6 + mm, 0xE6 + mm))
	var hic := []
	for mh in 10: hic.append(Color8(0xDC + 2 * mh, 0xCB + 2 * mh, 0x9E + 2 * mh))
	var plc := []
	for mp in 10: plc.append(Color8(0xBE, 0xDC - 2 * mp, 0x8A))
	for i in N:
		var o: int = om[i]
		var w := o == WATER
		var x := i % W
		var shore := false
		if x > 0 and (om[i - 1] == WATER) != w: shore = true
		elif x < W - 1 and (om[i + 1] == WATER) != w: shore = true
		elif i >= W and (om[i - W] == WATER) != w: shore = true
		elif i + W < N and (om[i + W] == WATER) != w: shore = true
		if w:
			bc[i] = shore_w if shore else ocean[mini(maxi(cdist[i] - 1, 0), 10)]
		elif snow_src.size() == N and snow_src[i] == 4: bc[i] = SNOW_COL
		elif shore: bc[i] = sand
		else:
			var e: float = el[i]
			var k: int = mt[i]
			if k == 2: bc[i] = mtc[clampi(int((e - 0.4) * 30.0), 0, 6)]
			elif k == 1: bc[i] = hic[clampi(int((e - 0.2) * 40.0), 0, 9)]
			else: bc[i] = plc[clampi(int(e * 30.0), 0, 9)]
	base_col = bc

# MapSurface.terrain_pixel (src/client/Map/MapSurface.luau), 1:1: the colour of an upstream terrain byte
# (bit7 land, bit6 shoreline, bits0-4 magnitude: land elevation 0-30 / water depth; land 31 impassable).
static func terrain_pixel(tb: int) -> Color:
	var land := tb >= 128
	var shore := (tb & 64) != 0
	var mag := tb & 31
	if land and mag == 31: return Color8(0x3C, 0x3C, 0x3C)
	if land and shore: return Color8(0xCC, 0xCB, 0x9E)
	if land:
		if mag < 10: return Color8(0xBE, 0xDC - 2 * mag, 0x8A)
		if mag < 20:
			var m := mag - 10
			return Color8(0xDC + 2 * m, 0xCB + 2 * m, 0x9E + 2 * m)
		var mm := mag / 2
		return Color8(mini(255, 0xE6 + mm), mini(255, 0xE6 + mm), mini(255, 0xE6 + mm))
	if shore: return Color8(roundi(0.7 * 0x47 + 76.5), roundi(0.7 * 0x85 + 76.5), roundi(0.7 * 0xB5 + 76.5))
	var d := mini(mag, 10)
	return Color8(0x47 - d, 0x85 - d, 0xB5 - d)

func _rw_terrain(i: int) -> Color:
	if tile_bytes.size() == W * H: return terrain_pixel(tile_bytes[i])
	var o := owner_map[i]
	var x := i % W
	var shore := false
	for d in _DIRS4:
		var j: int = i + d
		if j < 0 or j >= W * H or (d == 1 and x == W - 1) or (d == -1 and x == 0): continue
		if (owner_map[j] == WATER) != (o == WATER): shore = true; break
	if o == WATER:
		if shore: return Color8(int(0.7 * 0x47 + 76.5), int(0.7 * 0x85 + 76.5), int(0.7 * 0xB5 + 76.5))
		var dc: int = coast_dist[i] if coast_dist.size() == W * H else 10
		var m := mini(maxi(dc - 1, 0), 10)
		return Color8(0x47 - m, 0x85 - m, 0xB5 - m)
	if snow_src.size() == W * H and snow_src[i] == 4: return SNOW_COL
	if shore: return Color8(0xCC, 0xCB, 0x9E)
	var e: float = elev_map[i] if elev_map.size() == W * H else 0.2
	if mtn[i] == 2:
		var mm := clampi(int((e - 0.4) * 30.0), 0, 6)
		return Color8(0xE6 + mm, 0xE6 + mm, 0xE6 + mm)
	if mtn[i] == 1:
		var mh := clampi(int((e - 0.2) * 40.0), 0, 9)
		return Color8(0xDC + 2 * mh, 0xCB + 2 * mh, 0x9E + 2 * mh)
	var mp := clampi(int(e * 30.0), 0, 9)
	return Color8(0xBE, 0xDC - 2 * mp, 0x8A)

func _qual() -> int:
	if _qual_c >= 0: return _qual_c
	return clampi(int(save.get("settings", {}).get("qual_i", 3)), 0, 3)

func _tile_color(i: int) -> Color:
	var c0 := _tile_color_rgb(i)
	var o := owner_map[i]
	if o == WATER: c0.a = 0.5
	elif o > 0:
		var x := i % W
		var bd := false
		for d in [1, -1, W, -W]:
			if (d == 1 and i % W == W - 1) or (d == -1 and i % W == 0): continue
			var j: int = i + d
			if j < 0 or j >= W * H or (d == 1 and x == W - 1) or (d == -1 and x == 0): continue
			if owner_map[j] != o: bd = true; break
		c0.a = 0.86 if bd else 0.94
	else: c0.a = 1.0
	return c0

func _tile_color_rgb(i: int) -> Color:
	var o := owner_map[i]
	if _qual() >= 2: return _rw_tile_rgb(i, o)
	if o <= 0:
		if o == NEUTRAL and fallout.size() > i and fallout[i] == 1:
			var h := (i * 2654435761) % 7
			return Color(0.25, 0.62, 0.25) if h < 3 else (Color(0.85, 0.45, 0.2) if h == 3 else base_col[i].lerp(Color(0.3, 0.7, 0.3), 0.6))
		return base_col[i]
	var c: Color = nations[o].color
	var x := i % W
	var diff_cnt := 0
	for d in [1, -1, W, -W]:
		if (d == 1 and i % W == W - 1) or (d == -1 and i % W == 0): continue
		var j: int = i + d
		if j < 0 or j >= W * H or (d == 1 and x == W - 1) or (d == -1 and x == 0): continue
		if owner_map[j] != o:
			diff_cnt += 1
	if diff_cnt > 0:
		var msaa_i := clampi(int(save.get("settings", {}).get("msaa_i", 2)), 0, 3)
		var b_dark: float = 0.32 if msaa_i <= 1 else (0.18 + 0.04 * mini(diff_cnt, 3))
		return c.darkened(b_dark)
	return base_col[i].lerp(c, 0.50)

# RoWorld MapSurface.tile_pixel: fill = owner colour (saturation 0.85) at alpha 150/255 over the terrain,
# border tiles opaque in the owner colour with HSL lightness - 0.125, fallout ground opaque green noise
# (0.05, 0.55, 0.07) + hash * 0.05, glowing lime while fresh (FalloutGlow heat, 150,236,90).
func _rw_tile_rgb(i: int, o: int) -> Color:
	if surface != null: return surface.tile_color(i)  # client/map/map_surface.gd
	var x := i % W
	if fallout.size() > i and fallout[i] == 1 and o != WATER:
		var y := i / W
		var h := fmod(abs(sin(x * 12.9898 + y * 78.233) * 43758.5453), 1.0) * 0.05
		var g := Color(0.05 + h, 0.55 + h, 0.07 + h)
		var heat := clampf((fallout_t[i] - 34.5) / 25.5, 0.0, 1.0)
		var bx := (x / 4 + (y / 4) * 7) % 5
		if heat > 0.0: g = g.lerp(Color8(150, 236, 90), heat * (0.75 + 0.05 * bx))
		return g
	var tc: Color = base_col[i]
	if o <= 0: return tc
	var nc: Color = nations[o].color
	nc = Color.from_hsv(nc.h, nc.s * 0.85, nc.v)
	for d in [1, -1, W, -W]:
		if (d == 1 and i % W == W - 1) or (d == -1 and i % W == 0): continue
		var j: int = i + d
		if j < 0 or j >= W * H or (d == 1 and x == W - 1) or (d == -1 and x == 0) or owner_map[j] != o:
			return _hsl_darken(nations[o].color, 0.125)
	return tc.lerp(nc, 150.0 / 255.0)

func _hsl_darken(c: Color, k: float) -> Color:
	var mx := maxf(c.r, maxf(c.g, c.b)); var mn := minf(c.r, minf(c.g, c.b))
	var l := (mx + mn) * 0.5
	var nl := maxf(0.0, l - k)
	if l <= 0.0: return c
	# scale distance from grey proportionally (keeps hue and saturation in HSL)
	var sat := 0.0 if mx == mn else (mx - mn) / (1.0 - absf(2.0 * l - 1.0))
	var ch := (1.0 - absf(2.0 * nl - 1.0)) * sat
	var r := (c.r - mn) / maxf(1e-5, mx - mn); var g := (c.g - mn) / maxf(1e-5, mx - mn); var b := (c.b - mn) / maxf(1e-5, mx - mn)
	var m := nl - ch * 0.5
	return Color(m + r * ch, m + g * ch, m + b * ch)

func _px(x: int, y: int, c: Color) -> void:
	var k := (y / CH) * _chunk_cols() + x / CW
	chunk_img[k].set_pixel(x % CW, y % CH, c)
	chunk_dirty[k] = 1

func _redraw_all() -> void:
	_publish_tile_snapshot()
	_pend_paint.clear(); _rp_clear()
	_qual_c = clampi(int(save.get("settings", {}).get("qual_i", 3)), 0, 3)
	var N := W * H
	var buf := PackedByteArray(); buf.resize(N * 4)
	var hasf := fallout.size() == N
	for i in N:
		var o: int = owner_map[i]
		var c: Color
		if o <= 0 and not (hasf and fallout[i] == 1):
			c = base_col[i]; c.a = 0.5 if o == WATER else 1.0
		else:
			c = _tile_color(i)
		var b := i * 4
		buf[b] = c.r8; buf[b + 1] = c.g8; buf[b + 2] = c.b8; buf[b + 3] = c.a8
	var big := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, buf)
	var cols := _chunk_cols()
	for k in chunk_img.size():
		var cw: int = chunk_img[k].get_width()
		var ch: int = chunk_img[k].get_height()
		chunk_img[k].blit_rect(big, Rect2i((k % cols) * CW, (k / cols) * CH, cw, ch), Vector2i.ZERO)
		chunk_dirty[k] = 1
	dirty = true

# Territory repaint queue. Tiles whose colour may have changed (a capture marks the tile and its 4
# neighbours) go on a packed FIFO with a per-tile mark (no duplicates); the frame loop paints them under a
# time budget (_flush_paint_budget). _pend_paint (a Dictionary) stays for the other writers (MapSurface
# sweeps, fallout glow). (perf: the Dictionary queue cost ~180 ns per insert plus keys() of the whole
# queue every frame.)
var _rp_mark := PackedByteArray()
var _rp_list := PackedInt32Array()
var _rp_head := 0

func _rp_clear() -> void:
	_rp_list = PackedInt32Array(); _rp_head = 0
	if _rp_mark.size() == W * H: _rp_mark.fill(0)

func _paint_pending() -> bool:
	return _rp_head < _rp_list.size() or not _pend_paint.is_empty()

func _paint_pending_count() -> int:
	return _rp_list.size() - _rp_head + _pend_paint.size()

func _repaint(i: int) -> void:
	if net_dedicated: return  # a headless server paints nothing
	if _collect_presentation and tile_snapshot != null:
		_record_repaint(i)
		return
	var N := W * H
	if _rp_mark.size() != N:
		_rp_mark.resize(N); _rp_mark.fill(0); _rp_list = PackedInt32Array(); _rp_head = 0
	# append to the member itself: a local `var ls := _rp_list` is a copy once appended to, which dropped
	# queued tiles (stale colours that never went away)
	if _rp_mark[i] == 0: _rp_mark[i] = 1; _rp_list.append(i)
	# the neighbours only change colour when they are owned (their border and alpha follow the owners
	# around them): neutral land and water look the same whatever is next to them (fallout aside), so
	# they are not queued (5 tiles a flip became about 2 at a front: the backlog showed as stale dots)
	var om := owner_map
	var hasf := fallout.size() == N
	var j := i + 1
	if j < N and _rp_mark[j] == 0 and (om[j] > 0 or (hasf and fallout[j] == 1)): _rp_mark[j] = 1; _rp_list.append(j)
	j = i - 1
	if j >= 0 and _rp_mark[j] == 0 and (om[j] > 0 or (hasf and fallout[j] == 1)): _rp_mark[j] = 1; _rp_list.append(j)
	j = i + W
	if j < N and _rp_mark[j] == 0 and (om[j] > 0 or (hasf and fallout[j] == 1)): _rp_mark[j] = 1; _rp_list.append(j)
	j = i - W
	if j >= 0 and _rp_mark[j] == 0 and (om[j] > 0 or (hasf and fallout[j] == 1)): _rp_mark[j] = 1; _rp_list.append(j)
	dirty = true

# During a fixed-tick slice, record only tile IDs and which neighbours were
# eligible at emission time. Playback preserves the normal FIFO order.
func _record_repaint(tile: int) -> void:
	var n := W * H
	var has_fallout := fallout.size() == n
	var mask := 0
	var offset := 1
	for bit in 4:
		var neighbor := tile + offset
		if neighbor >= 0 and neighbor < n and (owner_map[neighbor] > 0 or (has_fallout and fallout[neighbor] == 1)):
			mask |= 1 << bit
		match bit:
			0: offset = -1
			1: offset = W
			2: offset = -W
	_repaint_events.append(tile * 16 + mask)

func _publish_repaints() -> void:
	if _repaint_events.is_empty():
		return
	var n := W * H
	if _rp_mark.size() != n:
		_rp_mark.resize(n)
		_rp_mark.fill(0)
		_rp_list = PackedInt32Array()
		_rp_head = 0
	var offsets := [1, -1, W, -W]
	for event: int in _repaint_events:
		var tile := event >> 4
		_mark_repaint(tile)
		for bit in 4:
			if event & (1 << bit):
				_mark_repaint(tile + int(offsets[bit]))
	_repaint_events = PackedInt32Array()
	dirty = true

func _mark_repaint(tile: int) -> void:
	if _rp_mark[tile] == 0:
		_rp_mark[tile] = 1
		_rp_list.append(tile)

# Paints queued tiles until `budget_us` microseconds have passed (<= 0: all). True when some are left.
func _flush_paint_budget(budget_us: int) -> bool:
	_publish_tile_snapshot()
	var deadline := Time.get_ticks_usec() + budget_us if budget_us > 0 else -1
	var q := _qual()
	var surf = surface if q >= 2 else null
	var om := owner_map
	var Wl := W
	var N := W * H
	var cols := _chunk_cols()
	var imgs: Array = chunk_img
	var cd := chunk_dirty
	var c := 0
	# 1) the packed FIFO (captures)
	var ls := _rp_list
	var mk := _rp_mark
	var hd := _rp_head
	var n := ls.size()
	var stopped := false
	while hd < n:
		var j: int = ls[hd]
		hd += 1
		mk[j] = 0
		_paint_one(j, surf, om, Wl, N, cols, imgs, cd)
		c += 1
		if deadline >= 0 and (c & 31) == 0 and Time.get_ticks_usec() > deadline:
			stopped = true
			break
	if hd >= n:
		_rp_list = PackedInt32Array(); _rp_head = 0
	elif hd > 32768 and hd * 2 > n:
		_rp_list = ls.slice(hd); _rp_head = 0
	else:
		_rp_head = hd
	if stopped: return true
	# 2) the Dictionary queue (sweeps, fallout)
	if _pend_paint.is_empty(): return false
	if deadline < 0:
		for j in _pend_paint: _paint_one(j, surf, om, Wl, N, cols, imgs, cd)
		_pend_paint.clear()
		return false
	var done := PackedInt32Array()
	for j in _pend_paint:
		_paint_one(j, surf, om, Wl, N, cols, imgs, cd)
		done.append(j)
		c += 1
		if (c & 31) == 0 and Time.get_ticks_usec() > deadline:
			break
	if done.size() == _pend_paint.size():
		_pend_paint.clear()
		return false
	for j in done: _pend_paint.erase(j)
	return true

# Same colour as _px(x, y, _tile_color(i)): the surface colour (or the legacy rules) with the alpha the map
# shader reads (water 0.5, own border 0.86, own interior 0.94, unowned 1.0).
func _paint_one(i: int, surf, om: PackedInt32Array, Wl: int, N: int, cols: int, imgs: Array, cd: PackedByteArray) -> void:
	var c0: Color = surf.tile_color(i) if surf != null else _tile_color_rgb(i)
	var o: int = om[i]
	var x := i % Wl
	if o == WATER: c0.a = 0.5
	elif o > 0:
		var bd := (x < Wl - 1 and om[i + 1] != o) or (x > 0 and om[i - 1] != o) \
			or (i + Wl < N and om[i + Wl] != o) or (i >= Wl and om[i - Wl] != o)
		c0.a = 0.86 if bd else 0.94
	else: c0.a = 1.0
	var y := i / Wl
	var k := (y / CH) * cols + x / CW
	imgs[k].set_pixel(x % CW, y % CH, c0)
	cd[k] = 1

func _flush_paint() -> void:
	_flush_paint_budget(0)

func _upd_border(t: int) -> void:
	var o: int = owner_map[t]
	if o <= 0: return
	var x := t % W
	var b := false
	if x > 0 and owner_map[t - 1] != o and owner_map[t - 1] >= 0: b = true
	elif x < W - 1 and owner_map[t + 1] != o and owner_map[t + 1] >= 0: b = true
	elif t >= W and owner_map[t - W] != o and owner_map[t - W] >= 0: b = true
	elif t < W * (H - 1) and owner_map[t + W] != o and owner_map[t + W] >= 0: b = true
	var d: Dictionary = border[o]
	if b: d[t] = true
	else: d.erase(t)

func _set_owner(i: int, o: int) -> void:
	var om := owner_map
	var old: int = om[i]
	var x := i % W
	var y := i / W
	if old > 0 and old < border.size(): border[old].erase(i)
	if old > 0:
		var no: Dictionary = nations[old]
		no.land -= 1
		no.sx -= x; no.sy -= y
	if not tile_pop.is_empty():
		var tp: float = tile_pop[i]
		if old > 0: nations[old].pop -= tp
		if o > 0: nations[o].pop += tp
	om[i] = o
	if _attack_worker != null: _record_attack_tile(i)
	if net_rec: net_dirty.append(i)
	if _tile_snapshot_valid: _tile_snapshot_dirty.append(i)
	if old > 0 and o > 0: nations[old]["last_by"] = o
	if not struct_at.is_empty() and struct_at.has(i):
		var st = struct_at[i]
		if o > 0 and o != old:
			_own_sv[st.o] = _own_sv.get(st.o, 0) + 1; st.o = o; _sv += 1; _own_sv[o] = _own_sv.get(o, 0) + 1
			st.hits = 0
			var lvl := int(st.get("level", 1))
			var ltxt := (" Lv%d" % lvl) if lvl > 1 else ""
			var nm: String = build_data[st.k][1] + ltxt
			if o == PLAYER:
				notify("Captured %s from %s!" % [nm, _nname(old)], "good")
				sfx("ka_ching")
				add_float(Vector2(i % W + 0.5, i / W + 0.5) * TS, "Captured %s!" % nm, GREEN)
			elif old == PLAYER:
				notify("%s captured your %s!" % [_nname(o), nm], "bad")
		elif o <= 0:
			_struct_remove(st)
	if o > 0 and fallout.size() > i and fallout[i] == 1:
		fallout[i] = 0; fallout_list.erase(i)
	if o > 0:
		var n: Dictionary = nations[o]
		n.land += 1
		var bb: Rect2i = n.bb
		if bb.size == Vector2i.ZERO:
			n.bb = Rect2i(x, y, 1, 1)
		elif x < bb.position.x or y < bb.position.y or x >= bb.position.x + bb.size.x or y >= bb.position.y + bb.size.y:
			n.bb = bb.merge(Rect2i(x, y, 1, 1))  # (only a tile outside the box grows it)
		n.sx += x; n.sy += y
	if border.size() == nations.size():
		ConquestBorders.refresh_after_capture(border, i, o, x, om, W, W * (H - 1))
	_repaint(i)


# TEST ONLY (USE_REAL_POP): load maps/upstream/<id>.pop.bin (zlib float32 W*H people per tile) for the
# current map: World and the continents (tabs 0 and 2); a map without a baked file leaves it off.
func _pop_map_id() -> String:
	# (the real-maps tab's continents share the upstream grid: land differs on ~0.2% of tiles)
	return _upstream_id_for(map_tab, map_i)

func _load_tile_pop() -> void:
	# vanilla: real-world population / 1:1 mode is off and hidden. Always the upstream tile cap,
	# troops displayed /10 (UITheme.troop_div).
	tile_pop = PackedFloat32Array(); tile_pop_avg = 1.0
	sim_rules.set_troop_scale(false)
	UITheme.troop_div = 10.0


func _sim_frame_budget_us() -> int:
	# The sim takes a slice of each frame (a long attacks pass is spread over frames). The slice follows the
	# frame time, 40% of it, so a 180 fps machine gets ~2.5 ms slices instead of a fixed 12 ms that dropped
	# it to ~24 fps while a heavy tick ran; when the sim falls behind it may take up to the old cap.
	var cap := 8000 if OS.has_feature("web") else SIM_BUDGET_US
	_frame_ema = lerpf(_frame_ema, clampf(get_process_delta_time(), 0.002, 0.1), 0.05)
	var us := int(_frame_ema * 1.0e6 * 0.4)
	if tick_acc > 0.5:  # five ticks behind: catch up at full budget
		return cap
	return clampi(us, 2500, cap)

var _frame_ema := 0.016

# Territory repaint time per frame (usec). Was a 5000-tile count, which cost ~10 ms native / 20+ ms on web
# during the early land grab.
func _paint_budget_us() -> int:
	# A big attack queues thousands of tiles a tick; at a flat 3 ms a frame the queue took ~5 s to drain and
	# the new land showed its dark border colour meanwhile. Spend more when the backlog is deep.
	var base := 2500 if OS.has_feature("web") else 3000
	# the faster the game runs the more tiles change a second: paint more a frame (to 4x)
	base = int(base * clampf(float(sim_speed), 1.0, 4.0))
	# a slow device (phone) gets few frames a second: paint proportionally more a frame so the front's stale
	# old-owner pixels do not pile up ("the dots are back", 2026-11-25); frames over 33 ms count as 33 ms
	var fdt := clampf(float(get_process_delta_time()), 0.0167, 0.1)
	base = int(base * clampf(fdt / 0.0167, 1.0, 3.0))
	var n := _paint_pending_count()
	if n > 60000: return base * 4
	if n > 20000: return base * 3
	if n > 6000: return base * 2
	return base

func _want_webprof() -> bool:
	if "--webprof" in OS.get_cmdline_user_args():
		return true
	if OS.has_feature("web"):
		var qs := str(JavaScriptBridge.eval("String(window.location.search || '')", true))
		return qs.find("prof=1") >= 0 or qs.find("webprof=1") >= 0
	return false

# perf harness: ?perfstart=1 (web) / --perfstart (native) starts a World match at once with the player
# spawned, so frame stats can be measured without clicking through the menu. No effect otherwise.
func _want_perfstart() -> bool:
	if "--perfstart" in OS.get_cmdline_user_args():
		return true
	if OS.has_feature("web"):
		var qs := str(JavaScriptBridge.eval("String(window.location.search || '')", true))
		return qs.find("perfstart=1") >= 0
	return false

func _perf_autostart() -> void:
	await get_tree().create_timer(4.0).timeout  # (web: let the title screen finish its own boot first)
	call("sim_start", 0, 0, Vector2(0.5, 0.38), 0, -1.0)
	if menu_panel: menu_panel.visible = false
	pick_panel.visible = false
	if hud: hud.show_match()
	call("_focus_player", 2.6)
	print("perfstart: World W=%d H=%d nations=%d" % [W, H, nations.size()])
	_perf_autostart_watch()

func _perf_autostart_watch() -> void:
	# if something sends the game back to the spawn pick, place the player again
	for k in 20:
		await get_tree().create_timer(1.0).timeout
		if state == "pick":
			print("perfstart: back in pick, restarting")
			call("sim_start", 0, 0, Vector2(0.5, 0.38), 0, -1.0)
			if hud: hud.show_match()
			call("_focus_player", 2.6)

func _webprof_start() -> void:
	_webprof_on = true
	_webprof_acc = 0.0
	print("webprof on")
