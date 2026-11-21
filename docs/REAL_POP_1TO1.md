# 1:1 real-population troops (design note, not implemented)

Goal: a mode where a nation's troop cap is the real number of people on the land it owns (the USA
about 348M, China 1.43B, India 1.50B, the World 8.19B, from the GHSL 2025 bake in
maps/upstream/<id>.pop.bin), and the HUD shows people, not game units.

Status: design only. Line numbers are for branch density-test as of this note (after 28555b7).

## Where the numbers stand today

- Upstream cap (Rules.luau:139-140): `2 * ((fullTiles)^0.6 * 1000 + 50000)` + 250k per city level.
  USA (about 35.3k full-size World tiles) = 1.17M internal troops. Upstream shows troops / 10
  (NumberFormat.render_troops), so a player sees 117K.
- This port's normal cap (sim/rules.gd:124-128) is a deliberate nerf: `5000 + 6200 * (tiles * tile_norm)^0.41`,
  so the USA is about 151k internal. The HUD also divides by 10 (client/ui/ui_theme.gd:589 `fmt_troops`).
- Real-pop test mode (sim/rules.gd:139-152, `pop_k = 1/300`) already gives a cap of `5000 + pop / 300`.

## The true ratio

- Anchored on the USA: 348M people / 1.17M upstream internal units = 297. So TROOP_SCALE = 297
  (call it 300) relative to upstream internal units, which is the scale every combat constant in sim/
  is tuned in (they are upstream's values).
- Against what players see upstream (internal / 10), that is about 2,970x. Against this port's nerfed
  cap it is about 2,300x (348M / 151k).
- There is no single ratio for every country: upstream's cap is concave in land (tiles^0.6) and
  population is not. With TROOP_SCALE = 297, a whole-world empire has 8.19B / 297 = 27.6M upstream
  units of cap, against about 5.8M for upstream's formula on all of the World's land. Big and dense
  empires get about 4.7x stronger than upstream relative to small ones. This is the snowball the ÷300
  sims showed (Nepal taking India and China and reaching a 10.8M cap).

## Proposal: one TROOP_SCALE, troops stored as people

- Add `const TROOP_SCALE := 297.0` and a match flag `pop_1to1` in sim/rules.gd. With the flag off
  everything below multiplies by 1.0 and nothing changes.
- Store troops in people (1:1) in `nations[].troops`, attacks, boats, donations and the save stats.
- Rule for every constant: an absolute troop amount is multiplied by S = TROOP_SCALE. A coefficient
  that multiplies a troop density is divided by S. A ratio, a fraction or a tile or tick count stays
  as it is. A nonlinear formula of troops is evaluated as `S * f(T / S)`, so it behaves exactly like
  upstream at upstream scale. Done this way the match plays like upstream with population-shaped caps,
  only S times bigger.
- The cap in 1:1 mode is `pop * kind/difficulty multiplier + city bonus`: no CAP_BASE, no tile curve,
  no pop_k.
- The alternative, keeping the sim in game units and multiplying only the HUD by S, plays identically
  and needs far fewer edits. It is the safer first step and a fallback if the native version shows
  precision or tuning problems. The native version is what "1:1" literally means, and it keeps
  logs, saves and debug numbers readable as people.

## Every constant and formula that must scale (S = TROOP_SCALE)

Troop cap and growth
- sim/rules.gd:124-128 `max_troops`: replaced by the population cap in 1:1 mode. CAP_BASE (111),
  CAP_K / CAP_EXP (112-113) are not used then.
- sim/rules.gd:143-152 `max_troops_pop`: becomes `pop * mult`. `pop_k` (140) = 1, no CAP_BASE.
  Tribes keep `/ 3` (150) and nations NATION_TROOP_MULT 0.5/0.75/1.0 (20, 151): decide if 1:1
  means only humans and Hard nations get all their people (proposed: yes, keep the multipliers).
- sim/rules.gd:22 CITY_TROOPS 250000 and :116 CITY_TROOPS_NERF 25000 per city level: x S would be
  74M people per city, which is absurd as "real people". Proposed: in 1:1 mode a city level adds
  +10% of the nation's population (a new constant CITY_POP_BONUS), not a flat amount.
- sim/rules.gd:156-162 `troop_growth`: `(10 + T^0.73 / 4) * (1 - T/cap)` becomes
  `S * (10 + (T/S)^0.73 / 4) * (1 - T/cap)`. If it is only multiplied by S, a 348M army would refill in
  minutes (T^0.73 grows slower than T, so growth per troop collapses; leaving it unscaled stalls).
  growth_mult (119), NATION_GROWTH_MULT (21) and the tribe 0.5 (160) stay.
- sim/rules.gd:164-166 `troop_growth_applied` floors per tick: fine at S.
- game/economy.gd:20-23 `troop_cap` and :636-643 (`cap`, `n.regen`, `n.troops +=`): call sites, they
  follow the two functions above.

Starting troops (people)
- sim/rules.gd:17 START_TROOPS_HUMAN 25000 -> 7.4M; :18 START_TROOPS_TRIBE 10000 -> 3.0M;
  :19 NATION_START_TROOPS [12500, 18750, 25000] -> [3.7M, 5.6M, 7.4M].
- game/nations.gd:224 (nations), :250 (tribes), _place_start :293 (player), game/nations.gd
  `start_troops_of` / `add_bot_player` (bot players): starts are bounded by the spawn cap. In 1:1 mode
  a spawn in an empty place (Siberia, the Sahara) starts with only the people living there. That is
  realistic, but it makes the spawn pick decisive. Proposed: keep the bound, and show the start army on
  the spawn ring before the player confirms.

Attacks (losses and speed)
- sim/rules.gd:13 ATTACK_MAG [80, 100, 120]: attacker loss per full-size tile, x S.
- sim/rules.gd:180 `neutral_loss_per_mag` (1/5, 1/10): ratio, stays. Neutral loss = mag * nl
  (sim/attacks.gd:333) is scaled through ATTACK_MAG.
- sim/rules.gd:33 TERRA_NULLIUS_COST_SCALE 2000: divided by the army (sim/attacks.gd:334), so x S.
  Without that every neutral tile hits TERRA_NULLIUS_MIN_COST (:34) and expansion becomes instant.
  MIN/MAX (34-35) are speeds and stay.
- sim/rules.gd:37 ATTACKER_LOSS_PER_DENSITY 0.0039: multiplies defender troops per tile
  (sim/attacks.gd:338, 340), so / S.
- sim/attacks.gd:340-341 `ratio` clamps (0.6-2.0, 0.82-7.5, /20): ratios, stay.
- sim/attacks.gd:346, 354, 368 defender loss `floor(dloss)` per tile: dloss is a density, so it scales
  by itself.
- sim/rules.gd:36 ATTACKER_LOSS_BASE, :29-31 large-territory depths, :174 `large_territory_bonus`
  (tiles), :32 BOT_DEFENDER_LOSS_MULT, :46-47 DEFENSE_POST_MAG / COST, :51-52 traitor debuffs: stay.
- sim/attacks.gd:307 `a.troops < 1.0` ends an attack: stays (1 person).
- game/economy.gd:339 launch_attack and :437 boats: shares, stay. sim/rules.gd BOAT_ATTACK_FRACTION
  (57), RETREAT_KEEP (42): stay.
- game/economy.gd:219-230 `tile_cost` / `tile_cost_at` (old pre-port costs, `20 + density * 1.2`):
  dead code (no callers). Delete it rather than scale it.

Defense
- Defense posts and fallout multiply the attack's mag/cost (sim/attacks.gd:325-328,
  sim/rules.gd:177 `fallout_modifier`): stay, they scale through ATTACK_MAG.
