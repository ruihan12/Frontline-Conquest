# Upstream RoWorld maps (the playable MapList only), decoded 1:1 from the Luau data modules
# (MapCodec: base64 -> zstd -> native-size tile bytes). No crop, scale, letterbox padding, or mapfix.
# Data: res://maps/upstream/.
#   <id>.codes.bin  zlib, native W*H u8: 0 water 1 plains 2 highland 3 mountain
#   <id>.tiles.bin  zlib, native W*H u8 exact upstream WorldMap tile bytes
#   <id>.json       meta: name, width, height, k_lin (1.0), scale (1.0), nations [{name, flag, x, y}]
#   index.json      map list, nation colour table (Data/Nations.luau), tribe names (Data/Tribes.luau)
# Pangaea and Onion are upstream test fixtures and are not listed. Usage: const UpstreamMaps := preload(...)
extends RefCounted

const DIR := "res://maps/upstream/"
# Featured rank (UIMaps.FEATURED_RANK) then the regional maps. map_i 0 is World.
const ORDER := ["world", "europe", "northamerica", "southamerica", "asia", "africa", "mediterranean", "middleeast",
	"oceania", "unitedstates"]
# Upstream UIMaps.FEATURED_RANK
const FEATURED_RANK := {"world": 1, "europe": 2, "northamerica": 3, "southamerica": 4, "asia": 5, "africa": 6}

static var _index := {}
static var _meta := {}
static var _codes := {}
static var _tiles := {}
static var _real := {}


static func _read_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("UpstreamMaps: cannot open %s (%d)" % [path, FileAccess.get_open_error()])
		return null
	return JSON.parse_string(f.get_as_text())


static func _read_zlib(path: String, n: int) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("UpstreamMaps: cannot open %s" % path)
		return PackedByteArray()
	var raw := f.get_buffer(f.get_length())
	var out := raw.decompress(n, FileAccess.COMPRESSION_DEFLATE)
	if out.size() != n:
		push_error("UpstreamMaps: %s decoded to %d bytes, expected %d" % [path, out.size(), n])
		return PackedByteArray()
	return out


static func index() -> Dictionary:
	if _index.is_empty():
		var d = _read_json(DIR + "index.json")
		if d is Dictionary: _index = d
	return _index


# ORDER, then the imported OpenFront maps (index.json "others", tools/import_openfront.py)
static var _all := []
static func ids() -> Array:
	if _all.is_empty():
		_all = ORDER.duplicate()
		for o in index().get("others", []): _all.append(str(o))
	return _all.duplicate()


static func count() -> int:
	ids()
	return _all.size()


static func id_at(k: int) -> String:
	ids()
	return _all[clampi(k, 0, _all.size() - 1)]


static func index_of(id: String) -> int:
	ids()
	var i := _all.find(id)
	return i if i >= 0 else 0


static func meta(id: String) -> Dictionary:
	if not _meta.has(id):
		var d = _read_json(DIR + id + ".json")
		_meta[id] = d if d is Dictionary else {}
	return _meta[id]


static func size_of(id: String) -> Vector2i:
	var m := meta(id)
	return Vector2i(int(m.get("width", 0)), int(m.get("height", 0)))


# Native W*H terrain codes (0 water, 1 plains, 2 highland, 3 mountain).
static func codes(id: String) -> PackedByteArray:
	if not _codes.has(id):
		var s := size_of(id)
		_codes[id] = _read_zlib(DIR + id + ".codes.bin", s.x * s.y)
	return _codes[id]


static func codes_at(k: int) -> PackedByteArray:
	return codes(id_at(k))


# Native W*H full upstream tile bytes (elevation magnitude, shore/ocean bits, water depth).
static func tiles(id: String) -> PackedByteArray:
	if not _tiles.has(id):
		var s := size_of(id)
		_tiles[id] = _read_zlib(DIR + id + ".tiles.bin", s.x * s.y)
	return _tiles[id]


