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

### Step 5c: Arsenal and Nukes in Luau (Core/SimArsenal.luau)

What changed:
- `luau/sim/Core/SimArsenal.luau`: sim/arsenal.gd and the sim half of game/nukes.gd. Bombs in flight (launch,
  Scattershot warheads, SAM candidates, plans and hits, MIRV split, detonation, blast troops / structures /
  fallout, breaking alliances on a nuked ally), munitions (shells, air strikes, slugs), reloads, construction,
  battery targeting and fire. Godot's SortArray introsort is copied (`godot_sort`) so SAMs with tied scores fire in
  the order Godot's sort_custom gave them.
- Luau owns the missiles and munitions in flight (ids). game.missiles and sim_ars.munitions hold mirror dicts with
  the same keys in the same order (net/rep.gd sends the missile dicts whole; packets unchanged). Kept mirrors are
  the same Dictionary objects from launch to impact; the lists are changed in place.
- The structures stay GDScript's (as in 5b): each call sends a snapshot (k, tile, o, level, bt, hp, serial) and the
  silo / SAM / battery / airfield / railgun state, and gets back the writes and events in the order the GDScript sim
  made them (struct removed / downgraded, boats scaled, grudges, strike fx, SAM fired / hit, detonation, fallout,
  units in the blast, alliance broken).
- `sim/arsenal.gd` and `game/nukes.gd` are the face (`_lrun`, `luau_launch`, `luau_missiles`). The GDScript code
  stays as the fallback (remote viewers, NO_LUAU_SIM, no extension) and for the parity source checks.
- The list is updated before the events of a call are played, as the GDScript sim erases a bomb before its blast /
  SAM-hit fx. The client's view id (`cuid`, client/game_state.gd nukes()) is stamped lazily when the HUD reads the
  list inside such a callback; GDScript erases bombs one at a time between callbacks, the facade once per call, so
  the counter can run 1 or 2 apart from GDScript's. Each bomb still keeps one id for its whole flight. Not sim state.
- Limitation: a missile dict appended to game.missiles by hand (not through launch_nuke) is not flown; a warning is
  printed once. Nothing in the game does that (the screenshot props have no "lt" and were never flown).
- tests/test_luau_arsenal.gd (18 checks): Luau's sort == Godot's on ties (sizes 1..200); the custom constants match
  game/nukes.gd and game/state.gd; the same seeded match played with Luau and with NO_LUAU_SIM, with scripted silos,
  SAMs, batteries and an airfield on both sides and launches of every bomb kind and air strikes from tick 1200:
  game.missiles, munitions, structures, SAM shots and stats byte-identical after each of 2800 ticks (cuid left out),
  same map at the end; ICBM flight ticks, Scattershot and MIRV warheads sharing the roll and ICBM flag, and the
  player's ICBM evade rolls (11 of 60) identical in both runs.

Results (4.5.1): parity 472 total, 467 pass, 0 fail, 5 intentional; hash owner=3480782660 (unchanged) whole and
--sliced; test list unchanged plus test_luau_arsenal 18/18; perf AVG 11.36 / 11.07 ms/tick (5b 11.72 / 11.81).
tests/test_icbm_evade.gd and tests/test_nuke_flight.gd (not in the VERIFY list) fail the same checks as on 5b:
their expectations predate the 0.9x nuke speed and the 20% ICBM roll, and their scenes run on frames, so their
numbers differ from run to run with either sim.

### Rails split (before Step 5b2, GDScript only)

What changed:
- The rail / train sim moved out of game/rails.gd into `sim/rails.gd` (class SimRails, `game.sim_rails`): rail paths
  (A* on the minimap), station links (_build_rail_mst / _rail_hops), the link cache with its per-tick budgets,
  routes, destinations, train spawns, legs and train gold. The code is the same, with `g.` in front of the game's
  members (W, H and owner_map read into typed locals once per call).
- game/rails.gd keeps the drawing side (`_rail_neighbors_view`, the land-path helpers, the fx and notes ticks) and
  forwards the old names (`_rail_curve`, `_rail_neighbors`, `_has_rail_link`, `spawn_train_from`, `_trains_tick`)
  so the renderer, main.gd, game/audio.gd and tests/upstream/test_live.gd are unchanged.
