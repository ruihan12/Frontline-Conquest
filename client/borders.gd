# The surface of src/client/UI/BorderTracker.luau the UI reads (what the local owner borders and
# can reach), answered from this port's game instead of a tracked border set.
class_name RWBorders
extends RefCounted

var st: RWGameState


func _init(state: RWGameState) -> void:
	st = state


func has_coast() -> bool:
	return st.has_coast(st.local_owner)


## The local owner shares a land border with `id` (0: unclaimed land).
func borders_owner(id: int) -> bool:
	if id == 0:
		return bool(st.g._shares_land_border(st.local_owner, 0))
	return st.borders_owner(st.local_owner, id)


## The unclaimed region around `tile` touches the local owner: 1 yes, 0 no, -1 unknown (too big to
## tell cheaply). Here: asked of the game for the clicked tile.
func region_touches_me(tile: int) -> int:
	# 1 = same landmass as the local owner (so the click is a land expansion, not a boat).
	return 1 if bool(st.g._shares_land_border(st.local_owner, 0, tile)) else 0


## A coast of ours reaches `tile` by sea. (The game's own search runs when the order is given; the
## hint only asks that we have a coast at all.)
func can_reach_by_sea(_tile: int) -> bool:
	return has_coast()


var _nb_cache: Array[int] = []
var _nb_tick := -1.0


## The local owner's border tiles (the game tracks them per nation).
func border() -> Array:
	var g = st.g
	var me: int = st.local_owner
	if me <= 0 or me >= g.border.size():
		return []
	return g.border[me].keys()


## Owners that share a land border with the local owner, nearest the start of the border first.
## Recomputed at most twice a second.
func neighbour_ids() -> Array[int]:
	var g = st.g
	var now := float(Time.get_ticks_msec())
	if _nb_tick >= 0.0 and now - _nb_tick < 500.0:
		return _nb_cache
	_nb_tick = now
	var out: Array[int] = []
	var me: int = st.local_owner
	var w: int = g.W
	var n: int = g.owner_map.size()
	for t: int in border():
		for d: int in [1, -1, w, -w]:
			var q := t + d
			if q < 0 or q >= n:
				continue
			var o: int = g.owner_map[q]
			if o > 0 and o != me and not out.has(o):
				out.append(o)
	_nb_cache = out
	return out
