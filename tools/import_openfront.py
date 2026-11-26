#!/usr/bin/env python3
"""Imports OpenFront maps (resources/maps/<id>/map*.bin + manifest.json) into maps/upstream/ as of_<id>.
Usage: import_openfront.py <openfront resources/maps dir>. Picks the largest of map/map4x/map16x with <= MAXT tiles."""
import json, sys, zlib, os
SRC = sys.argv[1]; DST = os.path.join(os.path.dirname(__file__), "..", "maps", "upstream")
MAXT = 2_400_000
SKIP = {"world","europe","northamerica","southamerica","asia","africa","oceania","unitedstates","middleeast",
        "tutorial","onion","pangaea","world10000","tourney1","tourney2","tourney3","tourney4"}
ids = []
for d in sorted(os.listdir(SRC)):
    p = os.path.join(SRC, d, "manifest.json")
    if d.lower() in SKIP or not os.path.exists(p): continue
    m = json.load(open(p))
    for key, fn in (("map", "map.bin"), ("map4x", "map4x.bin"), ("map16x", "map16x.bin")):
        W, H = m[key]["width"], m[key]["height"]
        if W * H <= MAXT: break
    raw = open(os.path.join(SRC, d, fn), "rb").read()
    if len(raw) != W * H: print("skip size mismatch", d); continue
    ratio = W / m["map"]["width"]
    raw = bytearray(raw)
    codes = bytearray(len(raw)); land = 0
    for i, b in enumerate(raw):
        if b == 0x9F:  # impassable (upstream codec: src_impassable_tiles) -> deep-ocean byte, water code
            raw[i] = 0x20
        elif b >= 128:
            land += 1; mg = b & 31
            codes[i] = 1 if mg < 10 else 2 if mg < 20 else 3
    if land < 200: print("skip tiny", d); continue
    oid = "of_" + d.lower()
    def snap(x, y):
        for r in range(0, 41):
            for dy in range(-r, r + 1):
                for dx in range(-r, r + 1):
                    if max(abs(dx), abs(dy)) != r: continue
                    px, py = x + dx, y + dy
                    if 0 <= px < W and 0 <= py < H and codes[py * W + px]: return px, py
        return None
    nations = [{"name": n["name"], "flag": n.get("flag", ""), "x": int(n["coordinates"][0] * ratio), "y": int(n["coordinates"][1] * ratio)} for n in m.get("nations", []) if "coordinates" in n]
    nn = []
    for n in nations:
        q = snap(min(max(n["x"], 0), W - 1), min(max(n["y"], 0), H - 1))
        if q: n["x"], n["y"] = q; nn.append(n)
    nations = nn
    meta = {"id": oid, "name": m["name"], "categories": ["others"] + [c for c in m.get("categories", []) if c != "featured"],
            "forced_modifiers": [], "k_lin": 1.0, "scale": 1.0, "width": W, "height": H, "land_tiles": land,
            "default_tribes": max(40, min(400, round(400 * land / 689018))), "nations": nations, "source": "OpenFront " + d}
    TW, TH = 296, 164  # card thumbnail source (nearest sample of the tile bytes; the web build keeps only this in the pack)
    th = bytearray(TW * TH)
    for y in range(TH):
        sy = min(H - 1, int((y + 0.5) * H / TH))
        for x in range(TW):
            th[y * TW + x] = raw[sy * W + min(W - 1, int((x + 0.5) * W / TW))]
    meta["thumb"] = [TW, TH]
    open(os.path.join(DST, oid + ".thumb.bin"), "wb").write(zlib.compress(bytes(th), 9))
    json.dump(meta, open(os.path.join(DST, oid + ".json"), "w"))
    open(os.path.join(DST, oid + ".codes.bin"), "wb").write(zlib.compress(bytes(codes), 9))
    open(os.path.join(DST, oid + ".tiles.bin"), "wb").write(zlib.compress(bytes(raw), 9))
    ids.append(oid)
ix = json.load(open(os.path.join(DST, "index.json"))); ix["others"] = ids
json.dump(ix, open(os.path.join(DST, "index.json"), "w"), indent=1)
print(len(ids), "maps")
