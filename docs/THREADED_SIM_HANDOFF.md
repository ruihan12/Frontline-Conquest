# Threaded sim handoff (for Codex)

Repo: ruihan12/Frontline-Conquest. Work on a new branch off multiplayer named thread-sim. Never merge into multiplayer or vanilla; the owner decides. Read CLAUDE.md and docs/OPTIMIZATION_HANDOFF.md first (measure, parity and push rules apply).

## Goal
Run the simulation (attack pass, AI, naval, economy, arsenal, warships, trains) on a worker thread so the main thread only renders and handles input. Target: the sim never blocks a frame; 60 fps on the main thread at 1x on World (400 tribes).

## Honest warning
The owner asked for this against advice. The sim is not written for threads: it calls UI/fx/audio about 80 times and the client reads sim state in about 138 places; Godot Arrays and Dictionaries are not safe for a concurrent read and write. Native sim cost is about 14 ms/tick, and the web frame time in software Chromium is dominated by rendering (about 6.5 fps there), so the gain may be small. Measure first and stop early if the numbers say so.

## Design (snapshot pipeline)
1. Sim thread owns all mutable sim state (owner_map, fallout, nation dictionaries, queues, RNG). It advances ticks at the game speed.
2. After each tick (or batch) it publishes an immutable snapshot for the client: PackedArrays copied or double-buffered (owner_map changes as a dirty-tile list, not a full copy), per-nation numbers, structures, units, and an event queue (sounds, toasts, effects, kills, nukes launched, captures) instead of direct UI/fx/audio calls.
3. The main thread consumes snapshots and events only: it reads the snapshot (never live sim state) and sends player intents into a thread-safe queue the sim thread drains at the start of a tick (RWSession.send_intent already routes by owner).
4. Replace the 80 direct UI/fx/audio calls in sim/ and game/ economy, nations, navy, nukes with event emissions; replace the 138 client reads (grep client/ and main.gd for g.nations, g.owner_map, g.border, g.sim_*) with snapshot reads.
5. Web: the export already has threads (COOP/COEP). Use Thread or WorkerThreadPool with a Mutex or lock-free double buffer; do not use await across threads.

## Constraints
- Sim results must not change: same seed gives the same hash as multiplayer (tests/perf_sim.gd --navfree checkpoints; parity 463 pass / 0 fail / 5 intentional). The sim's time budgets (sim/nav.gd budget_us, defer_paths, rail budgets, elapsed from real dt) make runs differ today; compare with --navfree.
- Multiplayer host (net/mp_host.gd, rep.gd) and client replication must keep working; test_net_match, test_net_rep, test_net_teams.
- Keep all customs in CLAUDE.md, the 0.1 s name-tag cadence, the owner console, save/load, the tutorial, the title attract sim.
- Headless tests call the sim directly; keep a single-threaded mode (a flag) so tests and the perf scripts still run.

## Steps
1. Inventory: list every sim-to-UI call and every client-to-sim read; write it into docs/THREADED_SIM.md.
2. Introduce the event queue and snapshot reads while the sim still runs on the main thread (no threading yet). Tests must pass unchanged. Commit.
3. Move the sim tick loop to a thread behind a flag. Add intents queue. Check the hash and parity in both modes.
4. Measure: native headless, then the threaded web build in Chromium (and the owner's PC/phone if possible). Record before/after in CLAUDE.md. If there is no gain, say so and leave the flag off.
5. Push thread-sim after each step; verify git ls-remote origin thread-sim equals HEAD.

## Risks to watch
Races on shared Packed arrays (copy-on-write does not protect a writer), RID/Node access from the thread (not allowed), RNG order changes, snapshot lag making clicks hit stale state (resolve by tile on the sim side), memory churn from snapshots at 2000x1000, and the web build's SharedArrayBuffer limits.