static func is_lake(tb: int) -> bool:
	return tb < 128 and (tb & 0x20) == 0


static func elevation(tb: int) -> int:
	return tb & 0x1F if tb >= 128 else -1


# Nations as main.gd expects them: [name, flag, x, y].
static func nations(id: String) -> Array:
	var out := []
	for n in meta(id).get("nations", []):
		out.append([str(n.name), str(n.flag), int(n.x), int(n.y)])
	return out


static func default_tribes(id: String) -> int:
	var m := meta(id)
	var s := float(m.get("scale", 1.0))
	if m.has("default_tribes"):
		return int(m.default_tribes)
	return int(floor(400.0 * s * s + 0.5))


# A dictionary shaped like a RealMaps.MAPS entry ({id, name, k_lin, b64, nations, land}), so main.gd
# paths that read RealMaps entries work unchanged. b64 is base64(zlib(codes)).
static func as_real_map(id: String) -> Dictionary:
	if _real.has(id): return _real[id]
	var m := meta(id)
	if m.is_empty(): return {}
	var f := FileAccess.open(DIR + id + ".codes.bin", FileAccess.READ)
	if f == null: return {}
	var e := {"id": id, "name": str(m.name), "k_lin": float(m.k_lin),
		"width": int(m.get("width", 0)), "height": int(m.get("height", 0)),
		"b64": Marshalls.raw_to_base64(f.get_buffer(f.get_length())),
		"nations": nations(id), "land": int(m.land_tiles), "upstream": true,
		"forced_modifiers": m.get("forced_modifiers", []),
		"default_tribes": default_tribes(id)}
	_real[id] = e
	return e


static func real_map_at(k: int) -> Dictionary:
	return as_real_map(id_at(k))


# Menu rows shaped like main.gd MAPS entries: [name, seed, 0.0, 200].
static func menu_entries() -> Array:
	var out := []
	for k in count():
		out.append([str(meta(id_at(k)).get("name", id_at(k))), 12001 + k * 97, 0.0, 200])
	return out


# Upstream nation colours by lowercase flag code ("us" -> "#719bfa"), from Data/Nations.luau.
static func nation_colors() -> Dictionary:
	var out := {}
	for n in index().get("nation_table", []):
		out[str(n.code).to_lower()] = str(n.color)
	return out


static func tribe_names() -> Array:
	return index().get("tribe_names", [])


# Card thumbnail in the in-game terrain palette (MapSurface.luau colours).
static func preview_image(id: String, pw: int, ph: int) -> Image:
	var tb := tiles(id)
	var s := size_of(id)
	var mw := s.x
	var mh := s.y
	var im := Image.create(pw, ph, false, Image.FORMAT_RGBA8)
	if tb.size() != mw * mh or mw < 1 or mh < 1: return im
	for py in ph:
		var sy := clampi(int((py + 0.5) * mh / ph), 0, mh - 1)
		for px in pw:
			var sx := clampi(int((px + 0.5) * mw / pw), 0, mw - 1)
			var b: int = tb[sy * mw + sx]
			var c: Color
			if b >= 128:
				var m := b & 0x1F
				if (b & 0x40) != 0: c = Color8(0xCC, 0xCB, 0x9E)
				elif m < 10: c = Color8(0xBE, 0xDC - 2 * m, 0x8A)
				elif m < 20: c = Color8(0xDC + 2 * (m - 10), 0xCB + 2 * (m - 10), 0x9E + 2 * (m - 10))
				else: c = Color8(mini(255, 0xE6 + m / 2), mini(255, 0xE6 + m / 2), mini(255, 0xE6 + m / 2))
			else:
				var d := mini(b & 0x1F, 10)
				c = Color8(0x47 - d, 0x85 - d, 0xB5 - d)
			im.set_pixel(px, py, c)
	return im


static func preview_texture(id: String, pw: int, ph: int) -> ImageTexture:
	return ImageTexture.create_from_image(preview_image(id, pw, ph))
