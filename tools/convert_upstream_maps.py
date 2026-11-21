#!/usr/bin/env python3
"""Decode every playable RoWorld map (MapCodec: base64 -> zstd -> native W*H tile bytes) exactly,
with no crop, scale, letterbox padding, mapfix, or Antarctica recolour. Writes maps/upstream/<id>.codes.bin
(zlib, 0 water 1 plains 2 highland 3 mountain), <id>.tiles.bin (zlib, the upstream tile bytes unchanged),
<id>.json (meta + nations at source x/y), index.json, previews/<id>_small.png.

Usage: python3 tools/convert_upstream_maps.py [/path/to/roworld]
Source: RoWorld (github.com/lukechatton/roworld, AGPL; maps from Natural Earth + NOAA ETOPO1, public domain).
"""
import base64, json, os, re, subprocess, sys, zlib
import numpy as np, zstandard
from PIL import Image

SRC = sys.argv[1] if len(sys.argv) > 1 else "/workspace/roworld_upstream_maps"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "maps", "upstream")
LAND, SHORE, OCEAN, IMPASSABLE = 0x80, 0x40, 0x20, 0x9F
PREVIEW_FULL = os.environ.get("PREVIEW_FULL", "/workspace/shots/upstream_maps/previews_full")
# Playable maps only (Data/MapList). Pangaea and Onion are test fixtures and are not written.
FILES = [
    ("src/shared/Data/Maps/World.luau", "game"),
    ("src/server/MapData/Africa.luau", "game"),
    ("src/server/MapData/Asia.luau", "game"),
    ("src/server/MapData/Europe.luau", "game"),
    ("src/server/MapData/NorthAmerica.luau", "game"),
    ("src/server/MapData/SouthAmerica.luau", "game"),
    ("src/server/MapData/UnitedStates.luau", "game"),
    ("src/server/MapData/Mediterranean.luau", "game"),
    ("src/server/MapData/MiddleEast.luau", "game"),
    ("src/server/MapData/Oceania.luau", "game"),
]
C_OCEAN = (0x47, 0x85, 0xB5); C_SAND = (0xCC, 0xCB, 0x9E); C_PLAINS = (0xBE, 0xDC, 0x8A)
C_HIGH = (0xDC, 0xCB, 0x9E); C_MTN = (0xE6, 0xE6, 0xE6)


def lua_list(s):
    return re.findall(r'"([^"]*)"', s or "")


def parse(path):
    s = open(path, encoding="utf-8").read()
    g = lambda k: re.search(r"^\t%s = (.+?),?$" % k, s, re.M)
    d = {
        "id": g("id").group(1).strip('"'), "name": g("name").group(1).strip('"'),
        "module": g("module").group(1).strip('"'),
        "width": int(g("width").group(1)), "height": int(g("height").group(1)),
        "k_lin": float(g("k_lin").group(1)),
        "categories": lua_list(g("categories").group(1)),
        "multiplayer_frequency": int(g("multiplayer_frequency").group(1)),
        "forced_modifiers": lua_list(g("forced_modifiers").group(1)),
        "land_tiles": int(g("land_tiles").group(1)),
        "codec": (g("codec").group(1).strip('"') if g("codec") else "zstd+base64"),
        "header": [l[3:] for l in s.splitlines() if l.startswith("-- ")],
    }
    d["nations"] = [{"name": m.group(1), "flag": m.group(2), "x": int(m.group(3)), "y": int(m.group(4))}
                    for m in re.finditer(r'\{ name = "([^"]+)", flag = "([^"]*)", x = (\d+), y = (\d+) \}', s)]
    t = re.search(r'\tterrain = "([^"]+)"', s).group(1)
    assert d["codec"] == "zstd+base64", d["codec"]
    raw = zstandard.ZstdDecompressor().decompress(base64.b64decode(t), max_output_size=d["width"] * d["height"])
    assert len(raw) == d["width"] * d["height"], (path, len(raw))
    d["bytes"] = np.frombuffer(raw, np.uint8).reshape(d["height"], d["width"]).copy()
    d["zstd_bytes"] = len(base64.b64decode(t))
    return d


