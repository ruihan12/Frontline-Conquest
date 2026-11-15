# Port of src/client/Map/ViewRules.luau (scripts/view/view_rules.gd): gameplay numbers the view
# draws (SAM / defense ranges, nuke radii, interception odds), read from the rules at run time so
# range rings and aim previews follow the sim when it is retuned.
#
# Range metric (must match the sim): covered <=> (dx * xs)^2 + dy^2 <= r^2 in grid tiles, dx
# wrapping at W, xs = max(cos(lat of the target tile's row), 0.08).
#
# Here the rules are this port's SimRules instance for the current map (game.sim_rules): ranges
# are in its tiles. (The port's own range system for nukes is the game's NUKE_R / silo_for.)
class_name ViewRules
extends RefCounted

static var _rules: SimRules = null
static var _base: SimRules = null


## Draw with `rules` (the bound map's SimRules); null = the K_LIN 1 defaults.
static func use(rules: SimRules = null) -> void:
	_rules = rules


static func _r() -> SimRules:
	if _rules != null:
		return _rules
	if _base == null:
		_base = SimRules.new()
	return _base


## SAM interception range (tiles) for a SAM of `level`.
static func sam_range(level: int = 1) -> float:
	return _r().sam_range(level)


## SAM range `ticks_since_upgrade` ticks after it reached `level` (grows over SAM_UPGRADE_TICKS).
static func sam_range_at(level: int, ticks_since_upgrade: int) -> float:
	return _r().sam_range_at(level, ticks_since_upgrade)


static func sam_upgrade_ticks() -> int:
	return SimRules.SAM_UPGRADE_TICKS


## Construction time (ticks) of structure kind `kind` (Defs.S_*).
static func build_ticks(kind: int) -> int:
	var bt: Array = SimRules.BUILD_TICKS
	return int(bt[kind]) if kind >= 0 and kind < bt.size() else 0


## Warship patrol radius around its patrol point (tiles).
static func warship_patrol_range() -> float:
	return _r().warship_patrol()


## Warship targeting range (tiles).
static func warship_target_range() -> float:
	return _r().warship_range()


## The Arsenal: an Artillery battery's range and an Airfield's reach (tiles).
static func artillery_range() -> float:
	return _r().artillery_range()


static func airfield_range() -> float:
	return _r().airfield_range()


## Defense-post protection radius (tiles).
static func defense_range() -> float:
	return float(_r().defense_range)


## [inner, outer] blast radii in tiles of nuke kind `kind` (Defs.N_*). MIRV: 0, spread.
static func nuke_radii(kind: int) -> Vector2:
	return _r().nuke_radii_full_scaled(kind)


## Nuke kind (Defs.N_*) whose outer radius rounds to `radius_tiles`, or -1.
static func nuke_kind_for_radius(radius_tiles: int) -> int:
	for k: int in [Defs.N_ATOM, Defs.N_HYDROGEN, Defs.N_MIRV]:
		var o := nuke_radii(k).y
		if o > 0.0 and (int(floor(o)) == radius_tiles or Defs.round_i(o) == radius_tiles):
			return k
	return -1


## Radius of a human player's spawn disk.
static func spawn_radius() -> float:
	return float(_r().spawn_radius)


## Chance that one ready hostile SAM shoots down nuke kind `kind` (0 = can't be intercepted).
static func intercept_p(kind: int) -> float:
	var p: Array = SimRules.NUKE_INTERCEPT_P
	return float(p[kind]) if kind >= 0 and kind < p.size() else 1.0


## Squared range distance (tiles) from structure tile `centre` to tile `t` in the sim's metric,
## on a map `w` by `h` tiles.
static func range_d2(centre: int, t: int, w: int, h: int) -> float:
	@warning_ignore("integer_division")
	var cy := centre / w
	@warning_ignore("integer_division")
	var ty := t / w
	var dx := absi(centre % w - t % w)
	dx = mini(dx, w - dx)
	var lat := (0.5 - (float(ty) + 0.5) / float(h)) * PI
	var xs := maxf(cos(lat), 0.08)
	var dy := float(cy - ty)
	return (dx * xs) * (dx * xs) + dy * dy
