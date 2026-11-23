# Build vs RoWorld.rbxl (2026-11-23)

Place file: RoWorld.rbxl (md5 9afc30a4..., built about 2026-11-13/14). It is newer than the repo copy at
/root/roworld (commit ae7a350, 2026-11-04) that the parity suite was written against.

Method: the place's 182 scripts were extracted from the .rbxlx and diffed by module name against the repo's
src/. Map data was compared with the .codes.bin files shipped in maps/upstream/.

## Result
- 160 of 182 scripts are byte-identical to the repo, including every sim module (Rules, Sim*, Defs...).
  Sim parity (463-466 tests) therefore also holds against the place.
- 14 differ, none in the sim: MapThumbs, MapList, Stars, Analytics, DsGate, Handoff, Purchases, Rewards,
  ServerMain, AudioDirector, GameOver, PauseMenu, Telemetry, UIRoot.
  - MapList: 4 more regional maps (Mediterranean, Middle East, Oceania, United States). Ours has all 10.
    Width, height, land tiles and nation counts of all 10 match the place exactly.
  - Stars.solo_cap / Rewards.SOLO_GAP_S: server anti-cheat for solo payouts (2026-11-13). No server here: n/a.
  - Purchases: owed Stars payouts, per-record write queue (Roblox DataStore plumbing): n/a.
  - AudioDirector: retries sounds that failed to load (Roblox asset permission errors): n/a.
  - GameOver / PauseMenu / UIRoot / NextMatch: the "next match" screen after a new player's first solo
    match, plus an admin/staging "Next-match screen" menu item. Ours has client/ui/next_match.gd; the
    admin-only preview item and the first-match trigger are not ported (no telemetry/admin here).
- Place-only content with no counterpart: Lighting/ColorGradingEffect (Roblox 3D lighting), Analytics, DsGate,
  Handoff, Party, Lobbies (online play).

## Gaps worth acting on
1. Online play (Party, Lobbies, Handoff): the multiplayer plan in CLAUDE.md.
2. Crates and shop (Purchases/Cosmetics/CrateArt): being added (cosmetic crates paid in Stars).
3. NextMatch trigger after a first match: optional.
