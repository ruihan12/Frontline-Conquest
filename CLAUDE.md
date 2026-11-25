# RoFront (Frontline Conquest) — handoff notes

Godot 4.3 port of upstream RoWorld (lukechatton/roworld, AGPL). Engine binary used: Godot 4.3.stable.
Last updated: 2026-11-23.

## Direction
As of Nov 21 2026 the game is "100% vanilla" (matches upstream RoWorld) except for these customs:
- Tab console (password 5516, FPS counter, match-only)
- Game speed slider 0.5x–10x
- ICBM toggle (key I): +10% cost (player only); 20% seeded chance per launch to ignore SAMs, +20% flight speed, -20% silo cooldown (as of Nov 22 2026). MIRV/Scattershot warheads share the carrier's roll and speed.
- Bulk launch ring (x1, x2, x5, most affordable) for every bomb (atom, hydrogen, MIRV, Mega, Scattershot; upstream: atom only), client/ui/ui_rules.gd (owner request 2026-11-24).
- Nukes fly at 0.9x upstream speed (NUKE_SPEED_X in game/nukes.gd).
- Range borders (with a mouse too: main.gd _feed_ranges feeds RangeLayer the aim; before 2026-11-24 only the touch ghost did, so SAM, post, artillery, airfield, factory and warship rings never showed before placing): armed Air Strike shows every airfield's reach; warship placement shows its 130-tile range; names show when they fit their territory.
- Title screen is a live AI-only attract simulation (5x time-lapse for first 8 s, silent, restarts on a winner or 300 s; setting save.settings.attract_on)
- No custom settings window any more (removed 2026-11-24): the gear/Settings rows open upstream's own settings page (client/ui/pause_menu.gd). FPS is uncapped (Engine.max_fps = 0) and V-Sync is off on desktop; the web follows the browser.
- Name tags: a new placement pass every 1 s of real time in a match and every 1 ms (as soon as the last pass is through) before the match, i.e. in the spawn phase (upstream: every 30 ticks); ease speed 18 (upstream 10), placement budget 3 ms, redraw 20 Hz, 0.5 px visibility hysteresis (client/map/name_layer.gd; owner request 2026-11-24).
- Cosmetic crates (3D chest client/ui/chest_view.gd, title button client/ui/crate_button.gd, top-right corner with Arsenal to its left like upstream; window client/ui/crates.gd, game/cosmetics.gd, game/cosmetics_data.gd generated from upstream Cosmetics.luau): 3000 Stars a crate, no duplicates, skins tile over the player's territory (client/map/map_surface.gd), flags are collected only (not drawn on name plates).
- Title-screen accounts with guest identities, optional local progress upload, and Minecraft linking and password recovery (client/ui/account.gd, net/api.gd).
- No automatic NEXT MATCH panel over the results (owner request 2026-11-24; client_hud.gd _maybe_next_match returns early; the menu preview still opens it).
- Player colour: 12 swatches in the pre-game (PLAY SOLO) menu, saved as save.settings.player_color, applied to your nation in game/nations.gd _start_game (owner request 2026-11-24; not used by the title attract sim).
- Supply drops (game/economy.gd _supply_tick; only in matches started from the title, supply_on): a crate lands on neutral land every 2 min after 90 s (max 3, gone after 5 min); whoever's territory covers it first gets gold, troops or (player) a free crate item. Own rng stream; tests and parity never run it.

Everything else follows upstream: native 2000x1000 World (k_lin 1.0, 400 tribes, 10 maps), troops display /10,
upstream max-troops formula, boat 0.35 / warship 0.7, upstream nuke speeds and radii, silos reach whole map,
SAM range 150 - 480/(level+5), reload 90 ticks, fallout until recaptured, tribe color #d1cdc7,
World Control bar = tiles / (contestable - fallout), win at 80%. See docs/VANILLA.md and docs/PARITY.md.

## Branches
- vanilla (e623664): main vanilla line. Parity 464 pass / 0 fail / 5 intentional (seeded 5516).
- density-test (164babe): old real-population 1:1 mode, kept for reference only.
- fix-gfx (f512577): DONE. Upstream terrain palette (0 px mismatch), tribe grey #d1cdc7 (dummy RNG calls kept for determinism), upstream name placement, StyleBox AA = exactly 1 screen px (UITheme.smooth()). Parity 464/0.
- fix-input-upstream (f89af0d): DONE, PREFERRED input fix. intent_attack ported from upstream Sim.intent_attack_troops (never launches a boat; refunds + toast if no shared border). borders.gd ported from upstream BorderTracker (3000-tile region check, sea reach requires shared water body). Test: tests/test_input_world.gd.
- fix-input (6ffca83): ALTERNATIVE input fix (whole-map landmass labelling, ~0.9s extra map load). Conflicts with fix-input-upstream in game/map.gd and client/borders.gd. Use fix-input-upstream; optionally cherry-pick its tests (tests/test_input_flow.gd, tools/web_input_test/).
- fix-perf (3abeba8): WIP, PAUSED, UNVERIFIED. Uncommitted perf edits were snapshot-committed when paused. Do not merge without review + parity.