- Warships, shells on ships, structure HP and SAMs act on HP and missiles, not troops: stay.

Nukes and fallout
- Bombs: `((T - n) / T)^5` on land (sim/arsenal.gd:344-354): land based, stays.
- Warheads: sim/rules.gd:366-369 `warhead_death` = 500 per full-size tile -> 500 * S; the 3% floor
  and `excess / max` are ratios. Call sites sim/arsenal.gd:355-377 follow.
- Fallout: lifetime and the attack modifier only: stays. Nuke ranges, costs, MIRV and ICBM: gold
  and tiles, stay.

SAM
- No troop terms (cooldowns, radius, intercept odds, hp): stays.

Strikes (artillery shell, air strike, railgun)
- sim/rules.gd:282-284 SHELL_KILL_FRAC stays, SHELL_KILL_MIN 1440 / MAX 19200 -> x S.
- sim/rules.gd:286 AIRSTRIKE_KILL_PER_TILE 60 -> x S; :287 AIRSTRIKE_KILL_FRAC stays.
- sim/rules.gd:355-358 `strike_kill`, call site sim/arsenal.gd:246-256.

Reinforcements
- sim/rules.gd:295-297 and :362-363 `reinforce_troops`: 20% of the cap (scale-free), 100k gold, 30 s
  cooldown (custom, keep). At 1:1 a full USA reinforcement is 70M people. Proposed: keep it.
  game/economy.gd:182-189.

