extends RefCounted
## Information used by name plates, map palettes and structure markers.

const NATION_FIELDS := [
	"name", "color", "alive", "land", "bb", "sx", "sy", "spawn_tile", "troops",
]
const STRUCTURE_FIELDS := [
	"k", "o", "tile", "level", "bt", "bmax", "shots", "cd", "cmax",
]

const BOAT_FIELDS := ["uid", "a", "pts", "cum", "d", "air", "_draw_previous", "_draw_received", "_draw_duration"]
const WARSHIP_FIELDS := ["uid", "o", "pos", "tgt", "vet", "_draw_previous", "_draw_received", "_draw_duration"]

var boats: Array
var warships: Array
var nations: Array
var structures: Array

func _init(source_nations: Array, source_structures: Array, source_boats: Array = [], source_warships: Array = []) -> void:
	nations = _copy_fields(source_nations, NATION_FIELDS)
	boats = _copy_units(source_boats, BOAT_FIELDS)
	warships = _copy_units(source_warships, WARSHIP_FIELDS)
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


static func _copy_units(source: Array, fields: Array) -> Array:
	var result := _copy_fields(source, fields)
	for unit: Dictionary in result:
		for key in ["pts", "cum"]:
			if unit.has(key):
				var value = unit[key].duplicate()
				unit[key] = value
		unit.make_read_only()
	result.make_read_only()
	return result
