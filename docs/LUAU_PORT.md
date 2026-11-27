# Luau sim port: progress log

Goal: run upstream RoWorld's Luau sim (src/shared/Core/*.luau, extracted copy in luau/place/ReplicatedStorage/Airfront/Core)
inside the Godot game, one module per commit, every custom in CLAUDE.md kept. Read this file first after a context reset.

Branch `luau-sim`. The remote already had a `luau-sim` (Nov 23 prototype: 182 place scripts extracted to luau/place, native
build recipe in tools/luau_proto/README.md), purely additive on b3300b7, an ancestor of `multiplayer`. Recreating the branch
would need a force-push, so it was merged instead: 84d5260 = `multiplayer` 0fbdd55 + that prototype (no conflicts).

## How to verify (every module)

```
godot --headless --path . --script tests/run_upstream_tests.gd            # parity, 0 fail, 5 intentional
godot --headless --path . -s tests/sim_hash.gd                            # SIM_HASH, World 400 tribes, seed 5516, 6000 ticks
godot --headless --path . -s tests/sim_hash.gd -- --sliced                # same hash with both passes cut in tiny slices
godot --headless --path . -s tests/perf_sim.gd -- --seed=12345            # AVG ms/tick over 3000 ticks
```

Test list: test_ui_upstream, test_port_left, test_input_world, test_client_clicks, test_tutorial, test_map_camera,
test_console_spawn, test_nav, test_net_match, test_net_rep, test_net_lobby, test_net_teams, test_progress_sync.
Known baseline failures that must not grow: test_lobby_ui 3, test_account_ui 55.

Perf rule: never more than 25% above the pre-Step-A baseline at any step; the end result must be faster than it.

## Baselines

| what | value | engine | commit |
|---|---|---|---|
| perf before Step A (seed 12345, 3000 ticks) | AVG 13.31 ms/tick (per minute 26.02 / 14.63 / 11.10 / 7.63 / 7.15) | 4.3 | 84d5260 |
| hash before Step A (old perf_sim loop, seed 5516, 6000 ticks) | owner=2340230155 (not repeatable: time budgets) | 4.3 | 84d5260 |
| parity before Step A | 470 total, 465 pass, 0 fail, 5 intentional | 4.3 | 84d5260 |

## Log

### Step A: tick-deterministic sim (GDScript only)

What changed:
- One tick everywhere: game/audio.gd `_sim_tick_begin` (match clock +0.1 s, rail budgets reset, defense posts, attack pass
  start) and `_sim_tick_end` (naval, economy, arsenal, missiles, requests, warships, trains, trade ships, transports,
  donation cooldowns, host deltas). main.gd still slices the attack and AI passes over frames; `_sim_tick_whole` runs it
  unsliced (sim_step, tests, perf_sim, sim_hash). Before, the frame loop, `_pt_ticks` and perf_sim each had their own order.
- `elapsed` (the match clock the AI's peace checks and the path / rail caches use) moves 0.1 s per tick, not real dt.
- Transports (`_tick_boats`) and trade ships (`_tick_trade`) move once per tick (0.1 s), not per frame with real dt; the
  unit layer draws them part way into the next tick (sub_tick) so they still glide.
- Budgets are counts: SimNav `budget_n` = 12 cold searches per tick (was 3000 us); naval `path_budget` = 2 per tick as
  upstream (the frame-time `defer_paths` is gone); rail search / web budgets reset per tick, not per frame; rail drawing
  only reads the cache (`_rail_neighbors_view`), the tick warms every station once a second (`_rail_warm`).
- `PLAYER` is a variable (state.gd), value still 1.
- The AI skips the local player and every nation flagged `human` (remote people in multiplayer). Before this the AI kept
  thinking for remote humans' nations (they were in SimAI.st).
- Sounds and the nuke hover preview draw from `fx_rng`, not the sim's `rng`. The alliance-expiry card check (UI only)
  runs every 5th frame instead of on `rng.randf() < 0.2` per frame (that draw advanced the sim rng per frame).
- Donation cooldowns count down per tick by 0.1 x SPEED_BASE (same length as before: they ran on the visual clock).
- New tests/sim_hash.gd; tests/perf_sim.gd times the game's tick (atk / ai / rest) and prints AVG ms/tick.

Results (Godot 4.3.stable): parity 472 total, 467 pass, 0 fail, 5 intentional (2 more live cases ran: the air strike
path); NEW BASELINE hash owner=3480782660 (troops=213616296.6 gold=266746204.0 alive=28 structs=412) identical in two
whole runs and one --sliced run; test list unchanged from before Step A (13 pass, test_lobby_ui 3, test_account_ui 55);
perf AVG 13.76 ms/tick (+3.4% on 13.31; per minute 24.92 / 14.40 / 10.74 / 9.42 / 9.31; a different match since the rng
draws changed; `rest` is higher, the rail warm-up once a second and trade ships now being stepped inside the tick).

## Results

| step | commit | parity | hash (seed 5516, 6000 ticks) | perf AVG ms/tick (seed 12345) | tests |
|---|---|---|---|---|---|
| pre-A | 84d5260 | 465/0/5 | (2340230155, not repeatable) | 13.31 | 13 pass, lobby_ui 3, account_ui 55 |
| A (4.3) | see git log | 467/0/5 | 3480782660 | 13.76 | 13 pass, lobby_ui 3, account_ui 55 |

## Customs touched per step

- Step A: none of the listed customs change. Speed slider / attract speed still scale how many ticks run per real
  second (tick_acc); the attract boost (20x/5x/1x by real seconds) is unchanged. Supply drops stay off.

## Questions

1. Player and network intents are still applied when they arrive (between frames, so possibly between two slices of a tick).
   Upstream queues intents and runs them at the start of the next tick (Sim._process_intents). Queue them the same way
   (needed for lockstep, not for the host-authoritative multiplayer)? Not done in Step A.
