extends RefCounted
## Information used by name plates, map palettes and structure markers.

const NATION_FIELDS := [
	"name", "color", "alive", "land", "bb", "sx", "sy", "spawn_tile", "troops",
]
const STRUCTURE_FIELDS := [
	"k", "o", "tile", "level", "bt", "bmax", "shots", "cd", "cmax",
]
const ATTACK_FIELDS := ["aid", "a", "t", "troops", "last", "retreat_at"]

const BOAT_FIELDS := ["uid", "a", "pts", "cum", "d", "air", "_draw_previous", "_draw_received", "_draw_duration"]
const WARSHIP_FIELDS := ["uid", "o", "pos", "tgt", "vet", "_draw_previous", "_draw_received", "_draw_duration"]

const TRADER_FIELDS := ["uid", "o", "pts", "cum", "d", "air", "_draw_previous", "_draw_received", "_draw_duration"]
const MISSILE_FIELDS := ["sim_uid", "k", "tgt_o", "mirv_bus", "split_done", "o", "nk", "from", "to", "lt", "ft", "t", "dur", "r", "_draw_previous", "_draw_received", "_draw_duration"]
const PLANE_FIELDS := ["o", "from", "to", "t", "dur", "_draw_previous", "_draw_received", "_draw_duration"]
const MUNITION_FIELDS := ["o", "nk", "from", "to", "t0", "t1"]

var traders: Array
var missiles: Array
var planes: Array
var munitions: Array
var sam_shots: Array = []
var shells: Array = []

var boats: Array
var warships: Array
var nations: Array
var structures: Array
var attacks: Array

func _init(source_nations: Array, source_structures: Array, source_boats: Array = [], source_warships: Array = [], projectiles: Dictionary = {}, source_attacks: Array = []) -> void:
	nations = _copy_fields(source_nations, NATION_FIELDS)
	attacks = _copy_fields(source_attacks, ATTACK_FIELDS)
	for attack: Dictionary in attacks:
		attack.make_read_only()
	attacks.make_read_only()
	boats = _copy_units(source_boats, BOAT_FIELDS)
	warships = _copy_units(source_warships, WARSHIP_FIELDS)
	traders = _copy_units(projectiles.get("traders", []), TRADER_FIELDS)
	missiles = _copy_units(projectiles.get("missiles", []), MISSILE_FIELDS)
	planes = _copy_units(projectiles.get("planes", []), PLANE_FIELDS)
	munitions = _copy_units(projectiles.get("munitions", []), MUNITION_FIELDS)
	for shot: Dictionary in projectiles.get("sam_shots", []):
		var record := {"o": shot.o, "from": shot.from, "t0": shot.t0, "t1": shot.t1, "k": shot.k}
		record["ms"] = null
		if shot.ms != null:
			record.ms = _copy_units([shot.ms], MISSILE_FIELDS)[0]
		record.make_read_only()
		sam_shots.append(record)
	sam_shots.make_read_only()
	for shell: Dictionary in projectiles.get("shells", []):
		var record := shell.duplicate()
		record.make_read_only()
		shells.append(record)
	shells.make_read_only()
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
