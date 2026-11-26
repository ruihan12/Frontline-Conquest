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


# Web: the OpenFront maps' codes/tiles are not in the pack (they would sit in memory whether played or not);
# they are downloaded from lazy/maps/ next to index.html when a match on that map is about to start.
static var _raw_codes := {}  # lazy id -> zlib bytes as downloaded (as_real_map's b64 source)


static func is_lazy(id: String) -> bool:
	return id.begins_with("of_") and OS.has_feature("web") and not FileAccess.file_exists(DIR + id + ".codes.bin")


static func needs_fetch(id: String) -> bool:
	return is_lazy(id) and not _raw_codes.has(id)


static func _inflate(raw: PackedByteArray, n: int) -> PackedByteArray:
	var out := raw.decompress(n, FileAccess.COMPRESSION_DEFLATE)
	return out if out.size() == n else PackedByteArray()


static func _http_get(host: Node, rel: String) -> PackedByteArray:
	var url := str(JavaScriptBridge.eval("new URL(%s, window.location.href).href" % JSON.stringify(rel), true))
	var req := HTTPRequest.new()
	host.add_child(req)
	if req.request(url) != OK:
		req.queue_free()
		return PackedByteArray()
	var res: Array = await req.request_completed
	req.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS or int(res[1]) != 200:
		return PackedByteArray()
	return res[3]


# Downloads and caches a lazy map's terrain (true when it is ready or was never lazy). Keeps only this map
# and drops the other downloaded ones.
static func ensure(id: String, host: Node) -> bool:
	if not needs_fetch(id): return true
	var s := size_of(id)
	var n := s.x * s.y
	var c: PackedByteArray = await _http_get(host, "lazy/maps/%s.codes.bin" % id)
	var t: PackedByteArray = await _http_get(host, "lazy/maps/%s.tiles.bin" % id)
	var cc := _inflate(c, n)
	var tt := _inflate(t, n)
	if n <= 0 or cc.is_empty() or tt.is_empty():
		push_warning("UpstreamMaps: could not download %s" % id)
		return false
	for k in _raw_codes.keys():
		_codes.erase(k); _tiles.erase(k); _real.erase(k); _raw_codes.erase(k)
	_raw_codes[id] = c
	_codes[id] = cc
	_tiles[id] = tt
	return true


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
	var zraw: PackedByteArray
	if _raw_codes.has(id):
		zraw = _raw_codes[id]
	else:
		var f := FileAccess.open(DIR + id + ".codes.bin", FileAccess.READ)
		if f == null: return {}
		zraw = f.get_buffer(f.get_length())
	var e := {"id": id, "name": str(m.name), "k_lin": float(m.k_lin),
		"width": int(m.get("width", 0)), "height": int(m.get("height", 0)),
		"b64": Marshalls.raw_to_base64(zraw),
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
	var tb := PackedByteArray()
	var s := size_of(id)
	var mw := s.x
	var mh := s.y
	var th = meta(id).get("thumb", null)
	if th is Array and FileAccess.file_exists(DIR + id + ".thumb.bin"):
		mw = int(th[0]); mh = int(th[1])
		tb = _read_zlib(DIR + id + ".thumb.bin", mw * mh)
	else:
		tb = tiles(id)
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
