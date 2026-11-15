# Port of src/client/UI/UIMaps.luau (the map list the title screen and the picker read).
#
# Upstream reads Data/MapList and Assets/MapThumbs. This port has three map tables of its own, kept as
# the picker's tabs: the 12 real-world maps, the 12 random (seeded) maps and RoWorld's own maps
# (maps/upstream/). An entry's id is "<tab>:<index>"; thumbnails are the game's map previews.
class_name UIMaps
extends RefCounted

const DEFAULT_ID := "0:0"
const TAB_NAMES := ["Real-world", "Random", "RoWorld maps"]
const TAB_KEYS := ["real", "random", "roworld"]


static func make_id(tab: int, k: int) -> String:
	return "%d:%d" % [tab, k]


static func tab_of(id: String) -> int:
	return clampi(int(id.get_slice(":", 0)), 0, 2)


static func index_of(id: String) -> int:
	return maxi(0, int(id.get_slice(":", 1)))


static func table(g, tab: int) -> Array:
	return g._upstream_menu() if tab == 2 else (g.RANDOM_MAPS if tab == 1 else g.MAPS)


static func count(g, tab: int) -> int:
	return table(g, tab).size()


## Second line of a card: who is on the map (upstream prints the map's size there).
static func sub_of(g, tab: int, k: int) -> String:
	var was: int = g.map_tab
	g.map_tab = tab
	var s: String = g._map_sub(k, tab)
	g.map_tab = was
	var cut := s.find("·")
	return s.substr(cut + 1).strip_edges() if cut >= 0 else s


static func entries(g, tab: int = -1) -> Array:
	var out := []
	for t in 3:
		if tab >= 0 and t != tab:
			continue
		var tbl := table(g, t)
		for k in tbl.size():
			out.append({
				"id": make_id(t, k),
				"tab": t,
				"index": k,
				"name": str(tbl[k][0]),
				"categories": [TAB_KEYS[t]],
				"sub": sub_of(g, t, k),
			})
	return out


static func selected(g) -> String:
	return make_id(int(g.map_tab), int(g.map_i))


static func valid(g, id: String) -> String:
	var t := tab_of(id)
	return id if index_of(id) < count(g, t) else DEFAULT_ID


static func name_of(g, id: String = "") -> String:
	var key := selected(g) if id == "" else valid(g, id)
	var tbl := table(g, tab_of(key))
	var k := index_of(key)
	return str(tbl[k][0]) if k < tbl.size() else "World"


## The cached preview of a map, or null while a random map's preview is still being drawn (the game
## draws those a few rows a frame). Real maps are drawn on the spot.
static func thumb(g, tab: int, k: int) -> Texture2D:
	var key := "%d:%d:%d" % [tab, k, int(g.rand_seed_off) if tab == 1 else 0]
	if g._preview_cache.has(key):
		return g._preview_cache[key]
	if tab == 1:
		return null
	var was: int = g.map_tab
	g.map_tab = tab
	var tex: Texture2D = g._map_preview(k, 148, 82)
	g.map_tab = was
	g._preview_cache[key] = tex
	return tex