- The state stays on the game (rail_cache, _rail_nb_cache, _rail_mst, trains, the budgets): road_layer, planes_fx,
  unit_layer and game/nations.gd read or clear it there.

Results (4.5.1): parity 472 total, 467 pass, 0 fail, 5 intentional; hash owner=3480782660 (unchanged) whole and
--sliced; test list unchanged; perf AVG 11.76 / 11.74 ms/tick (5c 11.36 / 11.07; the code path is the same plus one
forward per call, so most of the gap is run-to-run noise).

### Step 5b2: Rails, factories and trains in Luau (Core/SimRails.luau)

What changed:
- `luau/sim/Core/SimRails.luau`: sim/rails.gd line for line. Rail paths (A* on the minimap with its heap and tie
  rules), the geometry (points merged on rows / columns, lengths in float like Vector2), station links (nearest
  first, sorted with SimArsenal's copy of Godot's introsort so tied distances keep Godot's order, 4-hop check),
  the per-owner link web with its frame-tagged unfinished versions, the per-station link cache with the per-tick
  budgets (40 route searches, 40 link builds) and the pending flag, routes, destinations, spawns (rng rolls per
  factory level), legs, train gold and the float for the player.
- Luau owns the rail caches and the trains (ids). game.rail_cache, game._rail_nb_cache and game.trains hold mirrors
  with the same keys in the same order, built from what each call returns; train mirrors are the same Dictionary
  from spawn to arrival. game._rail_mst is no longer filled in Luau mode (nothing outside sim/rails.gd reads it).
  The budgets and the pending flag go in and come back each call. sim/naval.gd's per-tick hostile cache: Luau gets
  its pairs (or the same pairs from game.attacks when it is not built yet this tick) and the facade builds the cache
  after a call that asked, as the GDScript sim's first ask would.
- The structures stay GDScript's: each call sends a snapshot (id, k, tile, o, level, bt, trucks, last_spawn; id =
  tile + serial * 2^24 names a Dictionary across calls) plus the last fields of the Dictionaries dropped since the
  last call, which the caches and trains can still hold, and gets back the trucks / last_spawn writes (keys added in
  the GDScript order). Gold comes back as (payer, other side, tile, amount) records, applied in order.
- `sim/rails.gd` is the face (curve, neighbors, has_link, spawn, tick); game/rails.gd forwards the old names there.
  The GDScript code stays as the fallback (remote viewers, NO_LUAU_SIM, no extension).
- The renderer reads the mirrors only: game/rails.gd `_rail_curve_view` / `_has_rail_link_view` (draw_helpers,
  client/map/road_layer.gd, client/map/unit_layer.gd, planes_fx). Before, drawing a train or a rail could start a
  route search or a link build and spend the tick's budgets between ticks, so what the sim built depended on what
  was on screen. Headless runs (parity, hash) never drew, so their results don't change; in a window the sim no
  longer depends on the camera. A rail the sim has not searched yet is drawn once the tick has built it (each
  station is warmed every 10 ticks). Kept (Question 3, answered).
- Known differences, in cases the seeded matches never reach: GDScript compares structure Dictionaries by content
  in `st_b in links` and `trains.erase(tr)`; Luau compares identity (the same Dictionary). They differ only when a
  station is destroyed and rebuilt on the same tile with exactly the same fields while a stale link list still holds
  the old one, or when two trains have identical fields. A new map clears the link webs too (GDScript kept
  game._rail_mst across matches, so a web from the previous match could come back when owner id, _own_sv and the
  6 s bucket matched).
- tests/test_luau_rails.gd (8 checks): the same seeded match played with Luau and with NO_LUAU_SIM for 3000 ticks:
  trains (keys, route, leg, positions, t, dur, stops), rail_cache, the link cache (ver, time, stations), factories'
  keys / trucks / last_spawn, the budgets, the pending flag, the rng and every nation's gold identical after each
  tick; direct calls with a big budget (links and paths of the biggest nation's stations, spawns from its
  factories) equal; the drawing-side readers change nothing.

Results (4.5.1): parity 472 total, 467 pass, 0 fail, 5 intentional; hash owner=3480782660 (unchanged) whole and
--sliced; test list unchanged plus test_luau_rails 8/8; perf AVG 11.46 / 11.84 ms/tick (rails split 11.76 / 11.74;
the trains cost well under 0.4 ms/tick, so the change is within run-to-run noise).

