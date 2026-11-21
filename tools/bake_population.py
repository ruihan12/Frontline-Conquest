#!/usr/bin/env python3
"""Bake real-world population per tile for the upstream real-world maps (test: USE_REAL_POP).

Source: GHSL GHS-POP R2023A, epoch 2025, WGS84 30 arc-second grid (JRC, open data, CC BY 4.0):
  https://jeodpp.jrc.ec.europa.eu/ftp/jrc-opendata/GHSL/GHS_POP_GLOBE_R2023A/
  GHS_POP_E2025_GLOBE_R2023A_4326_30ss/V1-0/GHS_POP_E2025_GLOBE_R2023A_4326_30ss_V1_0.zip
Each 30" source pixel (people count) is added whole to the game tile under its centre, through the same
equirectangular projection upstream's tools/maps/make_maps.py used, then this project's crop / scale /
placement (maps/upstream/<id>.json, tools/convert_upstream_maps.py centre sampling). People that land on
a water tile (coastline mismatch, small islands removed upstream) move to the nearest land tile.

Output: maps/upstream/<id>.pop.bin = zlib(float32 little-endian, 1792*1600, people per tile).
Usage: python3 tools/bake_population.py <GHS_POP...30ss.tif> [ids...]   (needs numpy, scipy, rasterio)
"""
import json, math, sys, zlib
from pathlib import Path
import numpy as np
import rasterio
from rasterio.windows import Window
from scipy.ndimage import distance_transform_edt

ROOT = Path(__file__).resolve().parent.parent
DIR = ROOT / "maps" / "upstream"
W, H = 1792, 1600
WORLD_PPD = 2000 / 360.0
# Source projections, from upstream tools/maps/make_maps.py MAPS (lon0, lat_top, ppd, lat_std, wrap width)
SPECS = {
    "world": dict(lon0=-180.0 + 65 / WORLD_PPD, lat_top=90.0 - 10 / WORLD_PPD, ppd=WORLD_PPD, lat_std=0.0, wrap=2000),
    "europe": dict(lon0=-25.0, lat_top=72.0, ppd=33.0, lat_std=52.0),
    "northamerica": dict(lon0=-170.0, lat_top=75.0, ppd=18.0, lat_std=40.0),
    "southamerica": dict(lon0=-92.0, lat_top=14.0, ppd=20.0, lat_std=-20.0),
    "asia": dict(lon0=25.0, lat_top=78.0, ppd=15.0, lat_std=35.0),
    "africa": dict(lon0=-26.0, lat_top=38.0, ppd=18.0, lat_std=10.0),
}


class Grid:
    """lon/lat -> game tile (gx, gy) for one map; -1 when outside the placed area."""

    def __init__(self, mid):
        s = SPECS[mid]
        m = json.load(open(DIR / f"{mid}.json"))
        self.id = mid
        self.lon0, self.lat_top = s["lon0"], s["lat_top"]
        self.py = s["ppd"]
        self.px = s["ppd"] * math.cos(math.radians(s["lat_std"]))
        self.wrap = s.get("wrap")
        self.x0, self.y0, x1, y1 = m["crop"]
        self.cw, self.ch = x1 - self.x0, y1 - self.y0
        self.ox, self.oy, self.nw, self.nh = m["placed"]

    def gx(self, lon):
        sx = (lon - self.lon0) * self.px
        if self.wrap: sx = np.mod(sx, self.wrap)
        g = np.floor((sx - self.x0) * self.nw / self.cw)
        return np.where((g >= 0) & (g < self.nw), g + self.ox, -1).astype(np.int64)

    def gy(self, lat):
        sy = (self.lat_top - lat) * self.py
        g = np.floor((sy - self.y0) * self.nh / self.ch)
        return np.where((g >= 0) & (g < self.nh), g + self.oy, -1).astype(np.int64)

    def tile_lonlat(self):
        """Centre lon/lat of every game tile (NaN outside the placed area)."""
        gx = np.arange(W) + 0.5; gy = np.arange(H) + 0.5
        sx = (gx - self.ox) * self.cw / self.nw + self.x0
        sy = (gy - self.oy) * self.ch / self.nh + self.y0
        lon = self.lon0 + sx / self.px; lat = self.lat_top - sy / self.py
        lon = (lon + 180.0) % 360.0 - 180.0
        lon[(gx < self.ox) | (gx >= self.ox + self.nw)] = np.nan
        lat[(gy < self.oy) | (gy >= self.oy + self.nh)] = np.nan
        return lon, lat


def codes(mid):
    return np.frombuffer(zlib.decompress((DIR / f"{mid}.codes.bin").read_bytes()), np.uint8).reshape(H, W)


def bake(tif, ids, rows_per_chunk=512):
    grids = [Grid(i) for i in ids]
    acc = {g.id: np.zeros(W * H, np.float64) for g in grids}
    lost = {g.id: 0.0 for g in grids}
    with rasterio.open(tif) as r:
        t = r.transform
        lons = t.c + (np.arange(r.width) + 0.5) * t.a
        gxs = {g.id: g.gx(lons) for g in grids}
        total = 0.0
        for row0 in range(0, r.height, rows_per_chunk):
            n = min(rows_per_chunk, r.height - row0)
            a = r.read(1, window=Window(0, row0, r.width, n)).astype(np.float64)
            a[~np.isfinite(a) | (a < 0)] = 0.0
            total += a.sum()
            lats = t.f + (np.arange(row0, row0 + n) + 0.5) * t.e
            for g in grids:
                gy = g.gy(lats); gx = gxs[g.id]
                ok = (gy[:, None] >= 0) & (gx[None, :] >= 0)
                idx = (gy[:, None] * W + gx[None, :])[ok]
                acc[g.id] += np.bincount(idx, weights=a[ok], minlength=W * H)
                lost[g.id] += a[~ok].sum()
            print(f"\rrows {row0 + n}/{r.height}", end="", file=sys.stderr)
    print(file=sys.stderr)
    out = {}
    for g in grids:
        p = acc[g.id].reshape(H, W)
        land = codes(g.id) != 0
        on_water = p[~land].sum()
        _, (iy, ix) = distance_transform_edt(~land, return_indices=True)
        moved = np.zeros_like(p)
        np.add.at(moved, (iy[~land], ix[~land]), p[~land])
        p = np.where(land, p, 0.0) + moved
        (DIR / f"{g.id}.pop.bin").write_bytes(zlib.compress(p.astype("<f4").tobytes(), 9))
        print(f"{g.id}: in-map {p.sum()/1e9:.3f} B people (source total {total/1e9:.3f} B, outside map "
              f"{lost[g.id]/1e9:.3f} B, moved from water to nearest land {on_water/1e6:.1f} M), "
              f"max tile {p.max()/1e6:.2f} M, land tiles {int(land.sum())}")
        out[g.id] = p
    return out


if __name__ == "__main__":
    bake(sys.argv[1], sys.argv[2:] or list(SPECS))
