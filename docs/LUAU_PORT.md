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
test_console_spawn, test_nav, test_net_match, test_net_rep, test_net_lobby, test_net_teams, test_progress_sync,
test_luau_bridge (from Step 1), test_luau_rng (from Step 2), test_luau_rules (from Step 3), test_luau_state (from Step 4).
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

### Step 0: Godot 4.5.1

What changed:
- Editor and export templates 4.5.1.stable (official f62fdbde1). Templates from Godot_v4.5.1-stable_export_templates.tpz
  in ~/.local/share/godot/export_templates/4.5.1.stable. The web templates include `web_dlink_release.zip` /
  `web_dlink_debug.zip` (GDExtension support, threads), the same thread mode as the extension build (pthread side module)
  and as the game's web preset (`variant/thread_support=true`, COOP/COEP served by release/serve.py and nginx).
  `variant/extensions_support` stays false until Step 1 puts the extension in the pack.
- First import created a `.uid` file next to every script and shader (Godot 4.4+ keeps them in the repo). No script,
  scene or shader needed changes: the import and every test ran without parse or script errors.
- project.godot `config/features` = 4.5; CLAUDE.md, README.md, server/deploy/README.md, docs/MULTIPLAYER.md,
  docs/VM_DEPLOY_PROMPT.md name 4.5.1 for this branch. The live VM and `multiplayer` / `vanilla` stay on 4.3 (a 4.5.1
  pack does not load in 4.3), so deploying this branch needs the 4.5.1 arm64 binary on the VM.
- Web export with 4.5.1 works (index.wasm 37.3 MB, index.pck 52.5 MB, no export errors). Not run in a browser here.

Results (Godot 4.5.1.stable): parity 472 total, 467 pass, 0 fail, 5 intentional; hash owner=3480782660 (troops, gold,
alive, structs, attacks, traders all equal), the same as the 4.3 Step A baseline, in a whole and a --sliced run, so the
4.3 baseline stands for later steps; test list unchanged (13 pass, test_lobby_ui 3, test_account_ui 55); perf AVG
13.53 ms/tick (Step A on 4.3: 13.76; pre-A 13.31).

### Step 1: Luau runtime + bridge

What changed:
- Runtime: fernforestgames/luau-gdextension at bc1b88d (luau 0.719, godot-cpp godot-4.5-stable), no source changes.
  `tools/luau_ext/build.sh <checkout> [web|x86_64|aarch64]` clones, builds and copies the three libraries:
  - web: `luau/ext/libgdluau.wasm` (1.78 MB), emsdk 4.0.11, wasm side module with pthreads, `-fvisibility=hidden`,
    wasm longjmp (the recipe proven in tools/luau_proto, see its README).
  - Linux x86_64: `server_build/x86_64/libgdluau.linux.x86_64.so` (headless tests and x86 servers).
  - Linux aarch64: `server_build/aarch64/libgdluau.linux.arm64.so` (the Oracle VM), cross-built with
    g++-aarch64-linux-gnu (`tools/luau_ext/aarch64-linux-gnu.cmake`).
  - Both Linux builds link `tools/luau_ext/glibc_compat.c` so they need no glibc above 2.27 (Godot 4.5.1 needs 2.28;
    the build machine has 2.39, which made the first build ask for 2.38). The script checks it with objdump.
- `luau/ext/gdluau.gdextension` lists the three. An exported server loads the library of the same file name placed next
  to the Godot binary (tested with an exported x86_64 Server Pack: `LUAU ok`; without the file the server still runs and
  prints `LUAU missing`). The dedicated server prints that line at start.
- Web preset: `variant/extensions_support=true` (Godot then uses the web_dlink templates: index.wasm 1.66 MB +
  index.side.wasm 40.5 MB + index.js 4.2 MB instead of one 37.3 MB wasm and a 0.36 MB js, plus libgdluau.wasm, so about
  10 MB more before compression). Both presets add `luau/sim/*` to the pack and exclude `luau/place/*` and `server_build/*`.
- `luau/place/.gdignore`: with the extension loaded the editor treats `.luau` as scripts; the upstream reference copy
  stays out of the import and the pack (sim modules go in `luau/sim/`). tools/luau_proto's prototype .gdextension is
  renamed `.example` so only one copy of the classes registers.
