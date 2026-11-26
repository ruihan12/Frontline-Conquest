extends RefCounted
## Render-owned territory and fallout mirror. Packed arrays from the simulation
## are copied on reset. Incremental packets carry only changed tile values.

var _owners := PackedInt32Array()
var _fallout := PackedByteArray()

func reset(owners: PackedInt32Array, fallout: PackedByteArray) -> void:
	_owners = owners.duplicate()
	_fallout = fallout.duplicate()

# The attack journal has one value after each tile index, so it uses a stride of two.
static func capture(tiles: PackedInt32Array, owners: PackedInt32Array, fallout: PackedByteArray,
		tile_stride := 1) -> PackedInt32Array:
	var changes := PackedInt32Array()
	changes.resize(tiles.size() / tile_stride * 3)
	var offset := 0
	for i in range(0, tiles.size(), tile_stride):
		var tile := tiles[i]
		changes[offset] = tile
		changes[offset + 1] = owners[tile]
		changes[offset + 2] = fallout[tile]
		offset += 3
	return changes

func apply(changes: PackedInt32Array) -> void:
	for offset in range(0, changes.size(), 3):
		var tile := changes[offset]
		_owners[tile] = changes[offset + 1]
		_fallout[tile] = changes[offset + 2]

func owner(tile: int) -> int:
	return _owners[tile] if tile >= 0 and tile < _owners.size() else 0

func has_fallout(tile: int) -> bool:
	return tile >= 0 and tile < _fallout.size() and _fallout[tile] != 0

# Internal draw loops borrow these arrays for the duration of a synchronous pass.
# The mirror is their sole writer.
func owners() -> PackedInt32Array:
	return _owners

func fallout() -> PackedByteArray:
	return _fallout