## Done on 2026-11-22 (branch vanilla-merge, pushed)
- Merged fix-input-upstream, fix-gfx and fix-perf into vanilla (no conflicts). Parity 463 pass / 0 fail / 5 intentional; test_input_world, test_client_clicks, test_tutorial, test_map_camera, test_console_spawn, test_nav all PASS.
- Perf check (native headless, tests/perf_sim.gd, World, 400 tribes, seed 12345): first minute per tick vanilla 66 ms (worst 555) -> vanilla-merge 32 ms (worst 129); minute 2 32 ms -> 19 ms. So fix-perf is verified in the sim; the web build is still untested for fps in a real browser.
- Web export of vanilla-merge delivered as roworld_web.zip (needs COOP/COEP headers; serve.py/serve.bat are in release/).
- Perf, name labels (client/map/name_layer.gd): text metrics cached per plate, troop text refreshed at 10 Hz, layer redrawn only when the camera or hover changes or every 0.1 s (was every frame). In xvfb software GL with --perfstart --webprof: names 7.4 -> 4.4 ms/frame; process still ~25 ms/frame there (sim 13.5 of it, atk 10.9; paint 3.7, cam_paint 3.8, client_proc 5.8). xvfb frame time (~75 ms) is software rendering, not representative of a GPU.
- Not merged: fix-input (alternative), density-test. vanilla itself is unchanged: merge vanilla-merge into it when approved.

## Done on 2026-11-23 (branch vanilla-merge, pushed)
- Rails: stations are city/port/factory only (upstream; defense posts, SAMs and silos were wrongly linked); rail_path is now upstream's minimap A* (land only); the unfinished web is cached per frame (60 factories: train tick avg 52 -> 4 ms, worst 14.6 s -> 0.24 s); road layer culls and caches edges.
- docs/PLACE_COMPARE.md: RoWorld.rbxl (built about Nov 13-14) vs the repo copy (Nov 4): 160/182 scripts identical, sim identical; all 10 maps match exactly.
- Multiplayer finding: the sim is NOT lockstep-safe. It depends on time budgets (sim/nav.gd budget_us, sim_naval.defer_paths from elapsed microseconds, per-frame rail budgets, `elapsed` from real dt) and PLAYER is a const used in about 500 places. LAN options: (A) host-authoritative state replication to a thin client, or (B) make the sim tick-deterministic (count-based budgets, elapsed from ticks), make PLAYER a variable, flag human nations so the AI skips them, then lockstep intents (RWSession.send_intent already routes by owner). Needs the owner's choice.
- tests/test_input_world.gd failed once in three full-suite runs and passed twice solo: flaky, cause not found.

## Done on 2026-11-24 (branch vanilla-merge, pushed)
- Settings window removed (gear opens upstream's page), FPS uncapped, V-Sync off on desktop.
- Frame hitches at high fps: the AI pass is time-sliced like the attack pass (sim/ai.gd begin_tick/run_slice, main.gd _tick_stage), and the water-body census (~100 ms, was inside the first AI think) now runs in SimAI.setup. Worst single AI slice 184 ms -> 9 ms (tests/perf_sim.gd --sliced --real). Sliced and unsliced give the same hash with --navfree (nav's time budget makes runs differ otherwise). A real worker thread was judged unsafe: the sim calls UI/fx/audio about 80 times and the client reads sim state in about 138 places.
- New round: the finished round's sim lists and client layers are cleared and the world hidden while the map builds (nations.gd _clear_round_state/_set_world_visible; was: old territory, buildings and names showed through). Choosing a skin repaints only the player's territory (session.gd equip; was a whole-map recolour, ~4 s freeze).
- Territory repaint (game/map.gd _repaint, _paint_budget_us): a captured tile queues only its owned neighbours (neutral land and water don't change look), and the per-frame paint budget scales with game speed (to 4x). In a 10x match the stale-pixel backlog (old owner colour on tiles awaiting repaint: single-pixel dots at fronts) fell from ~17k to ~3.5k queued tiles; it is not zero while the fighting is heavy.
- UI package C updates the Tab console layout and keyboard scrolling, matches the Arsenal unlock motion, and fixes large HUD suffixes and name-plate flicker near the visibility cutoff.
- Remaining non-sliced spikes: naval up to 13 ms, economy up to 6.6 ms per tick.

## What's left
1. Measure fps of the vanilla-merge web build in a real browser; target steady 60fps at 1x on World (user measured ~30fps before fix-perf). Name relabel spike still to check.
   Known hotspots: per-tick attack pass ~80–90ms in web build (sliced 8ms/frame -> only ~1–1.5 ticks/s in software-rendered Chrome);
   full name relabel ~350ms CPU spread over 4–6s, ~25ms spike at end of spawn phase.
2. Fast-forward vanilla to vanilla-merge once the owner approves (and decide whether any 2026-11-16 main-branch fixes are wanted).
3. Run parity solo (must be 0 fail), plus test_input_world, test_client_clicks, test_tutorial, test_map_camera, test_console_spawn, test_nav.
4. Web export (threads on -> needs COOP/COEP; serve.py on port 8060 sends them, serve.bat runs it). Zip and deliver.
5. Later: multiplayer. Phase 1 LAN with host-run sim (ENet desktop, relay for web). Phase 2 online dedicated headless Godot server on the Oracle VM (WebSocket + ENet, lobby, server-authoritative sim, console disabled online, maybe rofront.henrymc.org).
6. Luau experiment (2026-11-23): tools/luau_proto shows Luau runs in a Godot 4.5 web export (~3x GDScript on the attack kernel). Not integrated; needs Godot 4.5 and Luau-owned hot state.
7. Paused backlog: batch 3 UI / ships / nukes-SAM-reinforce-SFX, custom cargo + transport planes.

## Rules for agents
- Verify claims: check git log -1, git status, and build zip dates/sizes before reporting.
- Every Web release zip must include release/serve.py and release/serve.bat (owner's rule): copy both next to index.html before zipping.
- Push to GitHub after every large update (feature, fix batch, or release build), on the current working branch only. Never push to `vanilla` or force-push without the owner saying so. Verify with `git ls-remote origin <branch>` == HEAD.
- Keep the vanilla customs list above as the only deviations from upstream.
