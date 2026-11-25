extends RefCounted
## Information used by name plates, map palettes and structure markers.

const NATION_FIELDS := [
	"name", "color", "alive", "land", "bb", "sx", "sy", "spawn_tile", "troops",
]
const STRUCTURE_FIELDS := [
	"k", "o", "tile", "level", "bt", "bmax", "shots", "cd", "cmax",
]

var nations: Array
var structures: Array

func _init(source_nations: Array, source_structures: Array) -> void:
	nations = _copy_fields(source_nations, NATION_FIELDS)
	structures = _copy_fields(source_structures, STRUCTURE_FIELDS)
	for building: Dictionary in structures:
		if building.has("shots"):
			var shots: Array = building.shots.duplicate()
			shots.make_read_only()
			building.shots = shots
		building.make_read_only()
	for nation: Dictionary in nations:
		nation.make_read_only()
	nations.make_read_only()
	structures.make_read_only()

static func _copy_fields(records: Array, fields: Array) -> Array:
	var result := []
	for record: Dictionary in records:
		var copy := {}
		for field: String in fields:
			if record.has(field):
				copy[field] = record[field]
		result.append(copy)
	return result
