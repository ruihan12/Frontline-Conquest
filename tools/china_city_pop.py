#!/usr/bin/env python3
"""Average population of a Chinese city (real-pop 1:1 city bonus), from the same GHSL data the pop bake uses.

Definition: the GHSL / Eurostat Degree of Urbanisation "urban centre" (the rule GHS-UCDB is built on):
4-connected clusters of 30" cells with density >= 1500 people/km2 and >= 50,000 people in the cluster,
holes inside a cluster filled. Cell area follows latitude (30" x 30" on the WGS84 sphere, R 6371 km).
A cluster counts for China when its population-weighted centre falls inside Natural Earth's China
(admin 0, ISO A3 CHN; mainland + Hainan; not Taiwan, Hong Kong, Macao). Reported: count, mean, median.
(GHS-UCDB itself works on a 1 km Mollweide grid with a majority-rule smoothing step; this 30" version
is the closest reproduction from the baked source.)

Usage: python3 tools/china_city_pop.py GHS_POP_...30ss.tif ne_50m_admin_0_countries.geojson
"""
import json, math, sys
import numpy as np
import rasterio
from rasterio.windows import from_bounds
from rasterio.features import rasterize
from scipy import ndimage

tif, geo = sys.argv[1], sys.argv[2]
LON0, LAT0, LON1, LAT1 = 73.0, 17.5, 135.5, 54.0
with rasterio.open(tif) as src:
    win = from_bounds(LON0, LAT0, LON1, LAT1, src.transform).round_offsets().round_lengths()
    pop = src.read(1, window=win).astype(np.float64)
    tr = src.window_transform(win)
    nod = src.nodata
if nod is not None:
    pop[pop == nod] = 0
pop[~np.isfinite(pop)] = 0
pop[pop < 0] = 0
h, w = pop.shape
lat = tr.f + tr.e * (np.arange(h) + 0.5)
R = 6371.0
d = math.radians(30 / 3600)
area = (R * d) ** 2 * np.cos(np.radians(lat))  # km2 per cell, per row
dens = pop / area[:, None]
mask = dens >= 1500.0
# fill holes: cells inside a cluster's outline join it; then 4-connected clusters
filled = ndimage.binary_fill_holes(mask)
lab, n = ndimage.label(filled)
idx = np.arange(1, n + 1)
cp = ndimage.sum(pop, lab, idx)
keep = cp >= 50000
rows = ndimage.sum(pop * np.arange(h)[:, None], lab, idx)
cols = ndimage.sum(pop * np.arange(w)[None, :], lab, idx)
geoj = json.load(open(geo))
chn = [f["geometry"] for f in geoj["features"] if f["properties"].get("ADM0_A3") == "CHN" or f["properties"].get("ISO_A3") == "CHN"]
cmask = rasterize([(g, 1) for g in chn], out_shape=(h, w), transform=tr, fill=0, dtype="uint8")
ok = []
for k in np.nonzero(keep)[0]:
    r = int(rows[k] / cp[k]); c = int(cols[k] / cp[k])
    if cmask[r, c]:
        ok.append(cp[k])
ok = np.array(sorted(ok, reverse=True))
print("urban centres in China: %d" % len(ok))
print("total people in them: %.1f M" % (ok.sum() / 1e6))
print("mean: %.0f  median: %.0f" % (ok.mean(), np.median(ok)))
print("largest 5 (M):", ", ".join("%.1f" % (x / 1e6) for x in ok[:5]))
