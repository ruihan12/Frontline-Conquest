extends "res://game/rails.gd"
# Protagonist AI hooks

# SimAIEconomy._sea_tile_near: a random water tile within r tiles (box) of t, or -1
func _ai_sea_tile_near(t: int, r: float) -> int:
	var ri := int(r)
	for _i in 50:
		var x := t % W + rng.randi_range(-ri, ri)
		var y := t / W + rng.randi_range(-ri, ri)
		if y < 1 or y >= H - 1 or x < 0 or x >= W: continue
		var c := y * W + x
		if owner_map[c] == WATER and sim_naval.body[c] > 0: return c
	return -1

# SimAIEconomy.on_transport_sunk / on_trade_captured -> _retaliate (630-697)
func ai_ship_loss(victim: int, tile: int, enemy: int) -> void:
	if victim <= 0 or victim == PLAYER or victim >= nations.size() or enemy == victim or tile < 0: return
	if _tracks_ships(victim): sim_ws.react_to_ship_loss(victim, tile, ai_difficulty(victim))

# SimAIEconomy._tracks_ships: AI nations and bot players above Easy that own a port answer ship losses
func _tracks_ships(id: int) -> bool:
	return id > 0 and id != PLAYER and id < nations.size() and nations[id].alive \
		and (kind_of(id) == SimRules.KIND_NATION or is_bot(id)) \
		and ai_difficulty(id) > 0 and owned_count(id, 1) > 0

# SimAIEconomy._move_nearest_warship: the nearest ship still near its patrol area takes `t` as its patrol tile
func _ai_move_nearest_warship(id: int, t: int) -> void:
	sim_ws.move_nearest_patrol(id, t)

func _count_ws(o: int) -> int:
	var c := 0
	for ws in warships: if ws.o == o: c += 1
	return c

func _neighbour_count(tile: int) -> int:
	if neigh_cache[0] == tile: return neigh_cache[1]
	var seen := {}
	var cx := tile % W; var cy := tile / W
	for k in 300:
		var p := Vector2(cx, cy) + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(2, 30)
		var x := int(p.x); var y := int(p.y)
		if x < 0 or y < 0 or x >= W or y >= H: continue
		var o: int = owner_map[y * W + x]
		if o > 1: seen[o] = true
	neigh_cache = [tile, seen.size()]
	return seen.size()