def convert(d):
    """1:1 copy of the upstream tile grid. No crop, scale, padding, mapfix, or snow recolour."""
    tb = d["bytes"]
    notes = []
    h0, w0 = tb.shape
    ice = int((tb == IMPASSABLE).sum())
    if ice:
        notes.append("%d impassable/ice tiles (0x9F) kept as in the source" % ice)
    nations = []
    for n in d["nations"]:
        nn = dict(n)
        nn["src_x"], nn["src_y"] = n["x"], n["y"]
        x, y = int(n["x"]), int(n["y"])
        if not (0 <= x < w0 and 0 <= y < h0 and tb[y, x] & LAND):
            yy, xx = np.nonzero((tb & LAND) != 0)
            k = int(np.argmin((yy - y) ** 2 + (xx - x) ** 2))
            x, y = int(xx[k]), int(yy[k])
            nn["moved_to_land"] = True
            notes.append("nation %s moved to land at %d,%d" % (n["name"], x, y))
        nn["x"], nn["y"] = x, y
        nations.append(nn)
    mag = tb & 0x1F
    isl = (tb & LAND) != 0
    # Impassable (0x9F) is not contestable land in codes.bin (water / non-land).
    codes = np.where(isl & (tb != IMPASSABLE), np.where(mag < 10, 1, np.where(mag < 20, 2, 3)), 0).astype(np.uint8)
    land_rows = np.where(isl.any(1))[0]
    meta = {k: d[k] for k in ("id", "name", "module", "categories", "multiplayer_frequency", "forced_modifiers")}
    meta.update({
        "source_file": d["path"], "source_kind": d["kind"], "source_header": d["header"],
        "src_width": w0, "src_height": h0, "src_k_lin": d["k_lin"], "src_land_tiles": d["land_tiles"],
        "src_land_tiles_decoded": int(isl.sum() - ice),
        "src_impassable_tiles": ice,
        "crop": [0, 0, w0, h0], "scale": 1.0, "placed": [0, 0, w0, h0],
        "width": w0, "height": h0, "k_lin": d["k_lin"], "resample": "none (native upstream grid, 1:1)",
        "land_tiles": int((isl & (tb != IMPASSABLE)).sum()),
        "code_counts": [int((codes == c).sum()) for c in range(4)],
        "snow_tiles": 0,
        "lake_tiles": int(((~isl) & ((tb & OCEAN) == 0)).sum()),
        "first_land_row": int(land_rows[0]) if len(land_rows) else -1,
        "last_land_row": int(land_rows[-1]) if len(land_rows) else -1,
        "default_tribes": int(np.floor(400 * 1.0 * 1.0 + 0.5)),
        "nations": nations, "notes": notes, "mapfix": [],
    })
    return meta, codes, tb