### Step 5d1: water navigation in Luau (Core/SimNav.luau)

What changed:
- `luau/sim/Core/SimNav.luau`: sim/nav.gd line for line. The region graph build (regions, clusters, edges with
  float32 costs, portals, coasts), the heap A* with its tie rules, the region and route caches with the same caps,
  line of sight, raster, BFS stitch, smoothing, the Chaikin `to_points`, `find_route`, `boat_route`,
  `nearest_own_coast`, `water_path_px` and the per-tick search budget. Float32 storage and Vector2 math are
  emulated, so the answers are byte for byte GDScript's.
- `sim/nav.gd` is the face: `find_route`, `boat_route` and `water_path_px` go to Luau once the game's link is on
  (not a remote viewer, not NO_LUAU_SIM); `begin_tick` forwards the budget. The old bodies are `*_gd` and stay the
  fallback. The pure helpers (to_points, dense, los, seg_water, region_of, water_next_to) and `steer` stay
  GDScript; steer searches through `find_route`, so it follows. game/map.gd calls `sim_nav.luau_attach(self)` after
  both nav builds.
- The graph is built in Luau on the first query after the link is up, and only if this nav has not answered a
  stateful query in GDScript yet (the caches and the budget history would differ). In the seeded runs nothing
  queries before the link exists, so the whole match runs in Luau.
- `boat_route` with the game's own owner map sends nothing and Luau reads SimState's copy after `flush`. The only
  owner_map writes that skip `_set_owner` are map generation (before the link) and the main.gd showcase, which
  calls `_set_owner` on the same tile right after.
- Known costs and gaps: the map's nav is built twice (GDScript about 235 ms, Luau about 196 ms at load on the
  seed 5516 map), because the link starts after map build. The GDScript counters on the match nav (searches,
  fails, cache hits) go stale in Luau mode; `luau_stats()` has Luau's. `last_deferred` is set only by the facade
  calls. If the link fails mid-match the nav falls back to GDScript with cold caches (still a valid game, but it
  leaves the pure GDScript run). tests/test_nav.gd builds its own navs without `luau_attach`, so it still tests
  the GDScript code.
- tests/test_luau_nav.gd (14 checks): the Luau graph against a fresh GDScript build of the same map (regions,
  centres, edges, costs, portals, coasts, clusters) and 3000 find_route, 800 water_path_px and 600 boat_route
  queries against GDScript, with the deferral flags and the search / fail counters.
- Drafted in a separate worktree (luau-nav-draft, never pushed) and taken over unchanged.

Results (4.5.1): parity 472 total, 467 pass, 0 fail, 5 intentional; hash owner=3480782660 (unchanged) whole and
--sliced; test list unchanged plus test_luau_nav 14/14; perf AVG 12.39 / 11.85 ms/tick (5b2 11.46 / 11.84; the Luau
searches cost about what the GDScript ones did, the difference is within run-to-run noise).

### Step 5d2: trade ship ports in Luau (Core/SimNaval.luau)

What changed:
- `luau/sim/Core/SimNaval.luau`: sim/naval.gd's ports tick line for line (`_ports_tick`, `_pick_partner`,
  `_refresh_partners`, `_trade_path`, `hostile`): every 10 ticks each finished port rolls `level` times against the
  spawn rate with its pity timer, picks a partner port of a non-hostile owner on the same water body and finds the
  trade route (its own trade cache with the same 2000 cap, searches through Core/SimNav with the 2-per-tick budget).
- The ports stay GDScript Dictionaries in game.structs. Each call sends them in order with their trade fields (slot,
  rej, partners, ptick, water, body) and the attack pairs hostile() sees, and gets back the fields it changed (keys
  added in the GDScript order) and the new trade ships, which sim/naval.gd makes with the same cum and gold as
  before. A tick where no port rolls makes no call (the GDScript draws nothing then either). game/map.gd bumps
  `sim_naval.trade_gen` with each `trade_cache.clear()`, so Luau drops its trade cache and takes the new water bodies.
