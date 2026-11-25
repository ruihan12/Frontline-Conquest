# Team games, ported from upstream Core/Teams.luau: which team each player is on, and the team colours.
# A team game here is online only (ranked and casual hosts): players only, no bot players; tribes are on no team.
#  - Duos / Trios / Quads: teams of 2 / 3 / 4, as many teams as the players need (at least 2), filled one by one
#    (packing); a number of teams fills evenly.
#  - a party (group) goes whole onto the team with the fewest players; everyone else goes where most of their
#    group already is, else the emptiest team (packing: the fullest one with room).
#  - up to 7 teams are named Red, Blue, Yellow, Green, Purple, Orange, Teal with 64 shades of the base colour,
#    more are "Team N" with one colour per team.
class_name Teams
extends RefCounted

const NAMED := ["Red", "Blue", "Yellow", "Green", "Purple", "Orange", "Teal"]
const BASE := {"Red": "#eb3333", "Blue": "#2962ff", "Yellow": "#e7b008", "Green": "#41be52", "Purple": "#9234ea", "Orange": "#ff7f0e", "Teal": "#06b6d4"}
const SHADES := 64
const SIZES := {"Duos": 2, "Trios": 3, "Quads": 4}
const NUMBERED_PALETTE := ["#ff5d8f", "#00a896", "#8d99ae", "#bc6c25", "#7209b7", "#80b918", "#f72585", "#3a86ff", "#fb8500", "#2ec4b6", "#b5179e", "#9d4edd"]


static func group_size(config) -> int:
	return int(SIZES.get(config, 0))


## Ranked team games pick the team size at random: Duos, Trios or Quads.
static func random_config(rng: RandomNumberGenerator) -> String:
	return ["Duos", "Trios", "Quads"][rng.randi_range(0, 2)]


## The team names for `config` and `players` players.
static func resolve(config, players: int) -> Array:
	var size := group_size(config)
	var n: int
	if size > 0:
		n = maxi(2, ceili(float(players) / size))
	else:
		n = maxi(2, int(config))
	var names := []
	for i in n:
		names.append(NAMED[i] if n < 8 else "Team %d" % (i + 1))
	return names


static func label(config) -> String:
	return "%d Teams" % int(config) if config is int or config is float else str(config)


## players: [{id, group (String, "" for none), filler (bool)}] in join order. Returns {id: team (1..n_teams)}.
static func assign(players: Array, n_teams: int, packing: bool, rng: RandomNumberGenerator = null) -> Dictionary:
	var out := {}
	var sizes := []
	sizes.resize(n_teams)
	sizes.fill(0)
	var max_size := ceili(float(players.size()) / maxi(n_teams, 1))
	var put := func(p: Dictionary, t: int) -> void:
		out[p.id] = t
		sizes[t - 1] += 1
	# the groups, largest first (stable), each onto the team with the fewest players
	var groups := {}
	var order := []
	for p in players:
		var gk := str(p.get("group", ""))
		if gk != "" and not p.get("filler", false):
			if not groups.has(gk):
				groups[gk] = []
				order.append(gk)
			groups[gk].append(p)
	var rank := {}
	for i in order.size():
		rank[order[i]] = i
	order.sort_custom(func(a, b) -> bool:
		if groups[a].size() != groups[b].size():
			return groups[a].size() > groups[b].size()
		return rank[a] < rank[b])
	var rest := []
	for key in order:
		var best := 1
		for t in range(2, n_teams + 1):
			if sizes[t - 1] < sizes[best - 1]:
				best = t
		for p in groups[key]:
			if sizes[best - 1] < max_size:
				put.call(p, best)
			else:
				rest.append(p)
	var place := func(p: Dictionary) -> void:
		var best := 0
		var best_friends := -1
		var best_size := -1 if packing else 1 << 30
		for t in range(1, n_teams + 1):
			if sizes[t - 1] >= max_size:
				continue
			var friends := 0
			var gk := str(p.get("group", ""))
			if gk != "":
				for q in players:
					if str(q.get("group", "")) == gk and out.get(q.id, 0) == t:
						friends += 1
			var better: bool = friends > best_friends or (friends == best_friends and ((sizes[t - 1] > best_size) if packing else (sizes[t - 1] < best_size)))
			if better:
				best = t
				best_friends = friends
				best_size = sizes[t - 1]
		if best == 0:  # every team full: the emptiest
			best = 1
			for t in range(2, n_teams + 1):
				if sizes[t - 1] < sizes[best - 1]:
					best = t
		put.call(p, best)
	for p in rest:
		place.call(p)
	var fillers := []
	for p in players:
		if not out.has(p.id):
			if p.get("filler", false):
				fillers.append(p)
			else:
				place.call(p)
	if rng != null:
		for i in range(fillers.size() - 1, 0, -1):
			var j := rng.randi_range(0, i)
			var tmp = fillers[i]
			fillers[i] = fillers[j]
			fillers[j] = tmp
	for p in fillers:
		place.call(p)
	return out


# ---- colours: shade i of a named team's base colour, in OKLCH (as upstream Teams.shade) ----

static func _srgb_to_lin(c: float) -> float:
	return c / 12.92 if c <= 0.04045 else pow((c + 0.055) / 1.055, 2.4)


static func _lin_to_srgb(c: float) -> float:
	c = clampf(c, 0.0, 1.0)
	return c * 12.92 if c <= 0.0031308 else 1.055 * pow(c, 1.0 / 2.4) - 0.055


static func _to_oklab(col: Color) -> Vector3:
	var r := _srgb_to_lin(col.r)
	var g := _srgb_to_lin(col.g)
	var b := _srgb_to_lin(col.b)
	var l := pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1.0 / 3.0)
	var m := pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1.0 / 3.0)
	var s := pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1.0 / 3.0)
	return Vector3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s, 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


static func _from_oklab(v: Vector3) -> Color:
	var l := pow(v.x + 0.3963377774 * v.y + 0.2158037573 * v.z, 3.0)
	var m := pow(v.x - 0.1055613458 * v.y - 0.0638541728 * v.z, 3.0)
	var s := pow(v.x - 0.0894841775 * v.y - 1.2914855480 * v.z, 3.0)
	return Color(_lin_to_srgb(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
		_lin_to_srgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
		_lin_to_srgb(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))


static func shade(base: Color, i: int) -> Color:
	if i <= 0:
		return base
	var lab := _to_oklab(base)
	var c := sqrt(lab.y * lab.y + lab.z * lab.z)
	var h := rad_to_deg(atan2(lab.z, lab.y))
	h = fposmod(h + fposmod(i * 137.508, 12.0) - 6.0 + 360.0, 360.0)
	c = clampf(c * (1.0 + 0.1 * sin(i * 0.7)), 0.03, 0.34)
	var l := clampf(lab.x + 0.18 * sin(deg_to_rad(i * 137.508)), 0.32, 0.86)
	var hr := deg_to_rad(h)
	return _from_oklab(Vector3(l, c * cos(hr), c * sin(hr)))


## The colour of the `index`-th (0-based) player of team `name` (the `team`-th team, 1-based).
static func color(name: String, team: int, index: int) -> Color:
	if BASE.has(name):
		return shade(Color(BASE[name]), index % SHADES)
	return Color(NUMBERED_PALETTE[((team - 1) * 7) % NUMBERED_PALETTE.size()])