Donations and diplomacy
- game/diplomacy.gd:223-226 troop donation (share of the army, capped at 1.25x the receiver's cap):
  stays.
- sim/rules.gd:68 CAPITULATE_RATIO 8.0 (sim/ai.gd:364): ratio, stays.

AI thresholds
- sim/ai.gd:487 `tile_troops := 60.0 * _LA()` and :566 `land * 60.0 * LA`: troops per tile
  assumed for a target, x S. sim/ai.gd:501 follows from :487.
- sim/ai.gd:326, :333 `send * troops >= 1.0`: stays.
- sim/ai.gd:256-257 reserve keep, :318 fill, :361-364, :397-402, :425, :445, :526, :556, :589,
  :620, :679: ratios between armies, stay.
- Real-pop maps make "fill" (troops / cap) jumpy for nearly empty land (a cap near 0). `_cap`
  (sim/ai.gd:129) already returns at least 1; keep that guard.

Tribes and neutral land
- Neutral land has no troops in RoWorld: only the expansion cost above changes.
- Tribes: START_TROOPS_TRIBE (above), cap / 3 (sim/rules.gd:150), growth x 0.5 (:160). The tribe
  count (400 x map scale^2, game/map.gd `_tribes_for`) stays.

UI
- client/ui/ui_theme.gd:589 `fmt_troops` divides by 10 (upstream render_troops). In 1:1 mode the
  divisor is 1, so the HUD shows people (USA "348M", the World "8.19B"). Every troop label goes
  through it: top status, command bar, leaderboard, attacks panel, target card, radial menu, build
  button, name layer, advisor, game over, UI rules (rate "+X/s" at client/ui/ui_rules.gd:152).
- game/state.gd:848 `_fmt` (old HUD, debug and stress logs): K/M/B/T/Qd, fine.
- Float texts ("+2.0K" reinforcements) and the coach copy ("Keep 20%") are ratios or go through
  fmt_troops.
- game/strikes.gd:146 stats.maxtroops and the game-over "max troops" card: people, fine.

## Overflow and precision

- GDScript `int` is 64-bit (max 9.2e18) and `float` is 64-bit double (exact integers to 9e15). The
  whole World is 8.19e9 people, so there is no overflow anywhere in sim/ or game/. `int(a.troops)`
  (sim/attacks.gd:373) and `"%d"` formats are safe.
- 32-bit traps to avoid:
  - `randi()`, `randi() % n` and `randi_range` are 32-bit. Never draw a random troop amount with
    them; use `randf() * x`. There are none today.
  - Vector2, Rect2 and Color are float32 in standard Godot 4.3 builds, with 24-bit mantissas: exact
    only to 16.7M, so 348M rounds to a multiple of 32. Never store troops in them (charts, tween
    targets, meta). There are none today.
  - PackedFloat32Array: `tile_pop` (game/state.gd tile_pop, maps/*.pop.bin) holds people per tile
    (max 18.6M, Karachi), so steps of 2 people. Harmless, but nation `pop` sums (game/map.gd
    `_set_owner`) are += / -= of float32 values in double: they drift by fractions of a person and
    can go slightly negative. `max_troops_pop` already clamps with maxf(pop, 0).
  - PackedInt32Array (max 2.1e9) must never hold troops. The World (8.19B) and China or India
    (1.4-1.5B, close to the limit) would overflow or come near it. There are none today.
- Shaders: no troop data reaches a shader (only fallout_t, colours and the gradient text), so float32
  GPU precision does not matter.
- UI: render_number / big() handle B, T and Qd, so 8.19B shows as "8.19B". The number-format change
  (6-digit e-notation past Qd) never triggers for people.
- Growth uses pow(T/S, 0.73) in double: fine. A 1e-6 floor on `tf` (sim/attacks.gd:345) is a speed,
  not troops.

## Implementation order (when approved)

1. Add TROOP_SCALE and pop_1to1 to sim/rules.gd. Scale the constants above through getters
   (`mag()`, `terra_scale()`, `loss_per_density()`, ...) so the flag-off path is unchanged and the
   parity suite still passes.
2. Population cap and city bonus, growth as S * f(T/S), and start troops x S.
3. HUD divisor 10 -> 1 in 1:1 mode.
4. AI per-tile troop guesses x S.
5. Sims (tests/density_sim.gd): compare the 1:1 mode with the ÷300 mode. With S = 297 they should
   match tick for tick apart from display and the city bonus.