- Runs only while the nav is in Luau (Step 5d1) on the same Luau state; otherwise `_ports_tick_gd` as before.
- `sim_nav.last_deferred` is no longer set by the trade route searches (it was set inside `_trade_path`); nothing
  reads it there.
- Sailing, arrival pay, transports and warships stay GDScript (5d3, 5d4).
- tests/test_luau_naval.gd (6 checks): the seeded match with Luau and with NO_LUAU_SIM for 4000 ticks: ports,
  trade ships, gold, owner map and rng identical after each tick, same trade ships made.
- Drafted in the separate worktree with 5d1 and taken over unchanged apart from comments.

Results (4.5.1): parity 467/0/5, sim_hash 3480782660 (whole and sliced), all tests as before plus luau_naval 6/6
(4000 ticks, 1002 trade ships, identical each tick), perf_sim 13.34 / 13.81 ms/tick.
- Cost: on a tick where a port rolls, the call costs more than the GDScript did (about 1.1 vs 0.7 ms on seed 12345,
  timed around the ports tick). The Luau work itself is about the GDScript's (the trade route searches, in Luau
  in both since 5d1, dominate); the extra is the snapshot of every port (about 0.15 ms) and the flush + world()
  before the call (about 0.2 ms). Ticks where no port rolls skip both. Planned fix, before Step 6: keep the ports'
  trade fields in Luau between ticks (only naval writes them) and send one world() per tick for all the modules.

### Step 5d3: warships, shells and defense posts in Luau (Core/SimWarships.luau)

What changed:
- `luau/sim/Core/SimWarships.luau`: sim/warships.gd's tick line for line: healing near an own port and docked,
  the repair retreat below 75 %, targeting (transport > warship > trade ship, safe-from-pirates along the shore),
  shells and their landing, veterancy, patrols, trade ship captures and their new route to the captor's port, the
  defense posts' shells, and sim/nav.gd `steer` (routes through Core/SimNav). Every Vector2 operation is rounded to
  float32 like Godot's.
