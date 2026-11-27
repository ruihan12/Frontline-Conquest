class_name LuauLink
extends RefCounted
## Keeps Luau's tile layer (luau/sim/Core/SimState.luau) equal to the GDScript one while the sim is half ported
## (docs/LUAU_PORT.md, Step 4). The match's GDScript side records every owner / fallout change it makes
## (map.gd _set_owner and sim/arsenal.gd nuke_blast append (tile, value) pairs to luau_dirty / luau_fdirty).
## flush() sends them to Luau, pull() writes back what Luau modules changed. A Luau module call is wrapped in
## flush() before and pull() after (so writes of both sides land in the order they happened), and sync() =
## flush + pull runs at the end of each tick, so at every tick boundary both copies hold the same tiles.
## A new map (sim_epoch) starts Luau from full copies.
## Without the extension the link stays off and the sim runs as before.

const STATE := "Core/SimState"

var vm: LuauVM = null
var on := false
var epoch := -1
var error := ""
## out pairs applied last sync (tests)
var applied_owner := 0
var applied_fall := 0


func _init() -> void:
	if not LuauVM.available():
		error = "Luau extension not loaded"
		return
	vm = LuauVM.new()
	if not vm.boot() or not vm.require_module(STATE):
		error = vm.last_error
		vm = null
		return
	on = true


## At the end of every tick (game/audio.gd _sim_tick_end).
func sync(g) -> void:
	if flush(g): pull(g)


## GDScript's changes since the last flush -> Luau. False when the link is off (or just started).
func flush(g) -> bool:
	if not on: return false
	if epoch != g.sim_epoch or not g.luau_rec:
		_begin(g)
		return false
	if g.luau_dirty.is_empty() and g.luau_fdirty.is_empty(): return true
	var ok: Variant = vm.call_fn(STATE, "push", [g.luau_dirty.to_byte_array(), g.luau_fdirty.to_byte_array()])
	g.luau_dirty.clear()
	g.luau_fdirty.clear()
	if ok == null:
		_fail(g, vm.last_error)
		return false
	return true


## Luau modules' changes since the last pull -> GDScript: owners through the game's _set_owner (borders, land
## counts, structures, net replication and fallout clearing follow), fallout through the fields nuke_blast sets.
## Owner recording is off meanwhile (Luau has those values); a fallout clear _set_owner makes is recorded and
## goes to Luau with the next flush, before any Luau module runs again.
func pull(g) -> void:
	if not on: return
	var out: Variant = vm.call_fn(STATE, "take", [])
	if out == null:
		_fail(g, vm.last_error)
		return
	var ob: PackedByteArray = out.owner
	var fb: PackedByteArray = out.fallout
	applied_owner = ob.size() / 8
	applied_fall = fb.size() / 8
	if ob.is_empty() and fb.is_empty(): return
	g.luau_rec = false
	var oi := ob.to_int32_array()
	for k in range(0, oi.size(), 2):
		g._set_owner(oi[k], oi[k + 1])
	g.luau_rec = true
	var fi := fb.to_int32_array()
	for k in range(0, fi.size(), 2):
		var t: int = fi[k]
		var v: int = fi[k + 1]
		g.fallout[t] = v
		if v == 1: g.fallout_list[t] = true
		else: g.fallout_list.erase(t)


func _begin(g) -> void:
	g.luau_dirty.clear()
	g.luau_fdirty.clear()
	var ok: Variant = vm.call_fn(STATE, "begin", [g.W, g.H, g.owner_map.to_byte_array(), g.fallout])
	if ok == null:
		_fail(g, vm.last_error)
		return
	epoch = g.sim_epoch
	g.luau_rec = true
	g.luau_frec = true


func _fail(g, msg: String) -> void:
	error = msg
	on = false
	g.luau_rec = false
	g.luau_frec = false
	push_error("Luau link off: " + msg)
