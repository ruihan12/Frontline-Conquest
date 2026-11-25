# Port of src/client/UI/UIMaps.luau (the map list the title screen and the picker read).
#
# Upstream reads Data/MapList and Assets/MapThumbs. This port lists exactly those playable maps
# (maps/upstream/, the 10 MapList ids). Tabs are upstream's category filters over that one list.
# There is no handcrafted or random-maps table. An entry's id is the map id ("world").
class_name UIMaps
extends RefCounted

const UpstreamMaps := preload("res://sim/upstream_maps.gd")

const DEFAULT_ID := "world"
const TAB_NAMES := ["Featured", "World", "Europe", "Asia", "Americas", "Africa · Oceania", "Others", "All"]
# Union of category keys, or empty = all. Matches MapPicker.TABS in MapPicker.luau.
const TAB_CATS := [
	["featured"],
	["world", "continental"],
	["europe"],
	["asia"],
	["north_america", "south_america"],
	["africa", "oceania", "antarctica"],
	["others"],
	[],
]


static func make_id(_tab: int, k: int) -> String:
	return UpstreamMaps.id_at(k)


static func tab_of(_id: String) -> int:
	return 0


static func index_of(id: String) -> int:
	if id.contains(":"):
		return maxi(0, int(id.get_slice(":", 1)))
	return UpstreamMaps.index_of(id)


static func _cats_of(id: String) -> Array:
	return UpstreamMaps.meta(id).get("categories", [])


static func _in_tab(id: String, tab: int) -> bool:
	var keys: Array = TAB_CATS[clampi(tab, 0, TAB_CATS.size() - 1)]
	if keys.is_empty():
		return true
	for c in _cats_of(id):
		if str(c) in keys:
			return true
	return false


static func table(g, _tab: int) -> Array:
	return g._upstream_menu()


static func count(g, tab: int) -> int:
	return entries(g, tab).size()


## Second line of a card: the map's size and who is on it (upstream prints the size).
static func sub_of(g, _tab: int, k: int) -> String:
	return g._map_sub(k, 0)


static func entries(g, tab: int = -1) -> Array:
	var out := []
	var t := 0 if tab < 0 else tab
	# Featured follows UIMaps.FEATURED_RANK; other tabs keep ORDER.
	var ids: Array = UpstreamMaps.ids()
	if t == 0:
		ids = ids.duplicate()
		ids.sort_custom(func(a, b):
			return int(UpstreamMaps.FEATURED_RANK.get(a, 99)) < int(UpstreamMaps.FEATURED_RANK.get(b, 99)))
	for id in ids:
		if tab >= 0 and not _in_tab(id, t):
			continue
		var k := UpstreamMaps.index_of(id)
		out.append({
			"id": id,
			"tab": t,
			"index": k,
			"name": str(UpstreamMaps.meta(id).get("name", id)),
			"categories": _cats_of(id),
			"sub": sub_of(g, t, k),
		})
	return out


static func selected(g) -> String:
	return UpstreamMaps.id_at(int(g.map_i))


static func valid(g, id: String) -> String:
	if id.contains(":"):
		var k := index_of(id)
		return UpstreamMaps.id_at(k) if k < UpstreamMaps.count() else DEFAULT_ID
	return id if id in UpstreamMaps.ids() else DEFAULT_ID


static func name_of(g, id: String = "") -> String:
	var key := selected(g) if id == "" else valid(g, id)
	return str(UpstreamMaps.meta(key).get("name", "World"))


## The cached preview of a map.
static func thumb(g, _tab: int, k: int) -> Texture2D:
	var id := UpstreamMaps.id_at(k)
	var key := "up:%s" % id
	if g._preview_cache.has(key):
		return g._preview_cache[key]
	var tex: Texture2D = g._map_preview(k, 148, 82)
	g._preview_cache[key] = tex
	return tex
