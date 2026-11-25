# Codex handoff (2026-11-25)

Repo: /home/claude/roworldgodot (GitHub ruihan12/Frontline-Conquest). Branch: multiplayer (HEAD 99feb17 when written).
Godot 4.3.stable. Upstream Luau source for reference: lukechatton/roworld (AGPL).

## Rules (from CLAUDE.md, owner's rules)
- Work on branch `multiplayer` only. Never push to `vanilla`. Never force-push.
- Push after every large update; verify `git ls-remote origin multiplayer` equals `git rev-parse HEAD`.
- The game is "100% vanilla" (matches upstream) except the customs list in CLAUDE.md. Do not add deviations. If a task needs one, add it to the customs list in CLAUDE.md in the same commit.
- Do not touch the sim (sim/, game/ tick code) in ways that change determinism. Parity must stay 0 fail: `godot --headless --path . -s tests/parity.gd` (see docs/PARITY.md for the exact entry point and seed 5516).
- Run tests one at a time (overlapping Godot runs garble output). After adding a new `class_name` file run `godot --headless --path . --import` once, or use `preload` consts.
- Terse commit messages. No secrets in the repo. Never touch Roblox folders on the owner's PC.
- GDScript chain: later classes cannot be called from earlier ones in the `extends "res://game/..."` chain; use `preload`.

## How to run
- Single test: `godot --headless --path . -s tests/<name>.gd 2>&1 | grep -i "PASS\|FAIL"`.
- Always green before you start (checked 2026-11-25): test_party, test_party_net, test_lobby_ui, test_net_match, test_net_teams, test_net_rep, test_client_clicks, test_ui_upstream, test_port_left.
- Known failing before you start: tests/test_input_world.gd, one check ("click on contiguous, 120 tiles out ... sends a land attack"). Flaky; see task 9.

## Architecture in one page (read docs/MULTIPLAYER.md for detail)
- Host-authoritative replication. The server (or a player's PC) runs the real sim; viewers (`g.net_remote`) never tick.
- net/transport.gd (WebSocket for server and web, ENet for LAN), net/mp_node.gd (glue, next-match loop, account gate), net/mp_host.gd (intents, replication, teams, results), net/mp_client.gd (viewer), net/rep.gd (snapshot/delta/lists), net/intents.gd (whitelist).
- Per-client id swap: the receiver is always nation 1 (`NetRep.swap_id`).
- Packet types: S_HELLO 1, S_SNAPSHOT 2, S_DELTA 3, S_NATIONS 4, S_LISTS 5, S_STATE 6, S_EVENT 7, S_END 8, S_NATION_INFO 9, S_REJECT 10, S_RESULT 11, S_TEAMS 12, S_PARTY 13, S_GO 14, S_NOTICE 15; C_JOIN 1, C_INTENT 2, C_PARTY 3.
- Team games: net/teams.gd (Core/Teams.luau rules), game/diplomacy.gd `allied()` / `same_team()`.
- Party: net/party.gd (rules), net/party_service.gd (server hub), net/party_net_model.gd + net/party_net.gd (client), client/ui/party_panel.gd (UI).
- UI classes: client/ui/ (GlassPanel, UITheme, UICtx). Phone layout when `ctx.compact`.

## Tasks Codex can take (each is independent; one branch commit per task, tests added)

### 1. Lobby Teams button
Today the server's mode comes from env FRONTLINE_MODE (ffa | teams | mixed). Add a Teams choice to client/ui/lobby.gd and net/net_lobby_model.gd so a player picks Casual FFA or Casual Teams (and ranked teams). The server must advertise or accept the mode: simplest is a field in C_JOIN {mode: "ffa"|"teams"} the server uses only when running `mixed`. Test: extend tests/test_lobby_ui.gd.

### 2. Team names and combined share in the UI
Upstream shows team names and the team's combined land share on the leaderboard and the top bar. Port from upstream src/client/UI (Leaderboard.luau, TopStatus/TopBar). Files here: client/ui/leaderboard.gd, client/ui/top_status.gd. Data: `g.team_mode`, `g.team_names`, nation `team`. Test: new tests/test_team_ui.gd.

### 3. Team column in match history
Account service: server/accounts/accounts/service.py already receives `team` per player in match_result. Store it and return it in the match history endpoint; show it in the lobby/account UI where history is listed. Tests: tests/test_accounts.py (14 pass now).

### 4. Teammate nuke rule
Upstream: you cannot nuke near a teammate's building. Find it in upstream Sim (grep for teammate / same_team near launch checks), port into the intent validation (game/nukes.gd launch path, and MPHost.apply_intent for online). Do not change non-team behaviour. Test: add to tests/test_net_teams.gd.

### 5. Party edge cases
- Members already inside a match should not be invitable (server: PartyService marks a peer busy when the match peer with its `party` key joins; hide busy peers from `players`).
- Name refresh: the hub name is sent only in `hello`. Add op `rename {name}` and have PartyNetModel send it when the account/guest name changes.
- Keep a party together when seats are short: MPHost.join in arrival order can split a party. If fewer free seats than the party size, reject the whole group (S_REJECT reason "party_too_big") or wait; pick the simplest and document it.
- Optional: lobby-side message when a follower's S_GO arrives but the match is full.
Tests: extend tests/test_party_net.gd.

### 6. Viewer interpolation for boats and missiles
Viewers receive lists at tick rate; boats, warships, planes, missiles jump between ticks. Interpolate positions in the client layer that draws them (client/map/*). Pure client side; do not change what the host sends unless needed. Check with tests/test_net_rep.gd that lists still apply.

### 7. Host events and fx/audio for viewers
S_EVENT exists in the protocol but the host does not send events. Forward the sim's UI/fx/audio calls (about 80 call sites: grep for `ui_`/`fx`/`sfx` calls from game/ and sim/) as small events to viewers in their id space, and play them in MPClient. Start with the loudest ones (nuke launch/detonation, SAM intercept, alliance requests, attacks received). Keep packets small; there is a per-peer budget.

### 8. Reconnect
A viewer that loses the WebSocket mid-match should reconnect and resume. Server keeps the nation for N seconds (mark `disconnected`, do not set `left`/`left_early` until the timeout), client resends C_JOIN with a resume token, server sends a fresh snapshot. Tests: new case in tests/test_net_match.gd.

### 9. Flaky tests/test_input_world.gd
Find why "click on contiguous, 120 tiles out ... sends a land attack" fails (also fails intermittently on solo runs). Do not loosen the check unless the behaviour is correct per upstream Sim.intent_attack_troops.

## Not for Codex (owner or Claude only)
- Anything on the VM, secrets, the account service's INTERNAL_KEY, systemd or nginx. See docs/VM_DEPLOY_PROMPT.md and server/deploy/.
- Release builds and zips (every web zip must include release/serve.py and release/serve.bat).
- Moving or merging `vanilla`; merging `multiplayer`.
- Any change to the sim's tick order, rng streams or budgets; parity runs and sign-off.
- Network matchmaking design and host choice by benchmark (needs the owner's decision).
- fix-perf sign-off, perf work and web fps measurement in a real browser.
- Luau experiment (needs Godot 4.5) and the paused batch 3 backlog.

## Definition of done per task
1. New or extended test passes; the "always green" list above still passes.
2. If the sim was touched at all: parity 0 fail.
3. CLAUDE.md customs list updated if behaviour differs from upstream; docs/MULTIPLAYER.md Status entry added.
4. Commit and push to `multiplayer`; verify ls-remote equals HEAD.
