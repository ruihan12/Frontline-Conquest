#!/usr/bin/env python3
"""Sanity table + heatmaps for maps/upstream/world.pop.bin (see tools/bake_population.py).
Usage: python3 tools/population_report.py <ne_50m_admin_0_countries.geojson> <out_dir>"""
import json, sys, zlib
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont
sys.path.insert(0, str(Path(__file__).resolve().parent))
from bake_population import Grid, W, H, DIR, codes

REAL = {  # UN WPP 2024, 2025 estimates (millions)
    "USA": ("United States", 347), "CHN": ("China", 1416), "IND": ("India", 1464), "RUS": ("Russia", 144),
    "BRA": ("Brazil", 212), "AUS": ("Australia", 27), "EGY": ("Egypt", 118), "IDN": ("Indonesia", 286),
    "NGA": ("Nigeria", 238), "JPN": ("Japan", 123), "DEU": ("Germany", 84), "CAN": ("Canada", 40),
    "BGD": ("Bangladesh", 175), "PAK": ("Pakistan", 255), "ATA": ("Antarctica", 0),
}


def rasterize(geo, grid, keys):
    """ADM0_A3 -> boolean tile mask on the game grid."""
    masks = {}
    for f in json.load(open(geo))["features"]:
        k = f["properties"]["ADM0_A3"]
        if k not in keys: continue
        img = Image.new("L", (W, H), 0); d = ImageDraw.Draw(img)
        g = f["geometry"]; polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
        for poly in polys:
            for ri, ring in enumerate(poly):
                a = np.asarray(ring, float)
                sx = (a[:, 0] - grid.lon0) * grid.px
                sy = (grid.lat_top - a[:, 1]) * grid.py
                for shift in ((0.0, grid.wrap) if sx.min() < 0 else (0.0,)):
                    x = (sx + shift - grid.x0) * grid.nw / grid.cw + grid.ox
                    y = (sy - grid.y0) * grid.nh / grid.ch + grid.oy
                    d.polygon(list(zip(x, y)), fill=0 if ri else 1)
        masks[k] = np.asarray(img, bool) | masks.get(k, np.zeros((H, W), bool))
    return masks


def magma(t):
    stops = np.array([[0, 0, 4], [40, 11, 84], [101, 21, 110], [159, 42, 99], [212, 72, 66], [245, 125, 21],
                      [250, 193, 39], [252, 255, 164]], float)
    xs = np.linspace(0, 1, len(stops))
    return np.stack([np.interp(t, xs, stops[:, c]) for c in range(3)], -1).astype(np.uint8)


def terrain_rgb(cd):
    pal = np.array([[38, 72, 128], [190, 220, 138], [220, 203, 158], [230, 230, 230], [244, 247, 250]], np.uint8)
    return pal[np.minimum(cd, 4)]


def main(geo, out):
    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    grid = Grid("world")
    pop = np.frombuffer(zlib.decompress((DIR / "world.pop.bin").read_bytes()), "<f4").reshape(H, W).astype(np.float64)
    cd = codes("world")
    masks = rasterize(geo, grid, set(REAL))
    rows = ["| country | tiles (NE mask) | baked pop (M) | real 2025 (M) | ratio |", "| --- | --- | --- | --- | --- |"]
    for k, (name, real) in REAL.items():
        m = masks.get(k)
        if m is None: rows.append(f"| {name} | - | - | {real} | - |"); continue
        m = m & (cd != 0)
        p = pop[m].sum() / 1e6
        rows.append(f"| {name} | {int(m.sum())} | {p:.1f} | {real} | {p / real:.2f} |" if real else f"| {name} | {int(m.sum())} | {p:.3f} | 0 | - |")
    snow = pop[cd == 4].sum()
    rows.append(f"\nTotal {pop.sum()/1e9:.3f} B on {int((pop>0).sum())} populated of {int((cd!=0).sum())} land tiles; "
                f"snow (Antarctica) tiles {snow:.0f} people; water tiles {pop[cd==0].sum():.0f}.")
    iy, ix = np.unravel_index(np.argsort(pop.ravel())[::-1][:8], pop.shape)
    lon, lat = grid.tile_lonlat()
    rows.append("Top tiles: " + "; ".join(f"({x},{y}) {lat[y]:.1f},{lon[x]:.1f} {pop[y, x]/1e6:.1f}M" for x, y in zip(ix, iy)))
    # nation spawn regions: people within 30 tiles of each spawn (rough "home region")
    (out / "sanity.md").write_text("\n".join(rows) + "\n")
    print("\n".join(rows))
    # heatmap, log scale, people per tile 1 .. 1e7
    y0, y1 = grid.oy, grid.oy + grid.nh
    t = np.clip(np.log10(np.maximum(pop, 1)) / 7.0, 0, 1)
    rgb = magma(t); rgb[cd == 0] = (14, 22, 40); rgb[(cd != 0) & (pop < 1)] = (40, 40, 48)
    heat = Image.fromarray(rgb[y0:y1])
    # legend
    lg = Image.new("RGB", (heat.width, 40), (14, 22, 40)); d = ImageDraw.Draw(lg)
    bar = magma(np.linspace(0, 1, 600))[None].repeat(14, 0)
    lg.paste(Image.fromarray(bar), (20, 6))
    for e in range(8):
        d.text((20 + e * 600 // 7 - 8, 22), f"1e{e}", fill=(230, 230, 230))
    d.text((640, 10), "people per tile (log10), GHSL GHS-POP 2025 30\" baked to World 1792x1600 (~20 km tiles)", fill=(230, 230, 230))
    full = Image.new("RGB", (heat.width, heat.height + 40)); full.paste(heat, (0, 0)); full.paste(lg, (0, heat.height))
    full.save(out / "world_density.png")
    terr = Image.fromarray(terrain_rgb(cd)[y0:y1])
    sbs = Image.new("RGB", (heat.width * 2 + 8, heat.height), (0, 0, 0))
    sbs.paste(terr, (0, 0)); sbs.paste(heat, (heat.width + 8, 0))
    sbs.save(out / "world_density_vs_terrain.png")
    print("wrote", out / "world_density.png", out / "world_density_vs_terrain.png")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
