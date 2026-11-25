# Port of the logic of src/shared/Data/Cosmetics.luau: the crate catalog, a player's own odds, a roll,
# and a skin's secondary colour. The data is game/cosmetics_data.gd (generated from the Luau).
# Port difference: a crate costs Stars (no Robux); no duplicates, as upstream.
class_name CosmeticsRules
extends RefCounted

const CRATE_COST := 3000  # Stars
const PACK_SIZE := 10
const PACK_COST := 27500  # Stars: Open x10 (owner request 2026-11-25; ten singles would be 30,000)

## Stars for opening n crates in one go: the x10 pack has its own price, any other count is n singles.
static func pack_cost(n: int) -> int:
	return PACK_COST if n == PACK_SIZE else n * CRATE_COST

static var _items := {}
static var _order: Array = []


static func _build() -> void:
	if not _order.is_empty():
		return
	for s: Dictionary in RWCosmetics.SKINS:
		_items[s.id] = s
		_order.append(s)
	for f: Array in RWCosmetics.FLAGS:
		var it := {"id": "flag_" + str(f[0]), "kind": "flag", "name": str(f[1]), "rarity": "common", "code": str(f[0])}
		_items[it.id] = it
		_order.append(it)


## Every crate item (skins first, then flags by code).
static func all() -> Array:
	_build()
	return _order


static func item(id: String):
	_build()
	return _items.get(id)


static func rarity(id: String) -> Dictionary:
	for r: Dictionary in RWCosmetics.RARITIES:
		if r.id == id:
			return r
	return RWCosmetics.RARITIES[0]


## The player's own odds per rarity: [{rarity, odds, left}] (odds sum to 1; 0 each when all is owned).
static func odds(owned: Dictionary) -> Array:
	_build()
	var out := []
	var total := 0.0
	for r: Dictionary in RWCosmetics.RARITIES:
		var left := 0
		for it: Dictionary in _order:
			if it.rarity == r.id and not owned.has(it.id):
				left += 1
		out.append({"rarity": r, "odds": float(r.odds) if left > 0 else 0.0, "left": left})
		if left > 0:
			total += float(r.odds)
	for e: Dictionary in out:
		e.odds = float(e.odds) / total if total > 0.0 else 0.0
	return out


## Roll a crate: an item id the player doesn't own ("" when they own everything). r1, r2 in [0, 1).
static func roll(owned: Dictionary, r1: float, r2: float) -> String:
	var x := r1
	var pick = null
	for e: Dictionary in odds(owned):
		if float(e.odds) > 0.0:
			pick = e
			if x < float(e.odds):
				break
			x -= float(e.odds)
	if pick == null:
		return ""
	var pool := []
	for it: Dictionary in _order:
		if it.rarity == pick.rarity.id and not owned.has(it.id):
			pool.append(it.id)
	return str(pool[clampi(int(floor(r2 * pool.size())), 0, pool.size() - 1)])


## The secondary colour of `skin` over a territory fill of colour `c`.
static func secondary(skin: Dictionary, c: Color) -> Color:
	var a := int(skin.get("accent", -1))
	if a >= 0:
		return Color8((a >> 16) & 255, (a >> 8) & 255, a & 255)
	var t := float(skin.get("tone", -0.2))
	if t >= 0.0:
		return Color(c.r + (1.0 - c.r) * t, c.g + (1.0 - c.g) * t, c.b + (1.0 - c.b) * t)
	return Color(c.r * (1.0 + t), c.g * (1.0 + t), c.b * (1.0 + t))


## A skin's mask as {w, h, bits: PackedByteArray (1 = the secondary colour)}.
static func mask_of(skin: Dictionary) -> Dictionary:
	var rows: Array = skin.mask
	var w := 0
	for r: String in rows:
		w = maxi(w, r.length())
	var bits := PackedByteArray()
	bits.resize(w * rows.size())
	for y in rows.size():
		var row: String = rows[y]
		for x in row.length():
			bits[y * w + x] = 1 if row[x] == "#" else 0
	return {"w": w, "h": rows.size(), "bits": bits}
