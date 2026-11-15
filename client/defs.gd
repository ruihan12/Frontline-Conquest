# Port of the constants of src/shared/Core/Defs.luau the client reads (the Sim keeps its own in
# sim/rules.gd; client/game_state.gd translates between the two).
class_name Defs
extends RefCounted

const TICK_RATE := 10

const T_OCEAN := 0
const T_LAKE := 1
const T_PLAINS := 2
const T_HIGHLAND := 3
const T_MOUNTAIN := 4
const T_TUNDRA := 5
const T_ICECAP := 6

const KIND_NATION := 0
const KIND_TRIBE := 1
const KIND_HUMAN := 2

const PHASE_SPAWN := 0
const PHASE_PLAYING := 1
const PHASE_OVER := 2

const S_CITY := 0
const S_PORT := 1
const S_FACTORY := 2
const S_DEFENSE := 3
const S_SAM := 4
const S_SILO := 5
const S_ARTILLERY := 6
const S_AIRFIELD := 7
const S_RAILGUN := 8
const STRUCT_KIND_COUNT := 9
const STRUCT_NAMES: Array[String] = ["city", "port", "factory", "defense", "sam", "silo", "artillery", "airfield", "railgun"]
const STRUCT_TITLES: Array[String] = ["City", "Port", "Factory", "Defense Post", "SAM Launcher", "Missile Silo", "Artillery", "Airfield", "Railgun"]

const U_TRANSPORT := 0
const U_TRADE := 1
const U_WARSHIP := 2
const U_TRUCK := 3
const UNIT_KIND_COUNT := 4

const N_ATOM := 0
const N_HYDROGEN := 1
const N_MIRV := 2
const N_WARHEAD := 3
const N_MEGA := 4
const N_SCATTER := 5
const N_SHELL := 6
const N_AIRSTRIKE := 7
const N_SLUG := 8
const NUKE_KIND_COUNT := 9
const NUKE_NAMES: Array[String] = ["atom", "hydrogen", "mirv", "warhead", "mega", "scatter", "shell", "airstrike", "slug"]

const F_FALLOUT := 1

const DEL_ARRIVED := 0
const DEL_DESTROYED := 1
const DEL_INTERCEPTED := 2
const DEL_CAPTURED := 3

const MSG_INFO := 0
const MSG_GOOD := 1
const MSG_BAD := 2
const MSG_ALERT := 3
const MSG_ALLIANCE := 4

const OVER_DOMINATION := 0
const OVER_TIME := 1
const OVER_DEFEATED := 2
const OVER_ABANDONED := 3


## Godot round(): half away from zero.
static func round_i(x: float) -> int:
	return int(round(x))


static func struct_kind_from_name(kind_name: String) -> int:
	return STRUCT_NAMES.find(kind_name)


static func nuke_kind_from_name(kind_name: String) -> int:
	return NUKE_NAMES.find(kind_name)

const NUKE_TITLES: Array[String] = ["Atom Bomb", "Hydrogen Bomb", "MIRV", "Warhead", "Mega Nuke", "Scattershot", "Artillery Shell", "Air Strike", "Railgun Slug"]