- `sim/luau_vm.gd` (LuauVM): one Lua state; `load_file` / `load_source` run a module and keep its table, `call_fn` calls
  module.fn(args) and returns the first result, buffers cross as PackedByteArray (copied at the boundary), errors come
  back as null + `last_error`. `luau/sim/hello.luau` + `tests/test_luau_bridge.gd` (10 checks).
- Known: the extension logs `ERROR: Class 'Object' doesn't exist.` once at start (one method bind in the extension; all
  documented LuaState / Luau methods the bridge uses are registered). Harmless.
- Not verified here: the web build in a browser (no browser with WebGL2 in this container; the same recipe ran in
  Chromium in the Nov 23 prototype) and the aarch64 library at run time (no arm64 machine or emulator here; it is the
  same source and glibc floor as the x86_64 one).

Results (4.5.1): parity 472 total, 467 pass, 0 fail, 5 intentional; hash owner=3480782660 (unchanged); test list
unchanged plus test_luau_bridge 10/10; perf AVG 13.22 ms/tick (the extension loads but the sim does not use it yet).

### Step 2: Roblox-globals shim, module loader, bit-exact Godot RNG

What changed:
- `luau/sim/rt/prelude.luau` runs first in the Lua state. It defines `__register(name, fn)` / `__has(name)` and a
  `require(name)` that runs each registered module chunk once and caches its result (a cycle is an error). Globals the
  upstream modules use from Roblox: `Vector3.new` / `Vector2.new` (Luau native vectors), `Color3.new` / `Color3.fromRGB`
  (frozen {R, G, B}), `Random.new(seed)` with `NextInteger` / `NextNumber` (backed by GodotRng with the raw seed, not
  Roblox's generator: the sim must match the GDScript rng, not Roblox), `task.spawn` / `task.defer` (run at once; no
  scheduler in the sim), `task.wait` (error: nothing in the sim may yield). `typeof` is Luau's own.
- `LuauVM.boot()` (sim/luau_vm.gd) runs the prelude, registers every `.luau` under luau/sim (name = path without
  extension, e.g. `Core/GodotRng`), then calls `sandbox()` (globals and library tables read-only). Upstream string
  requires (`require("./Defs")`, `require("../Net/Coop")`) are rewritten at load time to the resolved name, so copied
  upstream files need no edits. `require_module(name)` returns a module's table to GDScript.
- `luau/sim/Core/GodotRng.luau` and `luau/sim/Net/Coop.luau`: copied unchanged from upstream (c422466). GodotRng is
  Godot's PCG32 (randi, randf, randi_range, randf_range, seed hashing, hash_int for `hash(int)`).
- `luau/sim/rt/gd.luau`: what the GDScript sim does with Godot's rng, in Luau. `gd.rng(seed)` = a RandomNumberGenerator
  after `rng.seed = seed`; `gd.global` + `gd.seed(s)` = the engine's global rng after `seed(s)`; `gd.shuffle(arr)` =
  `Array.shuffle()` (Fisher-Yates from the end, j = global randi() % (i + 1)), used by navy.gd:31, nations.gd:282,
  economy.gd:378; `gd.calibrate_fused(samples)` sets GodotRng.FUSED from real `randf_range` outputs (whether the build's
  C++ compiler fused a*b+c; x86_64 official build: not fused). Dummy draws (the tribe grey #d1cdc7 path keeps its rng
  calls) need nothing special: they are ordinary calls and the test replays them.
- tests/test_luau_rng.gd + tests/luau/rng_check.luau (27 checks): loader and require rewriting, the shim globals,
  10 seeds x 3000 mixed ops (randi, randf, randi_range, randf_range, reseed) identical value for value and in the final
  rng state, hash(int) for 8 values, seed() + Array.shuffle for 3 seeds, tribe spawn order + 800 colour dummy draws for 2
  seeds, FUSED calibration.
- Note: upstream GodotRng.randi_range loops forever when the range is the full 32-bit span (bound mod 2^32 = 0). Godot
  handles that case; no sim call uses such a range, so the copy stays unchanged and the test does not use it.
- Speed: 200,000 randi + randf pairs take 139.9 ms in Luau, 11.1 ms in GDScript (native). The sim draws far fewer per
  tick, but rng-heavy modules may need a native rng later. Watch it in Step 5.

Results (4.5.1): parity 472 total, 467 pass, 0 fail, 5 intentional; hash owner=3480782660 (unchanged); test list
unchanged plus test_luau_bridge 10/10 and test_luau_rng 27/27; perf AVG 13.52 ms/tick (the sim does not use Luau yet).

