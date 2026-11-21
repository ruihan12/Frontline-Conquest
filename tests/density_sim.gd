# TEST ONLY (density-test): World match, AI nations only (the human sits passive in Antarctica), with or
# without USE_REAL_POP. Usage:
#   godot --headless --path . -s res://tests/density_sim.gd -- [--pop 2|0|1|off] (2 = real-pop 1:1, troops are people) [--ticks 4000] [--seed 7] [--map 0] [--k 300 (pop per troop)]  (reporting reads world.pop.bin: World only)
extends SceneTree

const DENSE := ["India", "China", "Bangladesh", "Pakistan", "Indonesia", "Japan", "Nigeria", "Germany",
	"France", "United Kingdom", "Italy", "United States", "Philippines", "Vietnam", "Egypt"]
const SPARSE := ["Siberia", "Yakutia", "Kamchatka", "Yukon", "Nunavut", "Greenland", "Mongolia",
	"Western Australia", "Australia", "Patagonia", "Canada", "Russia", "Algeria", "Mali", "Saudi Arabia"]

func _initialize() -> void:
	_run()

func _arg(k: String, d: String) -> String:
	var a := OS.get_cmdline_user_args()
	var i := a.find(k)
	return a[i + 1] if i >= 0 and i + 1 < a.size() else d

func _run() -> void:
	var mode := _arg("--pop", "off")
	var ticks := int(_arg("--ticks", "4000"))
	var sd := int(_arg("--seed", "7"))
	seed(sd)
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	m.use_real_pop = mode != "off"
	if mode != "off": m.sim_rules.pop_cap_mode = int(mode)
	if _arg("--k", "") != "": m.sim_rules.pop_k = 1.0 / float(_arg("--k", "300"))
	m.rng.seed = sd
	var t0 := Time.get_ticks_msec()
	hs.start(0, int(_arg("--map", "0")), Vector2(0.62, 0.74), 0, -1.0)
	# reporting uses the baked people per tile in every mode (the off run just does not play with it)
	var pop: PackedFloat32Array = m.tile_pop
	if pop.is_empty():
		var f := FileAccess.open("res://maps/upstream/world.pop.bin", FileAccess.READ)
		pop = f.get_buffer(f.get_length()).decompress(m.W * m.H * 4, FileAccess.COMPRESSION_DEFLATE).to_float32_array()
	print("DSIM k=1/%.0f mode=%s seed=%d ticks=%d tile_pop=%s start %.1fs" % [1.0 / m.sim_rules.pop_k, mode, sd, ticks, str(not m.tile_pop.is_empty()), (Time.get_ticks_msec() - t0) / 1000.0])
	for nm in ["United States", "China", "India"]:
		for id in range(1, m.nations.size()):
			if m.nations[id].name == nm and int(m.nations[id].get("spawn_tile", -1)) >= 0:
				key_tiles[nm] = int(m.nations[id].spawn_tile)
	_report(m, pop, 0)
	var done := 0
	while done < ticks:
		var n := mini(1000, ticks - done)
		hs.step(n); done += n
		_report(m, pop, done)
	print("DSIM wall %.1fs" % ((Time.get_ticks_msec() - t0) / 1000.0))
	m.queue_free()
	quit()

var key_tiles := {}

func _report(m, pop: PackedFloat32Array, t: int) -> void:
	var np := {}
	var om = m.owner_map
	for i in om.size():
		var o: int = om[i]
		if o > 0: np[o] = np.get(o, 0.0) + pop[i]
	var ids := []
	for id in range(1, m.nations.size()):
		if m.nations[id].alive and m.nations[id].land > 0: ids.append(id)
	ids.sort_custom(func(x, y): return m.nations[x].land > m.nations[y].land)
	var tot_land := 0; var tot_tr := 0.0
	for id in ids: tot_land += m.nations[id].land; tot_tr += m.nations[id].troops
	print("DSIM t=%d alive=%d owned_land=%d troops_total=%.0f" % [t, ids.size(), tot_land, tot_tr])
	for k in mini(10, ids.size()):
		var id: int = ids[k]; var n = m.nations[id]
		print("DSIM   #%d %-18s land=%6d pop=%7.1fM troops=%8.0f cap=%8.0f" % [k + 1, n.name, n.land, np.get(id, 0.0) / 1e6, n.troops, m.troop_cap(id)])
	var big := -1; var big_cap := -1.0
	for id in ids:
		var c: float = m.troop_cap(id)
		if c > big_cap: big_cap = c; big = id
	if big > 0:
		print("DSIM   biggest cap %s cap=%.0f troops=%.0f land=%d pop=%.1fM" % [m.nations[big].name, big_cap, m.nations[big].troops, m.nations[big].land, np.get(big, 0.0) / 1e6])
	for nm in key_tiles:
		var o: int = om[key_tiles[nm]]
		if o > 0:
			print("DSIM   %s capital owner %s troops=%.0f cap=%.0f pop=%.1fM shown=%s" % [nm, m.nations[o].name, m.nations[o].troops, m.troop_cap(o), np.get(o, 0.0) / 1e6, UITheme.fmt_troops(m.nations[o].troops)])
		else:
			print("DSIM   %s capital owner none" % nm)
	for grp in [["dense", DENSE], ["sparse", SPARSE]]:
		var gl := 0; var gp := 0.0; var gt := 0.0; var ga := 0
		for id in range(1, m.nations.size()):
			var n = m.nations[id]
			if n.name in grp[1] and n.alive and n.land > 0:
				ga += 1; gl += n.land; gp += np.get(id, 0.0); gt += n.troops
		print("DSIM   group %-6s alive=%2d land=%7d pop=%7.1fM troops=%9.0f" % [grp[0], ga, gl, gp / 1e6, gt])
