# Real-world population per tile (test, branch density-test)

Data: GHSL GHS-POP R2023A epoch 2025, 30 arc-second WGS84 grid (JRC open data, CC BY 4.0, no login).
Bake: `python3 tools/bake_population.py GHS_POP_E2025_GLOBE_R2023A_4326_30ss_V1_0.tif` (numpy, scipy,
rasterio) -> `maps/upstream/<id>.pop.bin` = zlib(float32 1792*1600 people per tile) for world, europe,
asia, northamerica, southamerica, africa. Each 30" pixel goes whole to the game tile under its centre,
through upstream make_maps.py's equirectangular projection (World: 2000/360 tiles per degree both ways,
lon0 -168.3, lat_top 88.2) and this port's crop/scale/placement (World: crop y 17..1000, scale 0.896,
placed at 0,359 as 1792x881; one tile ~0.20 deg ~22 km). People on water tiles move to the nearest land
tile. World total 8.192 B on 242k populated of 553k land tiles; Antarctica (snow) 0; max tile 18.6 M (Karachi).
Report: `python3 tools/population_report.py ne_50m_admin_0_countries.geojson <out>` (sanity table + heatmaps).

Sanity (Natural Earth country masks on the World grid, baked vs UN 2025, millions): USA 348 / 347,
China 1430 / 1416, India 1495 / 1464, Russia 148 / 144, Brazil 219 / 212, Australia 26.9 / 27,
Egypt 117 / 118, Indonesia 281 / 286, Nigeria 239 / 238, Japan 122 / 123, Pakistan 255 / 255.

Hook (off by default): `USE_REAL_POP` / `use_real_pop` in game/state.gd or `--realpop`. Nations carry
`pop` (updated in `_set_owner`), and the troop cap uses `SimRules.max_troops_pop`:
- mode 0 (default, "linear"): cap = 5000 + pop * pop_k (+ 25000 per city level), times the usual nation /
  tribe multipliers. pop_k = 1/300 matches upstream's cap for a USA-sized country: upstream
  src/shared/Core/Rules.luau:140 maxTroops = 2 * ((tiles * K_AREA)^0.6 * 1000 + 50000) = 1.17M internal
  troops for the USA's ~35.3k full-size World tiles (shown as 117K upstream: NumberFormat.luau:36
  render_troops divides by 10; this port shows raw counts and nerfs its own tile cap to ~150k).
  Bare caps at 1/300: USA 1.17M, China 4.77M, India 4.99M, Russia 0.50M, whole World 27.3M.
  At 1/1750: USA 204k, China 822k, India 859k, Russia 89k, World 4.69M. Linear k is per map in effect:
  Europe averages 653 people per tile vs World's 14.8k.
- mode 1 ("density"): normal cap curve on tiles_eff = 0.25 * tiles + 0.75 * pop / avg_pop_per_tile
Growth follows the cap through the existing (1 - troops / cap) term; nothing else changes.

Sim: `godot --headless --path . -s res://tests/density_sim.gd -- --pop off|2|1|0 --ticks 4000 --seed N`.
`--pop 2` is the 1:1 mode (troops are people, see REAL_POP_1TO1.md); 0 linear and 1 density keep the old troop scale.

Note (2026-11-20): spawns now start at Rules.start_troops (bounded by the cap) instead of at the cap, as upstream, so real-pop sims from before this date started dense spawns with far bigger armies. See docs/REAL_POP_1TO1.md for the 1:1 design.