### Step 3: Rules data (Core/Rules.luau)

What changed:
- `luau/sim/Core/Rules.luau`: sim/rules.gd (SimRules) transliterated line for line, not upstream's Rules.luau: our
  file already holds the customs and the 1:1 troop mode, and the hash needs our numbers. 155 constants (all of
  SimRules', plus `NUKE_KINDS` = 9, the size GDScript gets from `.size()`), `Rules.new(kl)` with the same 19 instance
  fields and `set_k`, and every function (static ones without self).
- Conventions for every ported module, written at the top of Rules.luau: data arrays are 0-based like GDScript
  (`{ [0] = ... }`) so index code reads the same; GDScript int division is `//`, `int(x)` is trunc; Vector2 is Luau's
  float32 vector; PackedFloat32Array entries are rounded with gd.f32.
- No Defs.luau: this port has no GDScript Defs (the N_* / S_* ids are in SimRules, now Rules.luau; the per-tile
  constants are in game/state.gd and move with Step 4). sim/sim_colors.gd and sim/bot_names.gd move with their
  callers (nation setup).
- SimRules stays and is still what the game calls (brief: replace it in the commit that moves its callers).
- tests/test_luau_rules.gd + tests/luau/rules_check.luau: every constant (name set and value), every instance field
  for 8 configurations (map scales 0.31 to 3.0, 1:1 mode on / off, pop cap modes 0/1/2, tile_norm, growth and gold
  multipliers), and 20,467 function calls (edge values plus seeded random inputs, nuke arcs with 97 samples, arc
  points, arc ticks) per configuration, compared as raw f64 bytes. All equal. A one-ulp change in a constant or in the
  arc interpolation makes it fail (checked).
- exp, log and pow give the same bits as GDScript's (the Linux library binds the old glibc versions, Step 1; the test
  covers sigmoid, trade gold, saturation curves, troop growth and caps).

Results (4.5.1): parity 472 total, 467 pass, 0 fail, 5 intentional; hash owner=3480782660 (unchanged); test list
unchanged plus test_luau_bridge 10/10, test_luau_rng 27/27, test_luau_rules 8/8; perf AVG 12.58 ms/tick (the sim
does not call Luau yet; run-to-run spread on this machine is about 1 ms).

### Step 4: the tile layer in Luau (Core/SimState.luau) + the sync link

What changed:
- `luau/sim/Core/SimState.luau`: the match's tile layer as Luau buffers: `owner` (i32 per tile, -2 ice, -1 water,
  0 neutral, > 0 nation) and `fallout` (u8 per tile). Luau modules read them with get_owner / get_fallout and write
  with set_owner / set_fallout, which also record the change for GDScript.
- `sim/luau_link.gd` (LuauLink, one per match process, created at the first tick): boots the Lua state and keeps the
  two copies equal while the sim is half ported. GDScript records every change it makes as (tile, value) pairs
  (`luau_dirty` in map.gd `_set_owner`, `luau_fdirty` at the two fallout writes: nuke_blast and the clear in
  `_set_owner`). `flush()` sends them to Luau (C++ copies of PackedInt32Array, no per-tile GDScript work),
  `pull()` applies what Luau modules wrote through the game's own `_set_owner` (so borders, land / pop / bounding box,
  structure capture, net replication and the fallout clear all follow) and sets fallout like nuke_blast does.
  A Luau module call is wrapped flush -> call -> pull, so writes of both sides land in the order they happen;
  `sync()` = flush + pull runs at the end of every tick (game/audio.gd `_sim_tick_end`, before the host's
  replication), so at every tick boundary the copies are equal. A new map (`sim_epoch`, bumped in gen_map) restarts
  Luau from full copies. Without the extension the link stays off and the sim runs as before.
- Pairs not a per-tile flag: two appends per owner change in `_set_owner` (which already does far more), and
  coalescing would need a GDScript loop over the changed tiles at every flush.
- Nothing in the sim reads Luau yet; the hash is the proof that recording changes nothing.
- tests/test_luau_state.gd (12 checks): copies equal every 100 ticks over 600 ticks of a seeded World match; a nuke's
  owner changes and fallout reach Luau; 300 ticks later still equal; a Luau owner write reaches owner_map through
  `_set_owner` with land counts; a Luau fallout write reaches fallout / fallout_list; owning a fallout tile from Luau
  clears it in GDScript and the clear reaches Luau with the next flush; a new map restarts the copy.