def preview(meta, full, path, small):
    land = full >= 128; shore = (full & SHORE) != 0; mag = (full & 0x1F).astype(np.int32)
    img = np.zeros(full.shape + (3,), np.int32)
    pl = land & (mag < 10); hl = land & (mag >= 10) & (mag < 20); mt = land & (mag >= 20)
    img[pl] = np.stack([np.full(pl.sum(), C_PLAINS[0]), C_PLAINS[1] - 2 * mag[pl], np.full(pl.sum(), C_PLAINS[2])], -1)
    img[hl] = np.array(C_HIGH)[None] + 2 * (mag[hl] - 10)[:, None]
    img[mt] = np.array(C_MTN)[None] + (mag[mt] // 2)[:, None]
    img[land & shore] = C_SAND
    w = ~land
    img[w] = np.array(C_OCEAN)[None] - (np.minimum(mag[w], 10) + 0.6 * np.maximum(0, mag[w] - 10))[:, None]
    img[w & shore] = (np.array(C_OCEAN) * 0.7 + 76.5).astype(int)
    lake = w & ((full & OCEAN) == 0)
    img[lake & ~shore] = (88, 150, 200)
    im = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    im.save(path)
    h, w = full.shape
    scale = min(448 / w, 400 / h)
    im.resize((max(1, int(round(w * scale))), max(1, int(round(h * scale)))), Image.LANCZOS).save(small)


def src_rev():
    try:
        return subprocess.check_output(["git", "-C", SRC, "rev-parse", "--short", "HEAD"], text=True).strip()
    except Exception:
        return "unknown"


def main():
    os.makedirs(os.path.join(OUT, "previews"), exist_ok=True)
    index = []
    rev = src_rev()
    for rel, kind in FILES:
        p = os.path.join(SRC, rel)
        d = parse(p); d["path"] = rel; d["kind"] = kind
        meta, codes, full = convert(d)
        # Exact edge check against the source bytes.
        assert full.shape == d["bytes"].shape
        assert np.array_equal(full, d["bytes"]), "%s tiles differ from the source" % meta["id"]
        open(os.path.join(OUT, meta["id"] + ".codes.bin"), "wb").write(zlib.compress(codes.tobytes(), 9))
        open(os.path.join(OUT, meta["id"] + ".tiles.bin"), "wb").write(zlib.compress(full.tobytes(), 9))
        json.dump(meta, open(os.path.join(OUT, meta["id"] + ".json"), "w"), indent=1, ensure_ascii=False)
        preview(meta, full, os.path.join(PREVIEW_FULL, meta["id"] + ".png"),
                os.path.join(OUT, "previews", meta["id"] + "_small.png"))
        index.append({k: meta[k] for k in ("id", "name", "source_kind", "categories", "k_lin", "scale",
                                           "land_tiles", "width", "height", "forced_modifiers",
                                           "multiplayer_frequency", "default_tribes")}
                     | {"nations": len(meta["nations"]), "src_size": [meta["src_width"], meta["src_height"]],
                        "first_land_row": meta["first_land_row"], "last_land_row": meta["last_land_row"]})
        top = int(((full[0] & LAND) != 0).sum())
        bot = int(((full[-1] & LAND) != 0).sum())
        print("%-14s src %dx%d land %d (decoded %d, 0x9F %d) 1:1 -> land %d nations %d tribes %d "
              "first_land_row %d last_land_row %d top_land %d bottom_land %d %s"
              % (meta["name"], meta["src_width"], meta["src_height"], meta["src_land_tiles"],
                 meta["src_land_tiles_decoded"], meta["src_impassable_tiles"], meta["land_tiles"],
                 len(meta["nations"]), meta["default_tribes"], meta["first_land_row"], meta["last_land_row"],
                 top, bot, meta["notes"]))
    ns = open(os.path.join(SRC, "src/shared/Data/Nations.luau"), encoding="utf-8").read()
    nat = [{"name": m.group(1), "code": m.group(2), "lat": float(m.group(3)), "lon": float(m.group(4)), "color": m.group(5)}
           for m in re.finditer(r'name = "([^"]+)", code = "(\w+)", lat = ([-\d.]+), lon = ([-\d.]+), x = \d+, y = \d+, color = "(#\w+)"', ns)]
    tr = open(os.path.join(SRC, "src/shared/Data/Tribes.luau"), encoding="utf-8").read()
    tribes = re.findall(r'^\t\t"([^"]+)",$', tr, re.M)
    json.dump({"source": "RoWorld @ %s (AGPL); maps: Natural Earth + NOAA ETOPO1 (public domain)" % rev,
               "format": {"codes": "zlib(W*H u8): 0 water 1 plains 2 highland 3 mountain; W,H are the map's native size",
                          "tiles": "zlib(W*H u8) exact upstream tile bytes (bit7 land, bit6 shore, bit5 ocean, bits0-4 magnitude). No padding, crop, or mapfix."},
               "default": "world", "maps": index, "nation_table": nat, "tribe_names": tribes},
              open(os.path.join(OUT, "index.json"), "w"), indent=1, ensure_ascii=False)
    print("nation_table", len(nat), "tribes", len(tribes), "source", rev)


if __name__ == "__main__":
    main()
