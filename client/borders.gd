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
	return 1 if bool(st.g._shares_land_border(st.local_owner, 0, tile)) else 0


## A coast of ours reaches `tile` by sea. (The game's own search runs when the order is given; the
## hint only asks that we have a coast at all.)
func can_reach_by_sea(_tile: int) -> bool:
	return has_coast()