Results (4.5.1): parity 472 total, 467 pass, 0 fail, 5 intentional; hash owner=3480782660 (unchanged) whole and
--sliced; test list unchanged plus test_luau_bridge 10/10, test_luau_rng 27/27, test_luau_rules 8/8,
test_luau_state 12/12; perf AVG 13.53 ms/tick (Step 3 12.58, Step 2 13.52: the link's cost is inside this
machine's ~1 ms run-to-run spread).

### Step 5a: Attacks in Luau (Core/SimAttacks.luau)

What changed:
- `luau/sim/Core/SimAttacks.luau`: sim/attacks.gd transliterated (attack list, per-attack front heaps, the conquest
  budget loop, merges, annexation, retreats). Same draw order on the shared sim rng: the rng state goes in as two
  uint32 halves with every call and comes back with the result.
- `luau/sim/Core/SimState.luau`: now also owns per-nation land, bounding box, last_by and the border sets (global
  per-tile linked lists, so a nation's border iterates in the same insertion order as GDScript's border Dictionary).
  One set_owner core (map.gd `_set_owner` + `_upd_border_fast`, same neighbour order) runs both for GDScript's
  recorded changes and Luau's own. Per call it is pushed only what the attack code reads: per nation troops, gold,
  alive, kind (team / left in team games), the ally keys, traitors, finished defense posts, fallout_count, land_total.
  Results stream back in order as i32 pairs: owner changes, fallout writes, and events (viewer attack notice,
  hostile = attacked_tick + grudge, conquest = gold hand-over + `_on_conquest` + last_by / killer), then the final
  troops of every nation the call touched.
- `sim/attacks.gd` is the GDScript face: start / end_attack / retreat / begin_tick / run_slice call Luau through
  `luau_link.lcall` (flush -> call -> apply). g.attacks holds one mirror Dictionary per attack (aid, a, t, troops,
  pend, retreat_at, frozen_from, started, counter, last, sent, tgt, plus the view's disp / shown / vel), updated in
  place so references held by the AI, HUD and net/rep.gd stay live. attack_between / troops_in_attacks /
  count_attacks_by read the mirror. New `scale_owner` / `set_troops` for the arsenal's troop cuts
  (sim/arsenal.gd: strike kills, nuke troop loss, warhead loss). The time slice is kept: GDScript passes the
  remaining microseconds and Luau checks os.clock every 8 attacks.
- The GDScript attack code is still there and runs when the extension is missing, on a remote viewer, or with the
  env var NO_LUAU_SIM set (A/B runs). It goes in Step 6.
- tests/test_luau_attacks.gd (12 checks): land / bb / last_by / border order equal to GDScript every 100 ticks over
  600 ticks; g.attacks mirrors Luau's list; no border-set anomalies; start, retreat, end_attack (troops back),
  scale_owner, set_troops through Luau; still equal on the next tick.

Results (4.5.1): parity 472 total, 467 pass, 0 fail, 5 intentional; hash owner=3480782660 (unchanged) whole and
--sliced, and the same with NO_LUAU_SIM=1; test list unchanged plus test_luau_attacks 12/12 (lobby_ui 3 and
account_ui 55 as before); perf AVG 11.11 / 10.93 ms/tick over two runs (Step 4 13.53). The attack pass in the
first minute went 19.72 -> 12.75 ms/tick even with the Luau rng about 12x slower per draw than the native one.

### Step 5b: Structures in Luau (Core/SimStructures.luau)

What changed:
- `luau/sim/Core/SimStructures.luau`: sim/structures.gd `place_site` (upgrade in reach, else the flood of own
  land within PLACE_SEARCH_R and the nearest tile clear of STRUCT_MIN_DIST; ports on own coast within
  PORT_SPAWN_MANHATTAN), and the construction countdown of sim/arsenal.gd tick (0.1 s per tick, activation at 0).
- `sim/structures.gd` is the face: `place_site` and `construction()` hand Luau a snapshot of game.structs first
  (f64 per structure in list order: k, tile, o, level, bt; about 0.1 ms per 400 structures) and the tile layer
  through flush. sim/arsenal.gd tick applies the new build times and calls `_activate` (the artillery's first gap is
  an rng draw) in list order, as before; the reload rings (`_refresh_cd`) stay with the arsenal (Step 5c).
- Decision: the structure list stays GDScript's in this step. It is read and written in many places outside the
  sim: the renderer, net/rep.gd (the whole dicts travel, so no new key like an id can be added without changing the
  packet), the shop's instant build, the debug modes in main.gd / game/audio.gd and the parity tests all write
  `bt`, `level`, `hp` or append dicts directly. A snapshot per call keeps all of those working without changes.
  Luau takes the list over when the per-tick readers move (arsenal 5c, AI 5f); capture on owner change stays in
  map.gd `_set_owner` until then.
- tests/test_luau_structures.gd (9 checks): Luau place_site == GDScript on 3246 clicks of a seeded match (every
  kind, own and foreign land, 92 upgrades, all four outcomes); a new post counts down 0.1 s per tick; a direct
  bt = 0 between ticks wins and the post counts as finished; an artillery battery activates when its countdown ends.

Results (4.5.1): parity 472 total, 467 pass, 0 fail, 5 intentional; hash owner=3480782660 (unchanged) whole and
--sliced; test list unchanged plus test_luau_structures 9/9; perf AVG 11.72 / 11.81 ms/tick (5a 11.11 / 10.93). The
snapshot adds 0.1 to 0.3 ms to "rest" late in the match (more structures); the attack and AI columns moved by
run-to-run noise only (their code did not change).

## Results

| step | commit | parity | hash (seed 5516, 6000 ticks) | perf AVG ms/tick (seed 12345) | tests |
|---|---|---|---|---|---|
| pre-A | 84d5260 | 465/0/5 | (2340230155, not repeatable) | 13.31 | 13 pass, lobby_ui 3, account_ui 55 |
| A (4.3) | 421aa12 | 467/0/5 | 3480782660 | 13.76 | 13 pass, lobby_ui 3, account_ui 55 |
| 0 (4.5.1) | f7214fc | 467/0/5 | 3480782660 | 13.53 | 13 pass, lobby_ui 3, account_ui 55 |
| 1 | a43b116 | 467/0/5 | 3480782660 | 13.22 | same + luau_bridge 10/10 |
| 2 | 9b35211 | 467/0/5 | 3480782660 | 13.52 | same + luau_bridge 10/10, luau_rng 27/27 |
| 3 | 0c719e1 | 467/0/5 | 3480782660 | 12.58 | same + luau_rules 8/8 |
| 4 | d85a762 | 467/0/5 | 3480782660 | 13.53 | same + luau_state 12/12 |
| 5a | e33428f | 467/0/5 | 3480782660 | 11.11 / 10.93 | same + luau_attacks 12/12 |
| 5b | see git log | 467/0/5 | 3480782660 | 11.72 / 11.81 | same + luau_structures 9/9 |

## Customs touched per step

- Step 5b: none of the listed customs are in placement or construction (the autoshot / bench build-time cut stays
  in economy.gd `_struct_add`). Supply drops stay off.
- Step 5a: none of the listed customs live in the attack code (troops /10 and the 80% win stay where they were). The
  arsenal now cuts attack troops through scale_owner / set_troops; values unchanged (hash).
- Step 4: none (recording only; the hash is unchanged).
- Step 3: none in the game (the numbers are copied). Not in SimRules: the 0.9x nuke speed (game/nukes.gd
  NUKE_SPEED_X, moves with Nukes) and the Arsenal Star prices (game/shop.gd, the shop, stays GDScript).
- Step 2: none (runtime and rng only).
- Step 1: none (runtime only).
- Step 0: none (engine only; the hash is unchanged).
- Step A: none of the listed customs change. Speed slider / attract speed still scale how many ticks run per real
  second (tick_acc); the attract boost (20x/5x/1x by real seconds) is unchanged. Supply drops stay off.

## Questions

1. Player and network intents are still applied when they arrive (between frames, so possibly between two slices of a tick).
   Upstream queues intents and runs them at the start of the next tick (Sim._process_intents). Queue them the same way
   (needed for lockstep, not for the host-authoritative multiplayer)? Not done in Step A.
2. Rails, stations, factories and trains (game/rails.gd: rail paths, the MST links, train routes, train gold) are
   part of upstream SimStructures, but here they sit with the rail drawing and train animation. Port them to Luau
   with Structures (a later sub-step) or with Economy, or keep them in GDScript? For now they stay GDScript and read
   game.structs as before.
