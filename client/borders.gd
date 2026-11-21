# The surface of src/client/UI/BorderTracker.luau the UI reads (what the local owner borders and
# can reach), answered from this port's game instead of a tracked border set.
class_name RWBorders
extends RefCounted

var st: RWGameState


func _init(state: RWGameState) -> void:
	st = state


## BorderTracker.has_coast: one of our border tiles touches a water body.
func has_coast() -> bool:
	return not _my_bodies().is_empty()


var _bodies := {}
var _bodies_key := -1
var _bodies_msec := -100000


## Water bodies our coast touches (BorderTracker._refresh's _bodies: coast_body of each coastal tile
## of ours). This port's border sets skip water neighbours, so the coast is read from the game's
## coast list instead. Like upstream it is refreshed at most every 400 ms (at once when we gain or
## lose our first tile).
func _my_bodies() -> Dictionary:
	var g = st.g
	var me: int = st.local_owner
	var land: int = int(g.nations[me].land) if me > 0 and me < g.nations.size() else 0
	var key: int = me * 1048576 + mini(land, 1)
	var now := Time.get_ticks_msec()
	if key == _bodies_key and now - _bodies_msec < 400:
		return _bodies
	_bodies_key = key
	_bodies_msec = now
	_bodies.clear()
	if land <= 0 or g.sim_naval == null:
		return _bodies
	var nv = g.sim_naval
	var om: PackedInt32Array = g.owner_map
	if nv.body.size() != om.size():
		return _bodies
	var cl: PackedInt32Array = nv.coast_list
	for i: int in cl:
		if om[i] == me:
			var b: int = nv.coast_body(i)
			if b > 0:
				_bodies[b] = true
	return _bodies


## The local owner shares a land border with `id` (0: claimable unclaimed land that is not fallout,
## as BorderTracker._note counts it).
func borders_owner(id: int) -> bool:
	if id == 0:
		return touches_neutral()
	return st.borders_owner(st.local_owner, id)


func touches_neutral() -> bool:
	var g = st.g
	var me: int = st.local_owner
	if me <= 0 or me >= g.border.size():
		return false
	var w: int = g.W
	var n: int = g.owner_map.size()
	var om: PackedInt32Array = g.owner_map
	var fo = g.fallout
	for t: int in g.border[me]:
		var x := t % w
		for k in 4:
			var q := -1
			if k == 0 and x > 0: q = t - 1
			elif k == 1 and x < w - 1: q = t + 1
			elif k == 2 and t >= w: q = t - w
			elif k == 3 and t + w < n: q = t + w
			if q >= 0 and om[q] == 0 and (q >= fo.size() or fo[q] == 0):
				return true
	return false


## BorderTracker.region_touches_me: flood-fills the clicked owner's region from `tile` (bounded by
## `budget` tiles) to see whether it touches us by land. 1 = touches, 0 = region fully explored
## without contact, -1 = budget exhausted (the caller then asks borders_owner).
func region_touches_me(tile: int, budget: int = 3000) -> int:
	var g = st.g
	var me: int = st.local_owner
	var om: PackedInt32Array = g.owner_map
	var n: int = om.size()
	if me <= 0 or tile < 0 or tile >= n:
		return 0
	var w: int = g.W
	var target: int = maxi(om[tile], 0)
	var seen := {tile: true}
	var queue := PackedInt32Array([tile])
	var head := 0
	while head < queue.size():
		if head >= budget:
			return -1
		var i: int = queue[head]
		head += 1
		var x := i % w
		for k in 4:
			var q := -1
			if k == 0 and x > 0: q = i - 1
			elif k == 1 and x < w - 1: q = i + 1
			elif k == 2 and i >= w: q = i - w
			elif k == 3 and i + w < n: q = i + w
			if q < 0:
				continue
			var o: int = om[q]
			if o == me:
				return 1
			# contestable land of the clicked owner (water / icecap are negative in owner_map)
			if o >= 0 and o == target and not seen.has(q):
				seen[q] = true
				queue.append(q)
	return 0


## BorderTracker.can_reach_by_sea: `tile` is coastal land on a water body one of our coasts touches.
func can_reach_by_sea(tile: int) -> bool:
	var g = st.g
	if tile < 0 or tile >= g.owner_map.size() or g.sim_naval == null:
		return false
	if not st.map.is_coastal(tile):
		return false
	return _my_bodies().has(int(g.sim_naval.coast_body(tile)))


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
