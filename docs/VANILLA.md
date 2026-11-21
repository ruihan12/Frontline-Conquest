# Vanilla branch

Frontline Conquest on `vanilla` is a Godot 4.3 port of lukechatton/roworld. Gameplay, numbers, visuals, UI, and audio match upstream except for the kept customs and platform deviations listed below.

Parity (seeded solo suite, `tests/run_upstream_tests.gd`): **469 total, 464 pass, 0 fail, 0 missing, 5 intentional**. Three consecutive runs all reported 0 unexpected fail.

## Kept customs (intentional deviations)

These are required port behaviour, not leftover tweaks.

- **Tab dev console** — password `5516`, FPS, match-only. `/spawn` snapping and int64 overflow clamps are allowed.
- **Game speed slider** — 0.5–10×.
- **ICBM toggle** — key `I`, slot after MIRV; +10% of the player's bomb price; 35% chance per launch to evade SAMs (seeded `main.rng.randf()`). A MIRV rolls once for the bus and its warheads inherit it; Scattershot warheads inherit the core roll.
- **Graphics / audio settings window** — non-gameplay (resolution, shake, audio). Not a rules change.

## Platform deviations (not gameplay)

- **No public world@80 matches.** Maps always play at native size with `k_lin = 1.0`. Upstream public matches run at 80% with scaled `k_lin`.
- **Local single-player Sim only.** No Roblox server snapshot, client mirror, or co-op netcode.
- **AF_SLOW** (headless audio-fallback pacing) is skipped in this port.

## Engineering kept (non-gameplay)

These do not change rules or presentation of the game:

- Web performance: `max_fps = 0`, sim slicing, web audio / Sample playback / `default_bus_layout.tres`, threads on (`variant/thread_support=true`).
- Sharp icons via `CrispIcon` (device-pixel 1:1 resampling).
- Int64 saturation on gold / manpower so values cannot wrap.
- HUD values that outgrow their box shrink rather than clip.

## Maps, numbers, and victory

- World map is native **2000×1000**, `k_lin = 1.0` (no 1792×1600 / 1.1161 scale).
- Troop counts display as upstream: divide by 10 (`UITheme.troop_div = 10.0`). The real-pop / 1:1 land path is gone.
- **World Control %** = owned land / total land **excluding fallout**, ported from upstream `Sim._check_victory` / `Rules.WIN_SHARE` (80% win).

## Reverted (must not return)

Real-pop / 1:1, custom number format, 2.1× nuke speed / custom radii, countdown pills, 1.2× boat / warship speed, 0.75 ship icons, organic borders, grid MST roads, land-border boat rewrite, muted AI build sounds, cargo / transport planes, map edits, speck ships, no-capital, custom MIRV.

Rails follow upstream `_link_nearby` (4-neighbour BFS, hop-limited), not Kruskal MST / Manhattan L-shapes. SAM radius and reload multipliers are 1.0. Cargo / transport plane APIs are stubs.

## Live parity

`tests/upstream/test_live.gd` seeds both Godot global `seed(5516)` and `m.rng.seed = 5516` before `hs.start`, so nation spawn and grow_n priority are deterministic. Flaky cases (foe re-pick, SAM gold / fallback upgrade, warship port replacement, scatter / MIRV / troop-loss / own-coast slack, full-scan `_pt_center`) were hardened so the suite is reliably 0 fail across consecutive solo runs.
