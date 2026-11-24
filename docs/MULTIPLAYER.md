# Multiplayer plan (branch multiplayer, owner request 2026-11-24)

Modes: solo (local sim, unchanged), casual (host = best player PC or the server, no Elo), ranked (server only, 1x, accounts, Elo).
Account API contract (VM side): /home/opc/frontline-server/API.md and schema.sql; game server env FRONTLINE_PORT 8070, FRONTLINE_MAX_MATCHES, FRONTLINE_SPEED_CAP, FRONTLINE_DEFAULT_BOTS, INTERNAL_KEY.

## Findings from the first survey
- Outbound seam already exists: RWSession.send_intent(intent) (client/session.gd) maps every UI intent to a main.gd call. Remote clients send the same dictionaries to the host; the host validates and runs the same code with `me` = that player's nation.
- Inbound seam: the renderer reads main.gd's own arrays (owner_map, nations, structs, attacks, boats, missiles, warships, ...). A remote client therefore does not tick the sim; it writes replicated data into those same arrays and queues the repaint. This avoids touching the ~138 client read sites.
- PLAYER is a const (~500 uses). Plan: per-client id remap. The host swaps nation id 1 with the client's own nation id in everything it sends (owner_map deltas, nation lists, intents coming back), so every client sees itself as nation 1.
- Headless: sim/headless_sim.gd already runs main.tscn without a player (sim_start/sim_step), used by tests. The server is main.tscn in a server mode (no UI/fx/audio, fixed speed cap) plus a network node.

## Phases
1 headless server mode + replication (owner deltas, nations, structs, attacks) + remote client mode, solo through loopback
2 dedicated server connect flow (casual), intent validation, rate limits
3 accounts and guests against /api/v1 (needs the account service running on 127.0.0.1:8071)
4 ranked on the server (Elo is computed by /internal/match-result)
5 Minecraft link and recover (game UI side; Skripts are on the VM)
6 PC benchmark and player hosting
7 deploy: web build in /var/www/frontline, aarch64 headless Godot 4.3 + pck in /home/opc/frontline-server/bin/

## Status
- 2026-11-24: branch created, survey done, this plan written.
- 2026-11-24: net/rep.gd (owner-change runs, snapshot, nation scalars, id swap) + game hook net_rec/net_dirty in _set_owner + tests/test_net_rep.gd (host to client over a byte pipe: owner_map identical after 300 ticks, snapshot 28k tiles = 11 KB, 5x60 ticks of deltas = 194 KB). Not done: structs/attacks/boats/missiles replication, server mode, transport, remote client mode, phases 2-7.
