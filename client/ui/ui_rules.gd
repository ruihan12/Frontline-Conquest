# Port of src/client/UI/UIRules.luau (scripts/ui/ui_rules.gd).
# Client-side game knowledge for the interface: build/nuke catalogue, costs (via Rules), what a
# click on a tile would do, radial-menu contents and placement checks. These are hints only; the
# Sim validates every intent for real.
#
# Rules(): the port's SimRules (sim/rules.gd). Costs come from the game's own pricing
# (main.build_cost), which keeps the port's additions (the ICBM fee) in the numbers shown.
class_name UIRules
extends RefCounted

const BUILD_KINDS: Array[String] = ["city", "port", "factory", "defense", "sam", "silo", "warship"]
const NUKE_KINDS: Array[String] = ["atom", "hydrogen", "mirv"]
## Hotkeys 1..9, 0 in this order.
const ACTIONS: Array[String] = ["city", "port", "factory", "defense", "sam", "silo", "warship", "atom", "hydrogen", "mirv"]
const HOTKEYS: Array[String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
## The Arsenal's kinds, in the order of its tray: structures, munitions launched like a nuke (the
## last two from their own structure: strikes), and the Reinforcements call.
const ARSENAL_BUILD: Array[String] = ["artillery", "airfield", "railgun"]
const ARSENAL_NUKES: Array[String] = ["mega", "scatter", "airstrike", "slug"]
const ARSENAL: Array[String] = ["artillery", "airfield", "railgun", "mega", "scatter", "airstrike", "slug", "reinforce"]

const TITLES := {
	"city": "City", "port": "Port", "factory": "Factory", "defense": "Defense Post",
	"sam": "SAM Launcher", "silo": "Missile Silo", "warship": "Warship", "atom": "Atom Bomb",
	"hydrogen": "Hydrogen Bomb", "mirv": "MIRV", "artillery": "Artillery", "airfield": "Airfield",
	"railgun": "Railgun", "mega": "Mega Nuke", "scatter": "Scattershot", "airstrike": "Air Strike",
	"slug": "Railgun Shot", "reinforce": "Reinforcements",
}
const SHORT := {
	"city": "City", "port": "Port", "factory": "Factory", "defense": "Defense", "sam": "SAM",
	"silo": "Silo", "warship": "Warship", "atom": "Atom", "hydrogen": "H-Bomb", "mirv": "MIRV",
	"artillery": "Artillery", "airfield": "Airfield", "railgun": "Railgun", "mega": "Mega",
	"scatter": "Scatter", "airstrike": "Strike", "slug": "Slug", "reinforce": "Troops",
}
const BLURBS := {
	"city": "Raises your troop cap by {city}. Joins the road network.",
	"port": "Coastal. Sends trade ships for gold and builds warships.",
	"factory": "Road hub. Trucks pay gold at every stop they pass.",
	"defense": "Land within {def_r} tiles costs attackers {def_mag}x the troops and {def_cost}x the time.",
	"sam": "Shoots down bombs aimed within {sam_r} tiles. MIRV warheads can't be stopped.",
	"silo": "Required to launch nuclear weapons.",
	"warship": "Patrols where you send it: sinks transports, then warships, and captures trade ships. Heals at your ports.",
	"atom": "Small blast that wipes troops and structures, leaving fallout.",
	"hydrogen": "Massive blast. Anything inside is erased.",
	"mirv": "Splits into up to {mirv_n} warheads that rain over one nation.",
	"artillery": "Shells every enemy within {art_r} tiles on its own: their troops, and the structures it reaches.",
	"airfield": "Flies Air Strikes on any spot within {air_r} tiles. Rearms in {air_s} s.",
	"railgun": "Fires at any spot on the map. Reloads in {rail_s} s.",
	"mega": "Twice an Atom Bomb's radius: four times the ground, gone.",
	"scatter": "An Atom Bomb with {scat_lo} to {scat_hi} warheads that come down around it.",
	"airstrike": "Bombs a {air_blast}-tile circle: kills troops and wrecks structures. No SAM can stop it.",
	"slug": "A slug that takes a level off every structure it hits. Nothing intercepts it.",
	"reinforce": "Brings a fifth of your troop cap at once. Ready again every {rein_s} s.",
}
## Rules.NUKE_LAUNCHER: the structure a munition leaves from.
const NUKE_LAUNCHER := {Defs.N_AIRSTRIKE: Defs.S_AIRFIELD, Defs.N_SLUG: Defs.S_RAILGUN}
## Structure kinds an own structure of the same kind upgrades instead of a new build (defense posts
## are not upgradable).
const UPGRADABLE: Array[String] = ["city", "port", "factory", "sam", "silo"]
## Bulk menus (four fixed slots: x1, two steps, then the most the player can do right now).
const STRUCTURE_BULK_STEPS: Array[int] = [5, 10]
const NUKE_BULK_STEPS: Array[int] = [2, 5]
const MAX_BULK := 50

var ctx: UICtx
# One-entry cache for primary(): hover card and the following click ask about the same tile.
var _pc_tile := -1
var _pc_msec := 0.0
var _pc_tick := -1
var _pc_ratio := -1.0
var _pc := {}
# Local owner's structure counts by kind (index = Defs.S_*) plus warships and transports.
var _scount: Array[int] = []
var _warships := 0
var _transports := 0
var _counted_owner := -1
var _counted_key := -1
var _m := {}


func _init(c: UICtx) -> void:
	ctx = c
	_scount.resize(Defs.STRUCT_KIND_COUNT)
	_scount.fill(0)


## The port's SimRules instance (sim/rules.gd), or a default one before a match.
func rules() -> SimRules:
	var s = ctx.state
	if s != null and s.g != null and s.g.sim_rules != null:
		return s.g.sim_rules
	return SimRules.new()


## Godot String.format({key: value}): replaces {key} placeholders.
static func format(text: String, values: Dictionary) -> String:
	return text.format(values)


## Blurb with its numbers filled in from Rules.
func blurb(kind: String) -> String:
	var R := rules()
	return format(BLURBS.get(kind, ""), {
		"city": UITheme.fmt_troops(R.city_troops_shown()),
		"def_r": str(Defs.round_i(R.defense_range)),
		"def_mag": str(Defs.round_i(SimRules.DEFENSE_POST_MAG)),
		"def_cost": str(Defs.round_i(SimRules.DEFENSE_POST_COST)),
		"sam_r": str(Defs.round_i(R.sam_range(1))),
		"mirv_n": str(SimRules.MIRV_WARHEADS),
		"art_r": str(Defs.round_i(R.artillery_range())),
		"air_r": str(Defs.round_i(R.launch_range(Defs.N_AIRSTRIKE))),
		"air_s": str(SimRules.RELOAD_TICKS[Defs.S_AIRFIELD] / Defs.TICK_RATE),
		"rail_s": str(SimRules.RELOAD_TICKS[Defs.S_RAILGUN] / Defs.TICK_RATE),
		"air_blast": str(Defs.round_i(R.nuke_radii_full_scaled(Defs.N_AIRSTRIKE).y)),
		"scat_lo": str(SimRules.SCATTER_MIN),
		"scat_hi": str(SimRules.SCATTER_MAX),
		"rein_s": str(SimRules.REINFORCE_COOLDOWN_TICKS / Defs.TICK_RATE),
	})


## The Arsenal item (Data/Arsenal) a build / launch kind belongs to; null for the kinds everyone has.
static func arsenal_item(kind: String):
	return ArsenalData.item_for(kind)


## True when `kind` is an Arsenal kind the player hasn't unlocked.
func arsenal_locked(kind: String) -> bool:
	var it = arsenal_item(kind)
	if it == null:
		return false
	var s = ctx.session
	return not (s != null and s.has_method("has_unlock") and s.has_unlock(it.key))


## A strike: a munition its own structure fires (an Air Strike, a Railgun shot), not a silo.
static func is_strike(kind: String) -> bool:
	return kind == "airstrike" or kind == "slug"


## The structure kind (Defs.S_*) a nuke / strike kind leaves from.
static func launcher(kind: String) -> int:
	var nk := Defs.nuke_kind_from_name(kind)
	return NUKE_LAUNCHER.get(nk, Defs.S_SILO)


## The troops/s label is green while the regrowth rate is >= its previous sample and orange once
## it drops. `last` = NAN (no previous sample) keeps it green.
static func troop_rate_rising(rate: float, last: float = NAN) -> bool:
	return is_nan(last) or rate >= last


## The label text: "+" .. render_troops(rate per second) .. "/s".
static func troop_rate_text(per_second: float) -> String:
	return "+" + UITheme.hud_troops(maxf(per_second, 0.0)) + "/s"


## Aimed at a target tile and launched (the bombs, and the Arsenal's munitions).
static func is_nuke(kind: String) -> bool:
	return kind in ["atom", "hydrogen", "mirv", "mega", "scatter", "airstrike", "slug"]


# ---------------------------------------------------------------------------------------------
# Costs (single adapter over Rules)
# ---------------------------------------------------------------------------------------------
## `owned`: structures of the kinds that share the cost count, warships for "warship", MIRVs
## launched this match for "mirv".
static func rules_cost(kind: String, owned_n: int) -> float:
	if is_nuke(kind):
		var nk := Defs.nuke_kind_from_name(kind)
		return SimRules.NUKE_COST[nk] + (SimRules.MIRV_COST_STEP * owned_n if kind == "mirv" else 0.0)
	return SimRules.build_cost(kind, owned_n)


## [inner, outer] blast radii in tiles (MIRV: 0, spread).
func nuke_radii(kind: String) -> Vector2:
	var k := Defs.nuke_kind_from_name(kind)
	if k < 0:
		return Vector2.ZERO
	# (this port's bombs: the game's own blast radius, with the source's inner share of it)
	var s = ctx.state
	var bid: int = RWGameState.BUILD_ID.get(kind, -1)
	if s != null and s.g.NUKE_R.has(bid) and kind != "mirv":
		var outer := float(s.g.NUKE_R[bid])
		return Vector2(outer * SimRules.inner_frac(k), outer)
	return rules().nuke_radii_full_scaled(k)


func nuke_radius(kind: String) -> int:
	return Defs.round_i(nuke_radii(kind).y)


## "Blast radius" text for tooltips: "15 tiles (6 wiped out)" / MIRV spread.
func blast_text(kind: String) -> String:
	var r := nuke_radii(kind)
	if kind == "mirv":
		# MIRV_WARHEADS is the cap: the real count follows the target's land (55-tile spacing)
		return "Up to %d warheads across the target nation" % SimRules.MIRV_WARHEADS
	if r.x > 0.0:
		return "%d tiles (%d wiped out)" % [Defs.round_i(r.y), Defs.round_i(r.x)]
	return "%d tiles" % Defs.round_i(r.y)


## The victory metric as result-screen copy: `win` = share of the land outside fallout, `land` =
## share of all land.
static func win_phrase(win: float, land: float, fallout: int, all_land: String) -> String:
	var pct := UITheme.fmt_pct(win)
	if fallout > 0 and UITheme.fmt_pct(land) != pct:
		return pct + " of the land outside fallout"
	return pct + all_land


## Seconds for the result screen's "Match duration" card.
static func result_seconds(kind: String, stats: Dictionary) -> float:
	var secs := float(stats.get("duration_s", 0.0))
	if kind != "eliminated" and stats.has("match_s"):
		secs = float(stats["match_s"])
	return secs


## Full recount (on bind / when the local owner changes).
func recount() -> void:
	_m = {}
	_scount.fill(0)
	_warships = 0
	_transports = 0
	var s = ctx.state
	var mine := ctx.me()
	_counted_owner = mine
	if s == null or mine == 0:
		return
	for st in s.structures():
		if st.owner == mine and st.kind >= 0 and st.kind < Defs.STRUCT_KIND_COUNT:
			_scount[st.kind] += 1
	for u in s.units():
		if u.owner == mine:
			if u.kind == Defs.U_WARSHIP:
				_warships += 1
			elif u.kind == Defs.U_TRANSPORT:
				_transports += 1


## (The port's game has no structure / unit signals: the counts are taken again when the tick or the
## number of structures and units moved.)
func _sync() -> void:
	var s = ctx.state
	if s == null:
		return
	var key: int = s.tick * 4096 + s.structures().size() * 64 + s.units().size()
	if _counted_owner != ctx.me() or key != _counted_key:
		_counted_key = key
		recount()


func struct_count(kind: int) -> int:
	_sync()
	return _scount[kind] if (kind >= 0 and kind < Defs.STRUCT_KIND_COUNT) else 0


func transports() -> int:
	_sync()
	return _transports


## Rules.cost_count_kinds: ports and factories share one count.
static func cost_count_kinds(kind: String) -> Array[int]:
	if kind == "port" or kind == "factory":
		return [Defs.S_PORT, Defs.S_FACTORY]
	var out: Array[int] = []
	var k := Defs.struct_kind_from_name(kind)
	if k >= 0:
		out.append(k)
	return out


func owned(kind: String) -> int:
	if ctx.state == null or ctx.me() == 0:
		return 0
	_sync()
	if kind == "warship":
		return _warships
	if kind == "mirv":
		return int(ctx.state.mirvs_launched)
	if is_nuke(kind) or kind == "reinforce":
		return 0
	var n := 0
	for sk in cost_count_kinds(kind):
		n += struct_count(sk)
	return n


## The local player's structures by kind, from one pass over the match's, kept while the tick and
## owner are the same: per kind the level sum, the finished and building counts, the seconds until
## the first one building finishes, and the structures themselves.
func _mine(s) -> Dictionary:
	var mine := ctx.me()
	var n := Defs.STRUCT_KIND_COUNT
	var cnt: int = s.structures().size()
	if not _m.is_empty() and _m.tick == s.tick and _m.me == mine and _m.cnt == cnt:
		return _m
	var m := {"tick": s.tick, "me": mine, "cnt": cnt, "level": [], "act": [], "building": [], "soonest": [], "list": []}
	for k in n:
		m.level.append(0)
		m.act.append(0)
		m.building.append(0)
		m.soonest.append(INF)
		m.list.append([])
	var tick: int = s.tick
	for st in s.structures():
		var k: int = st.kind
		if st.owner != mine or k < 0 or k >= n:
			continue
		m.level[k] += int(st.level)
		if st.active_tick > tick:
			m.building[k] += 1
			m.soonest[k] = minf(m.soonest[k], float(st.active_tick - tick) / Defs.TICK_RATE)
		else:
			m.act[k] += 1
		m.list[k].append(st)
	_m = m
	return m


## Gold for the next `kind` (structures, upgrades, warships, nukes): the Sim's own pricing.
func cost(kind: String) -> float:
	if kind == "reinforce":
		return SimRules.REINFORCE_COST
	if ctx.state == null:
		return rules_cost(kind, 0)
	var k: int = RWGameState.BUILD_ID.get(kind, -1)
	if is_strike(kind) or k < 0:
		return 0.0
	return float(ctx.state.g.build_cost(ctx.me(), k))


## The local player's finished structures of `kind` that can fire now (a silo's loaded missiles, an
## airfield / railgun that isn't reloading), and the seconds until the next one can when none does:
## [ready, wait_seconds].
func ready_launchers(kind: int) -> Array:
	var s = ctx.state
	if s == null:
		return [0, 0.0]
	var cd: int = SimRules.RELOAD_TICKS[kind] if (kind >= 0 and kind < SimRules.RELOAD_TICKS.size()) else 0
	var n := 0
	var soonest := INF
	var mine: Array = _mine(s).list[kind] if (kind >= 0 and kind < Defs.STRUCT_KIND_COUNT) else []
	for st in mine:
		if st.active_tick <= s.tick:
			var busy := 0
			var first := INF
			for t in st.shots:
				if t + cd > s.tick:
					busy += 1
					first = minf(first, t + cd - s.tick)
			var free: int = maxi(0, int(st.level) - busy)
			n += free
			if free == 0:
				soonest = minf(soonest, first)
	return [n, soonest / Defs.TICK_RATE if (n == 0 and soonest < INF) else 0.0]


## Finished (active) structures of `kind` the local player owns: [active, under_construction,
## seconds until the first one finishes].
func active_structs(kind: int) -> Array:
	var s = ctx.state
	if s == null or kind < 0 or kind >= Defs.STRUCT_KIND_COUNT:
		return [0, 0, 0.0]
	var m := _mine(s)
	var building: int = m.building[kind]
	return [m.act[kind], building, m.soonest[kind] if building > 0 else 0.0]


## {ok, locked, reason, cost}: whether the action can be used right now (ignores the target).
func availability(kind: String) -> Dictionary:
	var c := cost(kind)
	var out := {"ok": false, "locked": false, "reason": "", "cost": c}
	var s = ctx.state
	var o = ctx.my()
	# an Arsenal kind the player hasn't unlocked: `arsenal` names the item to offer
	if arsenal_locked(kind):
		var it = arsenal_item(kind)
		out.reason = "Unlock " + it.title + " in the Arsenal"
		out.locked = true
		out["arsenal"] = it.key
		return out
	if s == null or o == null or not ctx.in_match():
		out.reason = "Join a match first"
		out.locked = true
		return out
	if not o.spawned:
		out.reason = "Place your capital first"
		out.locked = true
		return out
	if not o.alive:
		out.reason = "You have been eliminated"
		out.locked = true
		return out
	if s.phase != Defs.PHASE_PLAYING:
		out.reason = "Available once the match begins"
		out.locked = true
		return out
	if is_nuke(kind):
		# the structure it leaves from: a silo, or (strikes) an airfield / a railgun
		var lk := launcher(kind)
		var title: String = Defs.STRUCT_TITLES[lk]
		if struct_count(lk) == 0:
			out.reason = "Requires " + ("an " if lk == Defs.S_AIRFIELD else "a ") + title
			out.locked = true
			return out
		var a := active_structs(lk)
		if a[0] == 0:
			var what := "Silo" if lk == Defs.S_SILO else title
			out.reason = what + " under construction · ready in " + UITheme.fmt_time(ceil(a[2]))
			out.locked = true
			return out
		if is_strike(kind):
			var rl := ready_launchers(lk)
			if rl[0] == 0:
				out.reason = "%s · ready in %s" % ["Airfield rearming" if lk == Defs.S_AIRFIELD else "Railgun reloading", UITheme.fmt_time(ceil(rl[1]))]
				return out
	if kind == "reinforce":
		var wait: int = int(s.reinforce_ready(o.id)) - int(s.tick)
		if wait > 0:
			out.reason = "Ready in " + UITheme.fmt_time(ceil(float(wait) / Defs.TICK_RATE))
			return out
		if SimRules.reinforce_troops(o.troops, o.max_troops) <= 0:
			out.reason = "Your army is at its cap"
			return out
	if kind == "port" and not s.has_coast(o.id):
		out.reason = "Requires a coastline"
		out.locked = true
		return out
	if kind == "warship" and struct_count(Defs.S_PORT) == 0:
		out.reason = "Requires a Port"
		out.locked = true
		return out
	if kind == "warship":
		var ap := active_structs(Defs.S_PORT)
		if ap[0] == 0:
			out.reason = "Port under construction · ready in " + UITheme.fmt_time(ceil(ap[2]))
			out.locked = true
			return out
	if c < 0:
		out.reason = "Unavailable"
		out.locked = true
		return out
	if float(o.gold) < c:
		out.reason = "Need " + UITheme.fmt_num(c - o.gold) + " more gold"
		return out
	out.ok = true
	return out


## Missiles loaded right now in the local player's finished silos (a silo holds one per level).
func ready_missiles() -> int:
	var s = ctx.state
	if s == null:
		return 0
	var mine := ctx.me()
	var cd: int = SimRules.SILO_COOLDOWN_TICKS
	var n := 0
	for st in s.structures():
		if st.owner == mine and st.kind == Defs.S_SILO and st.active_tick <= s.tick:
			var busy := 0
			for t in st.shots:
				if t + cd > s.tick:
					busy += 1
			n += maxi(0, int(st.level) - busy)
	return n


## Total gold for `amount` more of `kind` in a row (upgrades: each level at the next price).
func bulk_cost(kind: String, amount: int) -> float:
	if is_nuke(kind):
		return cost(kind) * amount
	var count := owned(kind) if ctx.state != null else 0
	var total := 0.0
	for i in amount:
		total += SimRules.build_cost(kind, count + i)
	return total


## The most of `kind` the local player can buy in a row now (gold; bombs: loaded missiles too).
func bulk_max(kind: String) -> int:
	var o = ctx.my()
	var gold: float = float(o.gold) if o != null else 0.0
	var cap := MAX_BULK
	if is_nuke(kind):
		cap = mini(cap, ready_missiles())
	var most := 0
	for n in range(1, cap + 1):
		if bulk_cost(kind, n) > gold:
			break
		most = n
	return most


## The amount ring for `kind` (id prefix "build" / "nuke") when more than one is possible, else [].
func bulk_ring(prefix: String, kind: String) -> Array:
	var most := bulk_max(kind)
	if most <= 1:
		return []
	var nuke := is_nuke(kind)
	var steps := NUKE_BULK_STEPS if nuke else STRUCTURE_BULK_STEPS
	var slots := [1, steps[0], steps[1], most]
	var ring := []
	var loaded: int = ready_missiles() if nuke else (1 << 30)
	for n in slots:
		var c := bulk_cost(kind, n)
		var ok: bool = n <= most
		var reason := ""
		if not ok:
			reason = ("Only %d missile%s loaded" % [loaded, "" if loaded == 1 else "s"]) if (nuke and n > loaded) else "Not enough gold"
		ring.append({
			"id": "%s:%s:%d" % [prefix, kind, n],
			# (the fourth slot is the most affordable: its amount says how many)
			"label": "×%d · %s" % [n, UITheme.fmt_cost(c)],
			"icon": kind,
			"ok": ok,
			"reason": reason,
			"danger": nuke,
			"cost": c,
		})
	return ring


## Radius (our tiles) a build tap searches the player's own land for a valid site (15 full-size
## tiles).
func snap_radius() -> float:
	return rules().place_search_r()


## Friendly copy for Rules.placement reasons.
const PLACE_REASONS := {
	"not_own": "Build on your own land",
	"no_room": "No room here: structures need space",
	"no_coast": "Ports must be on your coast",
	"no_port": "Warships need a finished port on this water",
	"gold": "Not enough gold",
	"invalid": "Can't build here",
}


## Where a build tap at `tile` really lands: {ok, tile, reason, warn, upgrade, sid, level}.
## (The game's own check answers: main.build_req, which snaps and upgrades when the order is given.)
func resolve_placement(kind: String, tile: int) -> Dictionary:
	var out := {"ok": false, "tile": tile, "reason": "", "warn": "", "upgrade": false, "sid": 0, "level": 1}
	var s = ctx.state
	if s == null or tile < 0:
		out.reason = "Point at the map"
		return out
	if is_nuke(kind):
		var pl := _placement_exact(kind, tile)
		out.ok = pl.ok
		out.reason = pl.reason
		out.warn = pl.warn
		return out
	var k: int = RWGameState.BUILD_ID.get(kind, -1)
	var req: String = s.g.build_req(k, tile) if k >= 0 else "Can't build here"
	if kind == "warship":
		out.ok = req == ""
		out.reason = req
		return out
	out.ok = req == ""
	out.reason = req
	# an own structure of the same upgradable kind under the tap: the order upgrades it
	if out.ok and kind in UPGRADABLE:
		var st = ctx.structure_at(tile, 1)
		if st != null and st.owner == ctx.me() and st.kind == Defs.struct_kind_from_name(kind):
			out.upgrade = true
			out.sid = st.sid
			out.level = int(st.level) + 1
			out.tile = st.tile
	return out


## {ok, reason, warn, tile, upgrade, level} for placing `kind` at `tile` (availability is checked
## separately).
func placement(kind: String, tile: int) -> Dictionary:
	if is_nuke(kind):
		return _placement_exact(kind, tile)
	return resolve_placement(kind, tile)


## True when a finished structure of `skind` of the local player's that can fire now is within the
## reach of munition `nkind` from `tile` (no reach limit: any such structure).
func in_reach(skind: int, nkind: int, tile: int) -> bool:
	var s = ctx.state
	if s == null:
		return false
	var mine := ctx.me()
	var reach: float = rules().launch_range(nkind)
	var cd: int = SimRules.RELOAD_TICKS[skind]
	var w: int = s.map.W
	for st in s.structures():
		if st.owner == mine and st.kind == skind and st.active_tick <= s.tick:
			var busy := 0
			for t in st.shots:
				if t + cd > s.tick:
					busy += 1
			if busy < int(st.level):
				@warning_ignore("integer_division")
				var d := Vector2(st.tile % w - tile % w, st.tile / w - tile / w)
				if reach <= 0 or d.length_squared() <= reach * reach:
					return true
	return false


func _placement_exact(kind: String, tile: int) -> Dictionary:
	var out := {"ok": false, "reason": "", "warn": ""}
	var s = ctx.state
	if s == null or tile < 0:
		out.reason = "Point at the map"
		return out
	var map = s.map
	var own: int = s.tile_owner(tile)
	var mine := ctx.me()
	if is_nuke(kind):
		if own == mine and own != 0:
			out.reason = "That is your own land"
			return out
		if not map.is_land(tile) and kind != "mirv":
			out.warn = "Open water: little to hit"
		if own != 0 and s.are_allies(mine, own):
			out.warn = "Breaks your alliance with " + s.owner_name(own)
		if kind == "mirv" and own == 0:
			out.reason = "Target a nation"
			return out
		if is_strike(kind):
			# a strike never hits an ally, and an air strike needs a ready airfield within reach
			out.warn = ""
			if own != 0 and s.are_allies(mine, own):
				out.reason = "That is your ally's land"
				return out
			if kind == "airstrike" and not in_reach(Defs.S_AIRFIELD, Defs.N_AIRSTRIKE, tile):
				out.reason = "Out of your Airfields' reach"
				return out
			if own == 0:
				out.warn = "Nobody's land: nothing to hit"
		# (this port's range system: the game says whether a silo reaches the spot)
		var k: int = RWGameState.BUILD_ID.get(kind, -1)
		var req: String = s.g.build_req(k, tile) if k >= 0 else ""
		if req != "":
			out.reason = req
			return out
		if k >= 0 and s.g.NUKE_R.has(k):
			@warning_ignore("integer_division")
			var tp := Vector2(tile % int(map.W) + 0.5, tile / int(map.W) + 0.5)
			if s.g.silo_for(mine, k, tp).is_empty() and not s.g.nearest_silo(mine, tp).is_empty():
				out.reason = "Out of range (%s): build a closer silo or turn ICBM on" % s.g.nuke_range_label(k)
				return out
		out.ok = true
		return out
	if kind == "warship":
		if map.is_water(tile) or own == mine:
			out.ok = true
		else:
			out.reason = "Target water near your ports"
		return out
	if own != mine:
		out.reason = "Build on your own land"
		return out
	if kind == "port" and not map.is_coastal(tile):
		out.reason = "Ports must be on the coast"
		return out
	out.ok = true
	return out


# ---------------------------------------------------------------------------------------------
# Primary click
# ---------------------------------------------------------------------------------------------
## Where a boat aimed at `tile` lands: the nearest coastal tile of the same owner (unclaimed land
## for owner 0) that one of our coasts reaches by sea, so clicking anywhere on a territory across the
## water works, not only its shore pixel. Searches rings out to BOAT_SNAP_FULL full-size tiles; -1
## when none.
const BOAT_SNAP_FULL := 120.0


func boat_landing(tile: int) -> int:
	var s = ctx.state
	if s == null or tile < 0:
		return -1
	var map = s.map
	var borders = ctx.borders
	if map.is_coastal(tile) and borders.can_reach_by_sea(tile):
		return tile
	var own: int = s.tile_owner(tile)
	var w: int = map.W
	var h: int = map.H
	var rmax := int(ceil(BOAT_SNAP_FULL / maxf(map.k_lin, 0.01)))
	var cx := tile % w
	@warning_ignore("integer_division")
	var cy := tile / w
	var best := -1
	var best_d := INF
	for r in range(1, rmax + 1):
		# the ring at Chebyshev distance r
		for dy in range(-r, r + 1):
			var y := cy + dy
			if y < 0 or y >= h:
				continue
			var edge := dy == -r or dy == r
			var dx := -r
			while dx <= r:
				var x := cx + dx
				if x >= 0 and x < w:
					var t := y * w + x
					if map.is_coastal(t) and s.tile_owner(t) == own and borders.can_reach_by_sea(t):
						var d := float(dx * dx + dy * dy)
						if d < best_d:
							best = t
							best_d = d
				dx += 1 if edge else 2 * r
		# a hit on ring r: nothing farther than r * sqrt(2) can be closer
		if best >= 0 and r * r >= best_d / 2:
			break
	return best


## {type: spawn|expand|attack|boat|inspect|none, ok, reason, target, troops, verb, icon}
func primary(tile: int) -> Dictionary:
	var now := UICtx.msec()
	var t: int = ctx.state.tick if ctx.state != null else -1
	if tile == _pc_tile and now - _pc_msec < 400 and t == _pc_tick and absf(ctx.ratio - _pc_ratio) < 1e-6:
		return _pc.duplicate()
	var res := _primary(tile)
	_pc_tile = tile
	_pc_msec = now
	_pc_tick = t
	_pc_ratio = ctx.ratio
	_pc = res
	return res.duplicate()


## Drops the primary() cache (tests / after the world changed under the same tick).
func invalidate() -> void:
	_pc_tile = -1


func _primary(tile: int) -> Dictionary:
	var out := {"type": "none", "ok": false, "reason": "", "target": 0, "troops": 0.0, "verb": "", "icon": "info"}
	var s = ctx.state
	if s == null or tile < 0 or tile >= s.map.W * s.map.H:
		return out
	var map = s.map
	var mine := ctx.me()
	var own: int = s.tile_owner(tile)
	out.target = own
	if mine == 0 or not ctx.in_match():
		out.type = "inspect"
		out.ok = own != 0
		return out
	var o = ctx.my()
	if s.phase == Defs.PHASE_SPAWN or ctx.needs_spawn():
		if o != null and o.spawned and own == mine:
			out.type = "inspect"
			out.ok = true
			return out
		if map.is_contestable(tile) and own == 0 and not s.has_fallout(tile):
			out.type = "spawn"
			out.ok = true
			out.verb = "Start here"
			out.icon = "target"
		else:
			out.reason = "Pick unclaimed land" if map.is_land(tile) else "Pick land, not water"
		return out
	if s.phase != Defs.PHASE_PLAYING or o == null or not o.alive:
		out.type = "inspect"
		out.ok = own != 0
		return out
	if own == mine or (own != 0 and s.are_allies(mine, own)):
		out.type = "inspect"
		out.ok = true
		return out
	if not map.is_contestable(tile):
		out.reason = "Antarctica cannot be claimed" if ctx.terrain_at(tile) == Defs.T_ICECAP else ""
		return out
	# Fallout stays until the land is conquered again; taking it is slow and costly.
	var fallout: bool = own == 0 and s.has_fallout(tile)
	var share := ctx.order_ratio()
	var troops: float = float(o.troops) * share
	out.troops = troops
	if troops < 1.0:
		# (the floor under a new player's army: UICtx.troop_floor)
		out["floor"] = share < ctx.ratio
		out.reason = "Keep some troops at home for now" if out["floor"] else "No troops available"
		return out
	var land := false
	if s.borders_tile(mine, tile):
		land = true
	elif own == 0:
		var touch: int = ctx.borders.region_touches_me(tile)
		land = touch == 1 or (touch == -1 and ctx.borders.borders_owner(0))
	else:
		land = ctx.borders.borders_owner(own)
	if land:
		out.type = "expand" if own == 0 else "attack"
		out.ok = true
		out.verb = ("Expand into fallout" if fallout else "Expand") if own == 0 else "Attack"
		out.icon = "attack"
		return out
	var landing := boat_landing(tile)
	if landing >= 0:
		out["boat_tile"] = landing
		var max_boats: int = SimRules.MAX_BOATS_PLAYER
		if transports() >= max_boats:
			out.type = "boat"
			out.reason = "All %d transports at sea" % max_boats
			out.icon = "boat"
			return out
		out.type = "boat"
		out.ok = true
		out.verb = "Boat invasion"
		out.icon = "boat"
		return out
	out.reason = "Out of reach: expand toward it" if own == 0 else "No border or sea route"
	return out


func primary_intent(tile: int, action: Dictionary) -> Dictionary:
	var ty := str(action.get("type", ""))
	if ty == "spawn":
		return {"type": "spawn", "tile": tile}
	elif ty == "expand" or ty == "attack":
		return {"type": "attack", "tile": tile, "ratio": ctx.order_ratio()}
	elif ty == "boat":
		return {"type": "boat", "tile": int(action.get("boat_tile", tile)), "ratio": ctx.order_ratio()}
	return {}


## Short sentence for the floating confirmation ("Attacking Brazil with 24.5K").
func confirm_text(action: Dictionary) -> String:
	var s = ctx.state
	var troops := UITheme.fmt_troops(float(action.get("troops", 0.0)))
	var target := int(action.get("target", 0))
	var ty := str(action.get("type", ""))
	if ty == "spawn":
		return "Starting position set"
	elif ty == "expand":
		return "Expanding with " + troops
	elif ty == "attack":
		return "Attacking %s with %s" % [s.owner_name(target), troops]
	elif ty == "boat":
		if target == 0:
			return "Boat launched with " + troops
		return "Invading %s by sea with %s" % [s.owner_name(target), troops]
	return ""


# ---------------------------------------------------------------------------------------------
# Radial menu
# ---------------------------------------------------------------------------------------------
## A donation to ally `own` at the current attack ratio, limited to the ally's troop headroom:
## {amount, want, room, cap, capped (amount < want), full (no useful room: < 1 % of cap)}.
func donate_plan(own: int) -> Dictionary:
	var want := floorf(ctx.troops_for_ratio())
	var s = ctx.state
	var o = s.get_owner(own) if (s != null and own != 0) else null
	var cap: float = float(o.max_troops) if o != null else 0.0
	var room := want
	if cap > 0:
		room = maxf(0.0, floorf(cap - float(o.troops)))
	var amount := maxf(0.0, minf(want, room))
	return {"amount": amount, "want": want, "room": room, "cap": cap, "capped": amount < want, "full": cap > 0 and room < maxf(1.0, cap * 0.01)}


## Items: {id, label, icon, ok, reason, danger, sub: [items]}
func radial_items(tile: int) -> Array:
	var items := []
	var s = ctx.state
	if s == null or tile < 0:
		return items
	var mine := ctx.me()
	var own: int = s.tile_owner(tile)
	var playing: bool = s.phase == Defs.PHASE_PLAYING and ctx.alive_player() and not ctx.needs_spawn()
	var land: bool = s.map.is_contestable(tile)
	if playing and land and own != mine and not s.are_allies(mine, own):
		var p := primary(tile)
		var is_boat := str(p.type) == "boat"
		var verb := "Expand" if own == 0 else "Attack"
		var atk := {"id": "attack", "label": verb, "icon": "attack", "ok": p.ok and not is_boat, "reason": "", "danger": false}
		if is_boat:
			atk.reason = "No land border: send a boat"
		elif not p.ok:
			atk.reason = str(p.reason)
		items.append(atk)
		var boat := {"id": "boat", "label": "Boat", "icon": "boat", "ok": false, "reason": "", "danger": false}
		if boat_landing(tile) < 0:
			boat.reason = "None of your coasts reach it" if s.map.is_coastal(tile) else "No coast of theirs within reach"
		elif transports() >= SimRules.MAX_BOATS_PLAYER:
			boat.reason = "All transports are at sea"
		elif ctx.troops_for_ratio() < 1.0:
			boat.reason = "No troops available"
		else:
			boat.ok = true
		items.append(boat)
	if playing and own != mine and mine != 0:
		for a in s.attacks():
			if a.attacker == mine and a.target == own:
				items.append({"id": "retreat", "label": "Retreat", "icon": "retreat", "ok": true, "reason": "", "danger": false})
				break
	if playing and own == mine:
		var sub := []
		# (the Arsenal's structures the player has unlocked come after the others)
		var build_kinds: Array[String] = BUILD_KINDS.duplicate()
		for k in ARSENAL_BUILD:
			if not arsenal_locked(k):
				build_kinds.append(k)
		for k in build_kinds:
			var av := availability(k)
			var pl := placement(k, tile)
			var ok: bool = av.ok and pl.ok
			var it := {"id": "build:" + k, "label": SHORT[k], "icon": k, "ok": ok, "reason": str(av.reason) if not av.ok else str(pl.reason), "danger": false, "cost": av.cost}
			# an existing structure here: level it up several times at once (bulk upgrade)
			if ok and pl.get("upgrade", false):
				var ring := bulk_ring("build", k)
				if not ring.is_empty():
					it["sub"] = ring
			sub.append(it)
		items.append({"id": "build", "label": "Build", "icon": "city", "ok": true, "reason": "", "danger": false, "sub": sub})
	# what can be launched at the tile: the bombs with a silo, and the Arsenal's munitions the player
	# has unlocked (a strike with its own structure)
	var launch_kinds: Array[String] = []
	if playing and own != mine and mine != 0:
		var kinds: Array[String] = NUKE_KINDS.duplicate()
		for k in ARSENAL_NUKES:
			if not arsenal_locked(k):
				kinds.append(k)
		for k in kinds:
			if struct_count(launcher(k)) > 0:
				launch_kinds.append(k)
	if launch_kinds.size() > 0:
		var nsub := []
		for k2 in launch_kinds:
			var av2 := availability(k2)
			var pl2 := placement(k2, tile)
			var ok2: bool = av2.ok and pl2.ok
			var it2 := {"id": "nuke:" + k2, "label": SHORT[k2], "icon": k2, "ok": ok2, "reason": str(av2.reason) if not av2.ok else str(pl2.reason), "danger": true, "cost": av2.cost}
			# atom bombs stack (x2 against a SAM): a bulk launch
			if ok2 and k2 == "atom":
				var ring2 := bulk_ring("nuke", k2)
				if not ring2.is_empty():
					it2["sub"] = ring2
			nsub.append(it2)
		var only_strikes := struct_count(Defs.S_SILO) == 0
		items.append({"id": "nuke", "label": "Strike" if only_strikes else "Nuke", "icon": launch_kinds[0] if only_strikes else "atom", "ok": true, "reason": "", "danger": true, "sub": nsub})
	if playing and own != 0 and own != mine:
		var target_info = s.get_owner(own)
		if s.are_allies(mine, own):
			var plan := donate_plan(own)
			items.append({
				"id": "donate", "label": "Donate", "icon": "donate",
				"ok": plan.want >= 1 and not plan.full,
				"reason": "No troops to spare" if plan.want < 1 else ("At their troop cap" if plan.full else ""),
				"danger": false, "troops": plan.amount, "capped": plan.capped,
			})
			# port-only: this port's gold donation (a quarter of the treasury)
			var me_o = ctx.my()
			var gold: float = floorf(float(me_o.gold) * 0.25) if me_o != null else 0.0
			items.append({"id": "donate_gold", "label": "Gold", "icon": "gold", "ok": gold >= 1.0, "reason": "No gold to spare" if gold < 1.0 else "", "danger": false, "note": UITheme.fmt_num(gold) + " gold (25%)"})
			# the last ALLIANCE_EXTEND_WINDOW_TICKS: ask to renew (renewed once both asked)
			var ai = s.alliance_info(mine, own)
			if ai != null and ai.in_window:
				items.append({"id": "ally_extend", "label": "Renew", "icon": "alliance", "ok": ai.can_extend, "reason": "Renewal asked" if ai.me_asked else "", "danger": false})
			# (a teammate is no alliance: nothing to betray). Never in one tap: the sub-ring asks first.
			if s.has_alliance(mine, own):
				items.append({"id": "ally_break", "label": "Betray", "icon": "betray", "ok": true, "reason": "", "danger": true,
					"sub": [
						{"id": "ally_break:yes", "label": "Betray", "icon": "betray", "ok": true, "reason": "", "danger": true, "note": "You become a Traitor for %d s" % int(SimRules.TRAITOR_TICKS / SimRules.TICK_RATE)},
						{"id": "cancel", "label": "Keep", "icon": "alliance", "ok": true, "reason": "", "danger": false},
					]})
		elif s.has_request(own, mine):
			items.append({"id": "ally_accept", "label": "Accept", "icon": "alliance", "ok": true, "reason": "", "danger": false})
		elif s.has_request(mine, own):
			items.append({"id": "ally_request", "label": "Ally", "icon": "alliance", "ok": false, "reason": "Request pending", "danger": false})
		elif target_info != null and target_info.alive:
			# a new request waits 30 s after the previous one (Rules.ALLY_REQUEST_COOLDOWN_TICKS)
			var wait: int = s.request_cooldown_left(mine, own)
			items.append({"id": "ally_request", "label": "Ally", "icon": "alliance", "ok": wait <= 0, "reason": "Wait %ds" % int(ceil(float(wait) / Defs.TICK_RATE)) if wait > 0 else "", "danger": false})
	items.append({"id": "focus", "label": "Focus", "icon": "eye", "ok": true, "reason": "", "danger": false})
	if own != 0:
		items.append({"id": "info", "label": "Info", "icon": "info", "ok": true, "reason": "", "danger": false})
	return items