- Nothing is kept in Luau between ticks except the trade ships' points (sent once per ship). The trade ships
  come over only when a ship needs them that tick (a trade target, a scan that gets to trade ships): Luau stops
  in the same coroutine, sim/warships.gd sends them and Luau goes on. Most ticks no ship needs them, and there
  are a few hundred. The GDScript keeps the
  ship Dictionaries, `shells`, `tref`, the posts' memory and the stats; each tick sends them and applies what comes
  back: the ship fields (written only when changed, same types; the nav keys set and erased in steer's order), the
  shells and targets (old entries kept by identity), and the events in order (shot / lost sounds, notes, hit marks,
  sunk transports and warships, captured trade ships, which sim/warships.gd makes with the same cum, gold and key
  order as before).
- `game.ai_ship_loss` stays GDScript (AI, Step 5f). Where the tick calls it (a sunk transport, a capture), Luau
  stops in a coroutine, the batch so far is applied, the AI runs (it may move or add warships and draws the rng)
  and Luau goes on with the ships and the rng as they are then. Calls the AI returns from at once (the player's
  ships, no owner) don't stop.
- Transports and trade ships have no id field, so sim/warships.gd names them by identity across ticks (both lists
  only lose entries or grow at the end); no keys are added to their Dictionaries (net/rep.gd sends them whole).
- A target that left its list before the tick stays in `tref` until its ship looks again, as in GDScript.
- Runs only while the nav is in Luau (5d1) on the same Luau state; otherwise `_tick_gd` as before. A tick with no
  warships, no shells and no post that could fire makes no call. If a resume fails after a batch was applied the
  link goes off for the rest of the match (the GDScript can't take over half a tick); not seen in the tests.
- `SimNav.find_route_t` for steer (the corners as a table, no copy).
- tests/test_luau_warships.gd (8 checks): the seeded match with Luau and with NO_LUAU_SIM for 5000 ticks: every
  warship key in order, shells, targets, posts, stats, transports, trade ships, gold, notes and rng identical after
  each tick (up to 17 warships, 177 shots, 71 ships sunk, 152 captures, 204 stops for the AI), and the capture
  custom.

Results (4.5.1): parity 467/0/5, sim_hash 3480782660 (whole and sliced), all tests as before plus luau_warships
8/8 (5000 ticks identical), perf_sim 13.25 / 13.05 ms/tick.
- Cost: the first version sent all trade ships every tick and ran 15.3 / 15.5 ms/tick (bridge about 2 ms/tick at
  t=3000: building the trade ship list 0.45, ships / ports / posts 0.22, flush + world() 0.27, the call 0.7).
  Sending the trade ships only when a ship needs them brought it to the numbers above. flush + world() is still
  paid on every tick with warships; the one-world()-per-tick fix planned under 5d2 covers it.

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
| 5b | 88bb160 | 467/0/5 | 3480782660 | 11.72 / 11.81 | same + luau_structures 9/9 |
| 5c | b89e9f7 | 467/0/5 | 3480782660 | 11.36 / 11.07 | same + luau_arsenal 18/18 |
| rails split | 662352f | 467/0/5 | 3480782660 | 11.76 / 11.74 | same |
| 5b2 | 5dd163f | 467/0/5 | 3480782660 | 11.46 / 11.84 | same + luau_rails 8/8 |
| 5d1 | a61a285 | 467/0/5 | 3480782660 | 12.39 / 11.85 | same + luau_nav 14/14 |
| 5d2 | d412c8d | 467/0/5 | 3480782660 | 13.34 / 13.81 | same + luau_naval 6/6 |
| 5d3 | see git log | 467/0/5 | 3480782660 | 13.25 / 13.05 | same + luau_warships 8/8 |

## Customs touched per step

- Step 5d3: a warship capturing a trade ship plays no sound: SimWarships.luau capture_trade (`-- CUSTOM:`) pushes
  notes only; test_luau_warships checks it. Warship 0.7 and boat 0.35 speeds still come from the game.
- Step 5d2: none (trade ship spawns; boat 0.35 stays on the game).
- Step 5d1: none (water routes only; boat 0.35 and warship 0.7 speeds stay on the game).
- Step 5b2: none of the listed customs are in the rail / train sim (supply drops stay off; train gold and spawn
  rates are upstream's). Nothing to add a custom test for.
- Rails split: none (code moved, values unchanged).
- Step 5c: the 0.9x nuke speed (all bombs, warheads included), ICBM 1.2x speed and the 20% seeded SAM-ignore roll
  for the player's launches with the toggle on, MIRV and Scattershot warheads sharing the carrier's roll and speed:
  copied into SimArsenal.luau (`-- CUSTOM:`), the constants checked against game/nukes.gd and game/state.gd by
  test_luau_arsenal, and the rolls checked against the GDScript sim. Stay in GDScript: the ICBM +10% fee and the
  -20% silo cooldown (game/nukes.gd, applied to the shot stamp before the Luau launch), Arsenal Star prices and owned
  items (shop). Upstream values kept: SAM range, reload 90, fallout until recaptured. Supply drops stay off.
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
   Answer (Ruihan, Nov 27 2026): no, skip it for now; keep applying player and network intents when they arrive
   (online play is host-authoritative, queueing would add up to 0.1 s to every command). Deferred until lockstep or
   tick-exact replay is wanted.
2. Rails, stations, factories and trains (game/rails.gd: rail paths, the MST links, train routes, train gold) are
   part of upstream SimStructures, but here they sit with the rail drawing and train animation. Port them to Luau
   with Structures (a later sub-step) or with Economy, or keep them in GDScript? For now they stay GDScript and read
   game.structs as before.
   Answer (Ruihan, Nov 27 2026): "Port them with Structures, but split the file first". Plan: split game/rails.gd's
   sim (rail paths, links, trains) from the drawing / fx as its own commit, then port the sim half as Step 5b2.
3. Step 5b2 points the renderer at cache-only readers (`_rail_curve_view`, `_has_rail_link_view`) in both modes, so
   drawing no longer starts route searches or spends the tick's rail budgets. That changes nothing headless, but in
   a window the sim no longer depends on what is drawn, and a rail shows up once the tick has searched it instead of
   when it first comes on screen. Keep it (it is a determinism fix, needed so Luau and GDScript agree), or should the
   GDScript fallback keep the old drawing-side searches?
   Answer (Ruihan, Nov 27 2026): "Keep the new one". The renderer reads cached rails only, with and without Luau;
   no drawing-side searches come back.
