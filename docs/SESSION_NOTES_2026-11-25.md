# Session notes, 2026-11-25 (Frontline Conquest / RoFront)

For picking the project up in a new session. CLAUDE.md is the source of truth for customs and rules; this file is the session's state, decisions and open items.

## Project
Ruihan (henry9149)'s Godot 4.3 port of upstream RoWorld (lukechatton/roworld, AGPL), called Frontline Conquest or RoFront. Repo: GitHub ruihan12/Frontline-Conquest (the old name ruihan12/roworldgodot redirects; the session git proxy only authorizes the OLD name, so keep origin at https://github.com/ruihan12/roworldgodot.git or pushes get 403). Local: /home/claude/roworldgodot. Upstream Luau clone: /home/claude/lukechatton/roworld. OpenFront clone: /home/claude/openfrontio/openfrontio.
Live site https://frontline.henrymc.org (Oracle VM, Cloudflare + nginx; game server 127.0.0.1:8070 /ws; account API 127.0.0.1:8071 /api). He tests on a Windows PC (Edge) and an iPhone and sends photos of the screen.
Renderer: Godot Compatibility (OpenGL, WebGL2 on web). Map is one texture drawn by MAP_SHADER (game/state.gd); layers in client/map/ use CanvasItem drawing.

## Branches (all pushed)
- multiplayer a47712b: working branch, current default. Everything below marked done is on it.
- perf-world 5699645: Codex optimization pass, NOT merged (see below).
- thread-sim 38b53ed: Codex threaded-sim groundwork, NOT merged, flags off.
- vanilla: never push to it or force-push without the owner saying so.
Stop-hook note: it keeps reporting "N unpushed commits" because the local origin/multiplayer ref is stale (push goes through the old URL). Verify with git ls-remote origin multiplayer equals HEAD instead.

## Done this session (on multiplayer)
- Name tags re-place every 0.1 s.
- SAM and silo upgrade and launch reload bars (client/map/structure_layer.gd uses g.sim_atk.tick).
- Bulk nukes launch spaced 0.2 s (NUKE_GAP_TICKS=2, queue_nuke in game/economy.gd, net/intents.gd); MIRV bulk price fixed (arithmetic series).
- Loot boxes removed from the UI (code dormant).
- Owner console: Esc then Tab, only henry9149 via a signed 7-day account token (RSA-SHA256, net/admin_console.gd, net/admin_pub.pem, server /admin/token); works online through whitelisted host commands (gold, troops, god, claim, nation ...).
- Railgun/Air Strike crosshair fix, SAM cover row hidden for strikes, no sound when a warship captures a trade ship.
- Map shader box filter (removes stray dots in skin patterns at fractional zoom).
- Credits Source button now ruihan12/Frontline-Conquest.
- Others tab: 131 OpenFront maps imported by tools/import_openfront.py (maps/upstream/of_<id>, index.json "others", sim/upstream_maps.gd ids(), picker tab in client/ui/ui_maps.gd). Largest of map/map4x/map16x with <= 2.4M tiles; 0x9F impassable tiles became water; nations snapped to land. Adds about 34 MB to the web pack. Loaded 5 of them in the headless sim; not played in full.
- Docs: docs/OPTIMIZATION_HANDOFF.md, docs/THREADED_SIM_HANDOFF.md (Codex instructions).

## Optimization (Codex, branch perf-world, head 5699645)
Sim tick 15.55 to 14.69 ms (about 6%); full paint 77 to 55 ms; name placement benchmark 373 to 285 ms; deployment name placement peak 27.9 to 4.0 ms; naval LOS 190 to 138 ms; economy 1.23 to 0.97 ms/tick; range redraw 40 to 1. Discarded (no gain): bucket queue (cannot reproduce heap equal-key order), paged front bitset, capacity-retaining heap, isolated worker job (467 us vs 406 us inline). Parity 463 pass / 0 fail / 5 intentional. nuke_flight test fails on baseline too. Software Chromium still about 6.5 fps; real GPU and phone fps unmeasured.
Upstream techniques noted (Luau): --!native/--!strict, buffer-backed flat state, bucket-queue conquest ring (RING=256), i32 border buffer, table.create, MAX_TILES_PER_TICK.

## Threaded sim (Codex, branch thread-sim, head 38b53ed)
Not threaded yet. Added docs/THREADED_SIM.md (inventory: 308 sim-to-presentation calls, 192 client reads), an ordered notice/float-text queue, sim/intent_queue.gd (solo commands queue at tick boundaries) and sim/tile_snapshot.gd (detached territory and fallout for draw layers), all opt-in. Diagnostic: skipping the sim entirely moved software Chromium only 6.5 to 7.0 fps, so rendering dominates there. My advice (still standing): do not finish threading until fps is measured on the owner's PC and phone. Safe parallelism is only isolated WorkerThreadPool jobs on copied data.

## VM drop (built from 59feb3e, delivered as vm_drop.zip, 343 MB)
web/ (build + serve.py/serve.bat), server/ (rofront.pck, service, env example), accounts/ (source), DEPLOY.md. The private console key is NOT in it. It does not include perf-world. The VM runs an old build until this is deployed.

## Open items
1. Owner: measure fps on PC and phone. Offered: build a test web zip from perf-world; then decide merging perf-world into multiplayer.
2. VM: deploy the drop; fix /ws 502 (party shows "Can't reach the server"); register henry9149; copy /home/claude/admin_keys/console_private.pem to the VM (never commit); set ADMIN_USERS=henry9149 and ADMIN_KEY_FILE; restart the account service (tell players first). Back up configs before changing them and list backup paths.
3. Server-held star wallet (design agreed: accounts hold stars server-side; not started).
4. Show other players' skins in multiplayer; flags next to usernames; single-player matches use usernames.
5. "Tf is this" Iran-label photo: unresolved, he was asked which part.
6. The "42 of 50 nukes gone" report was not reproduced (maybe SAM interception or an old live build).
7. Parity was not re-run on multiplayer HEAD after the Others import (perf-world ran it: 463/0/5). test_lobby_ui has 3 failures that predate this session.
8. Fast-forward vanilla to vanilla-merge/multiplayer: owner decision.

## Working preferences (from his memory and this session)
Terse, direct replies; no bold anywhere; ask when something can't be classified instead of guessing; avoid opt-in questions and hedging at the end; code blocks for copy-pasteable text; for HenryMC server work tell him before restarting a server with players, back up configs and list paths; no sends or posts without his approval; push to GitHub after every large update on the working branch (verify git ls-remote origin <branch> == HEAD); every web zip includes release/serve.py and release/serve.bat; keep the vanilla customs list as the only deviations from upstream; do not use Cursor cloud agents.
