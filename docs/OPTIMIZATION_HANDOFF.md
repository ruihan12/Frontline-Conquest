# Optimization handoff (for Codex)

Repo: ruihan12/Frontline-Conquest, branch multiplayer. Godot 4.3 (binary: godot 4.3.stable), GDScript. Read CLAUDE.md first (customs list, rules for agents).

## Scope: do everything in one run (owner request 2026-11-25)
Do all of the hotspots and ideas below in one pass, not one at a time and without stopping to report between steps. Continue on branch perf-world (first commit 23f20bd: name-tag histogram reuse, 373 to 285 ms). Order: static typing audit, attack pass (flat arrays instead of Dictionaries, bucket queue only if the hash is unchanged), paint and upload, name relabel burst, naval and economy spikes, client reads, then isolated worker jobs. Keep every step that gives a measured gain and verified hash; revert the rest. Run the full test list once at the end plus the sim hash after each step, push perf-world after each large step, and finish with one summary of the before/after numbers. Do not merge into multiplayer or vanilla; the owner decides.

## Goal
Steady 60 fps at 1x on the World map (400 tribes) in the web build (threads on, Chrome/Edge) and on a phone. The owner measured about 30 fps before the earlier perf work and still reports lag. Do not change gameplay.

## Hard constraints
- Behaviour must not change. Parity must stay 0 fail (see docs/PARITY.md, seeded 5516; last known 463-464 pass / 0 fail / 5 intentional). Run it solo.
- Sim determinism: same seed gives the same result. Keep RNG draw order exactly as is (see the comments in sim/attacks.gd _add_neighbors_fast / _push_fast). tests/perf_sim.gd with --navfree gives a hash to compare before/after.
- Multiplayer host replicates the sim state (net/mp_host.gd, rep.gd); do not break replication formats.
- Keep the vanilla customs in CLAUDE.md. No new deviations from upstream.
- Worker threads for the sim were judged unsafe (sim calls UI/fx/audio about 80 times, client reads sim state in about 138 places). Do not thread the sim.
- Do not touch maps/ or the account server.

## How to measure
- Sim only, native headless: godot --headless --path . --script tests/perf_sim.gd -- --ticks=3000 --seed=12345 [--sliced --real] [--navfree]
  Baseline (CLAUDE.md): first minute about 32 ms/tick (worst 129), minute 2 about 19 ms.
- Whole frame, software GL (not representative of a GPU, use for relative changes only):
  xvfb-run godot --path . --resolution 1280x720 --rendering-driver opengl3 -- --perfstart --webprof
  Last numbers: process about 25 ms/frame, sim 13.5 (attack pass 10.9), paint 3.7, cam_paint 3.8, client_proc 5.8, names 4.4.
- Web build: export with the Web preset (threads on), serve with release/serve.py (port 8060, COOP/COEP). Check fps in a real browser if you can; the web build is the target.

## Known hotspots
1. Attack pass (sim/attacks.gd _process, _add_neighbors_fast, _push_fast, _hpush/_hpop heap): about 80-90 ms per tick in the web build, sliced to 8 ms/frame so only about 1-1.5 ticks/s in software Chrome. Heap keys are PackedInt64Array, front is a Dictionary (a.front[t] = true).
2. Name tags (client/map/name_layer.gd): placement pass every 0.1 s (owner request, keep the cadence), full relabel about 350 ms CPU spread over 4-6 s, about 25 ms spike at end of spawn phase. Spread the burst out, cache, cut per-plate work. Keep the 0.1 s pass and behaviour.
3. Territory paint and upload (game/map.gd _repaint, _paint_budget_us): stale pixel backlog at 10x speed, texture upload per frame. Consider skipping or merging uploads, dirty rects.
4. Non-sliced spikes: naval up to 13 ms, economy up to 6.6 ms per tick.
5. Client reads of sim state each frame (client_proc 5.8 ms), structure/range/road layers.

## Ideas, in rough order of payoff
- Static typing audit of every hot GDScript file (sim/*.gd, game/map.gd, game/economy.gd, client/map/*.gd): typed locals, typed arrays (Array[int], Packed*Array), typed function signatures, no Variant in loops. Godot 4 typed code is 25-150 percent faster on the web too.
- Replace Dictionaries in hot loops with flat Packed arrays indexed by tile (front set, per-nation counters). a.front[t] = true as a Dictionary is costly; a PackedByteArray flag (or the bucket queue below) is much cheaper. Memory is fine at 2000x1000.
- Upstream (Luau, lukechatton/roworld, clone at /home/claude/lukechatton/roworld if present) does its conquest with: --!native/--!strict on 31 files, buffer-backed flat state, a bucket-queue conquest ring (RING=256) instead of a binary heap, an i32 border buffer, table.create preallocation, and a MAX_TILES_PER_TICK cap. A bucket queue keyed by integer priority could replace the heap in sim/attacks.gd if it keeps the same pop order (verify with the hash; ties and RNG order matter, so match the existing order exactly or prove the hash is unchanged).
- Hoist invariant work out of loops, cache lookups (g.* property reads in hot loops are slow: copy to locals, as _process already does).
- Avoid per-frame allocations (Array/Dictionary/Vector2 churn, string formatting, duplicate()).
- Isolated worker jobs are allowed: WorkerThreadPool tasks that take a copy of their input (Packed arrays, plain values) and return a result for the main thread to apply, never touching live sim state, nodes or the RNG. Candidates: name-tag placement and territory paint/texture preparation (client side only). The threads must not change any sim result, so parity and the hash stay as they are. Web threads work in our export (COOP/COEP).
- Rendering: fewer draw calls and redraws in client layers (redraw only on change), reuse textures, avoid per-frame Image creation.
- GDExtension/C# are not options for the web export; do not add them. Luau in Godot needs 4.5 (see tools/luau_proto), out of scope.

## Process
- Work on branch multiplayer (or a branch off it). Small commits, each with before/after numbers in the message.
- After each step: tests/perf_sim.gd hash unchanged with --navfree, then at the end parity solo plus test_input_world, test_client_clicks, test_tutorial, test_map_camera, test_console_spawn, test_nav, test_paint_stale, test_nuke_flight. (test_lobby_ui has 3 failures that predate this work.)
- Push to GitHub after every large update on the working branch only (never vanilla, never force-push). Verify with git ls-remote origin <branch> equals HEAD.
- Update CLAUDE.md (a short Done entry with the measured numbers) when finished.
- Every Web release zip must include release/serve.py and release/serve.bat next to index.html.
