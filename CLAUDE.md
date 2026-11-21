# RoFront (Frontline Conquest) — handoff notes

Godot 4.3 port of upstream RoWorld (lukechatton/roworld, AGPL). Engine binary used: Godot 4.3.stable.
Last updated: 2026-11-21.

## Direction
As of Nov 21 2026 the game is "100% vanilla" (matches upstream RoWorld) except for these customs:
- Tab console (password 5516, FPS counter, match-only)
- Game speed slider 0.5x–10x
- ICBM toggle (key I): +10% cost (player only); 35% seeded chance per launch to ignore SAMs. MIRV/Scattershot warheads share the carrier's roll.
- Graphics settings window (no gameplay effect)

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

## What's left
1. Finish perf: target steady 60fps at 1x on World (user measured ~30fps).
   Known hotspots: per-tick attack pass ~80–90ms in web build (sliced 8ms/frame -> only ~1–1.5 ticks/s in software-rendered Chrome);
   full name relabel ~350ms CPU spread over 4–6s, ~25ms spike at end of spawn phase.
2. Merge fix-input-upstream + fix-gfx + fix-perf into vanilla, resolve conflicts.
3. Run parity solo (must be 0 fail), plus test_input_world, test_client_clicks, test_tutorial, test_map_camera, test_console_spawn, test_nav.
4. Web export (threads on -> needs COOP/COEP; serve.py on port 8060 sends them, serve.bat runs it). Zip and deliver.
5. Later: multiplayer. Phase 1 LAN with host-run sim (ENet desktop, relay for web). Phase 2 online dedicated headless Godot server on the Oracle VM (WebSocket + ENet, lobby, server-authoritative sim, console disabled online, maybe rofront.henrymc.org).
6. Paused backlog: batch 3 UI / ships / nukes-SAM-reinforce-SFX, custom cargo + transport planes.

## Rules for agents
- Verify claims: check git log -1, git status, and build zip dates/sizes before reporting.
- Don't push to GitHub unless the owner says so.
- Keep the vanilla customs list above as the only deviations from upstream.
