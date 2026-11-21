# Helpers for the Tab console /spawn command: snap buildings to owned land and ships to water.
class_name SpawnSnap
extends RefCounted

const WATER := -1


## Nearest owned land tile (owner > 0) around `from_tile` that does not already have a structure.
## Prefers `prefer_o` when that owner has a free tile in range; otherwise any owned land.
## Returns -1 if none in `max_r`.
static func owned_land_near(owner_map: PackedInt32Array, occupied: Dictionary, W: int, H: int, from_tile: int, prefer_o: int, max_r := 64) -> int:
	var n: int = W * H
	if from_tile >= 0 and from_tile < n:
		var o: int = owner_map[from_tile]
		if o > 0 and not occupied.has(from_tile):
			return from_tile
		if o > 0:
			prefer_o = o
	if prefer_o < 1:
		prefer_o = 1
	var cx := 0
	var cy := 0
	if from_tile >= 0 and from_tile < n:
		cx = from_tile % W
		@warning_ignore("integer_division")
		cy = from_tile / W
	var best_any := -1
	for r in range(0, max_r + 1):
		var found_pref := -1
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if r > 0 and absi(dx) != r and absi(dy) != r:
					continue
				var x := cx + dx
				var y := cy + dy
				if x < 0 or y < 0 or x >= W or y >= H:
					continue
				var t := y * W + x
				var o: int = owner_map[t]
				if o <= 0 or occupied.has(t):
					continue
				if o == prefer_o:
					found_pref = t
					break
				if best_any < 0:
					best_any = t
			if found_pref >= 0:
				break
		if found_pref >= 0:
			return found_pref
	return best_any


## Nearest water tile around `from_tile`, or -1 if none in `max_r`.
static func water_near(owner_map: PackedInt32Array, W: int, H: int, from_tile: int, max_r := 64) -> int:
	var n: int = W * H
	if from_tile >= 0 and from_tile < n and owner_map[from_tile] == WATER:
		return from_tile
	var cx := 0
	var cy := 0
	if from_tile >= 0 and from_tile < n:
		cx = from_tile % W
		@warning_ignore("integer_division")
		cy = from_tile / W
	for r in range(1, max_r + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if absi(dx) != r and absi(dy) != r:
					continue
				var x := cx + dx
				var y := cy + dy
				if x < 0 or y < 0 or x >= W or y >= H:
					continue
				var t := y * W + x
				if owner_map[t] == WATER:
					return t
	return -1
