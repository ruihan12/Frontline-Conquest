# Threaded simulation inventory

This inventory covers the Godot 4.3 code at `a47712b`, the starting point for `thread-sim`. The [threaded simulation handoff](THREADED_SIM_HANDOFF.md) defines the work and test gates.

## Ownership boundaries

| Area | Current dependency | Required separation |
|---|---|---|
| Tick scheduling | `main.gd::_process_inner` slices attacks and AI, then runs naval, economy, arsenal, missiles, requests, warships and trains before notifying the host. | Keep that order. Publish at a completed tick boundary. Keep the legacy single-threaded path for headless tests and baseline comparison. |
| Frame-time simulation | `_tick_trade`, `_tick_boats`, `_tick_alliances` and the win checks run outside the fixed-tick loop. The alliance path draws from the simulation RNG. | Account for frame-time updates before transferring ownership. Moving only the fixed loop would leave two writers and change event and RNG order. |
| Map | `game/map.gd::_set_owner` changes ownership, borders, structures and fallout, records host deltas and queues repaint. | Maintain a separate render-side tile mirror. Publish absolute values for dirty tiles, including fallout-only changes. A map reset needs an initial snapshot and a new generation ID. |
| HUD and map layers | `RWGameState` exposes raw structures, units and attacks. UI rules, map painters and input handlers also read the game object directly. | Publish detached records. Resolve hover and draw data against the render mirror, then validate intents against current simulation state. |
| Effects and sound | `notify`, `add_float`, `sfx`, layer callbacks and `_viewer_event` are separate paths. Conquest effects read the presentation-side name position. Legacy `sfx` may advance the same RNG as the simulation. | Preserve effect ordering with value-only events. Compute conquest presentation on the main thread. Audit and reproduce the existing sound-related RNG draws before moving audio dispatch across threads. |
| Player input | `RWSession.send_intent` routes network intents or immediately applies local ones. Warship orders, console commands, spawning and some legacy handlers use other paths. | Route all commands that change worker-owned state through the same boundary, with a round ID and ordered delivery. Keep hover, zoom and selection on the main thread. |
| Multiplayer | `NetRep.encode_changes` drains `net_dirty`, while other encoders read live structures, nations and units. The viewer applies packets back into its render state. | Keep wire formats and per-client ID mapping intact. Give local snapshot publication its own dirty-tile cursor or journal so it cannot consume the host's changes. |
| Lifecycle | Round start, teardown, attract mode, tutorial, and save/console code share the main game node. | Stop and join a worker before freeing or reinitializing its state. Ignore late output from earlier generations. Preserve immediate mode for existing tests and callers. |

## Migration checkpoints

1. Measure seed 12345 on World with `tests/perf_sim.gd --navfree --ticks=3000`. Record every 600-tick checkpoint. Establish a repeatable frame-time and tick-rate trace separately.
2. Introduce ordered events and detached snapshot readers on the main thread. Apply events and snapshots through the intended consumer path and verify behavior before adding a worker.
3. Move only detached simulation data and computation to the worker. Keep Godot scene-tree, audio, rendering and UI access on the main thread. Do not put locks around live game state as a substitute for separating ownership.
4. Test both modes at the same seed. Run solo upstream parity and multiplayer match, replication and team tests. Profile the worker, publication, render-side apply, frame times and tick rate. Keep the feature off if end-to-end performance does not improve.

## Main-thread event migration

The regular frame loop now collects notices and floating text during each fixed-tick slice and drains them in order before the frame advances presentation. Direct calls outside that loop still present immediately, including the existing headless simulation helpers. This establishes a boundary for two value-only events. Audio, direct effects, snapshot reads and worker ownership remain separate follow-up work. The regression test is `tests/test_sim_presentation.gd`.

## Source index

The index lists direct references and common helper calls by file, function and line. One line may contain multiple calls. Aliases, indirect calls and dynamic lookups still need review as each consumer is migrated.

### Simulation calls into presentation and networking

308 matching lines across 20 files. Numbers refer to base commit `a47712b`.

- `game/audio.gd` — `_init_audio` (95, 106); `_init_audio_director` (114, 117, 118, 119); `_try_unlock_web_audio` (183); `sfx` (209, 211); `_play_music` (234); `hud_toggle_music` (261); `_stop_music` (266); `_tick_music_mood` (284); `_music_file` (287); `_music_playing` (291); `_regress` (332, 334, 335, 336, 337, 338); `_audiotest` (406, 408, 409, 410, 411, 412, 413, 414, 415, 420); `_uishot` (706, 709, 740, 741, 742, 743, 746, 756, 826, 827, 828, 831, 836, 841, 844, 846, 869, 870, 874); `_hudfit` (1536, 1537, 1538, 1539, 1540); `_hudfit_res` (1554, 1555); `audio_diag` (1660, 1661)
- `game/diplomacy.gd` — `form_alliance` (31, 34, 35); `end_alliance` (42, 44, 50, 51, 52); `extend_alliance` (76, 79); `propose_alliance` (133, 136, 138, 142); `ally_reply` (152); `_requests_tick` (223, 224, 225); `donate` (232, 240); `donate_gold` (244, 252); `_build_ally_card` (267, 273, 274, 276, 277, 278); `_show_ally_card` (283, 297); `_tick_ally_card` (306, 309, 310); `_refresh_diplo` (378)
- `game/draw_helpers.gd` — `_ship_px` (65); `_ship_sprite` (73); `_warship_click` (258, 268, 269)
- `game/economy.gd` — `select_build` (140, 146); `try_build` (165, 175, 188, 192, 197, 201, 202, 211, 214); `launch_attack` (331, 338, 343); `launch_boat` (436, 441); `_spawn_boat` (518, 519); `_tick_boats` (586, 592, 601, 604); `_supply_tick` (634, 635); `_supply_claim` (667, 668, 670); `_economy` (705, 707); `_upgrade_struct` (764, 765); `_on_conquest` (770, 775); `_struct_remove` (778); `notify` (790, 791, 792)
- `game/end_screen.gd` — `show_end` (84, 86, 93, 95)
- `game/map.gd` — `intent_attack` (263, 265); `gen_map` (330); `_rw_tile_rgb` (672); `_set_owner` (911, 912, 913, 915, 963); `_perf_autostart` (1034); `_perf_autostart_watch` (1046)
- `game/nations.gd` — `_load_progress` (53); `_clear_round_state` (69, 73, 74, 75, 76); `_set_world_visible` (82, 83); `_start_game_ui` (133); `_start_game` (190, 194, 199); `_rw_spawn_all` (297); `add_bot_players` (427, 433); `begin_shields` (453)
- `game/navy.gd` — `spawn_warship` (42); `_tick_warships_legacy` (75, 76, 77, 81, 82, 89, 94); `_ws_kill` (112); `_tick_trade` (210, 219)
- `game/nukes.gd` — `set_icbm` (69); `launch_nuke` (164, 167, 171, 176, 181, 204, 205, 206, 209, 211, 212, 213); `_detonate_missile` (251, 254, 256, 258); `detonate` (334, 335)
- `game/planes_fx.gd` — `_draw_notes` (384, 385, 387, 388, 391, 393, 394, 396, 397, 400)
- `game/rails.gd` — `_trains_tick` (464); `_tick_notes` (511)
- `game/shop.gd` — `_open_shop` (8); `unlock_arsenal_item` (20); `_open_settings` (56); `_console_spawn` (345, 364); `run_console_cmd` (426, 428)
- `game/strikes.gd` — `launch_sortie_legacy` (52, 53)
- `game/ui_anim.gd` — `_wire_anims` (68); `_set_share` (91, 92); `_game_over` (101, 105); `_to_menu` (124, 130, 135, 140)
- `game/ui_build.gd` — `_build_ui` (170, 174, 194, 195); `_show_tip` (649); `_update_hud` (772, 788, 800, 821, 844); `_update_tooltip` (934, 937); `apply_settings` (1039)
- `sim/ai.gd` — `capitulate` (411)
- `sim/arsenal.gd` — `damage_struct` (96, 104); `launch_strike` (187, 190, 208, 214, 215, 217); `strike` (272, 275, 277); `nuke_blast` (322, 324, 336); `_sam_tick` (549); `sam_resolve` (570, 572, 573, 575, 578, 579)
- `sim/attacks.gd` — `start` (216); `annex` (445)
- `sim/warships.gd` — `_posts_tick` (108); `_shoot` (290); `_shells_tick` (307, 308, 319, 320); `_vet_up` (339); `_capture_trade` (410, 411)
- `main.gd` — `_process_inner` (191, 195, 196, 201, 203, 204, 293, 295, 299, 302, 304, 352, 354, 363); `_autoshot` (899, 1028, 1029, 1032, 1053, 1079); `_feed_ranges` (1378, 1381); `_map_click` (1425); `_map_context` (1429, 1431); `_unhandled_input` (1450, 1458, 1461, 1476, 1484, 1496, 1500, 1504, 1508); `_pop_tick` (1536); `_attract_begin` (1592)

### Client access through the game object

192 matching lines across 17 files. Numbers refer to base commit `a47712b`.

- `client/borders.gd` — `_my_bodies` (30, 38, 40, 41); `touches_neutral` (64, 67, 68, 69, 70); `region_touches_me` (89); `can_reach_by_sea` (125, 129); `border` (140, 142); `neighbour_ids` (156, 162)
- `client/game_state.gd` — `file scope` (43, 52, 55, 59, 63, 66, 72); `_init` (99, 118, 136); `spawn_seconds_left` (146, 148); `grace_seconds_left` (155); `_refresh_owners` (171, 180); `_fill` (188, 195, 196, 197, 198); `owner_name` (218, 220); `owner_color` (224, 226); `tile_owner` (230, 232); `are_allies` (236); `is_traitor` (240); `is_team_game` (244); `team_of` (248, 250); `team_name` (259); `team_ranking` (270, 272, 274); `has_fallout` (284); `borders_tile` (289); `alliance_info` (295, 297); `has_alliance` (305); `borders_owner` (332); `income` (347, 349); `troop_growth` (357); `has_coast` (373, 374, 376); `structures` (406, 408, 414); `units` (440, 442); `unit` (463); `attacks` (472, 476); `reinforce_ready` (500, 502); `nukes` (519, 524)
- `client/map/fallout_glow.gd` — `_heat` (213, 215); `_recompute` (261, 334)
- `client/map/front_layer.gd` — `poll` (138, 143, 150, 161, 163, 178)
- `client/map/map_surface.gd` — `_palette` (106, 108); `tile_color` (146, 149, 170, 171); `set_hover` (195); `_sweep` (204); `step` (232, 238, 241, 250)
- `client/map/map_view.gd` — `focus_owner` (70, 72); `aim_sams` (118, 119, 122); `set_selected_unit` (142); `draw_markers` (221, 225, 226, 227)
- `client/map/name_layer.gd` — `label_tile` (136, 142); `_job_for` (184); `_fill_step` (202); `_place_from_box` (272, 275); `_place` (310); `_place_spawn` (326); `_live` (341); `_refresh_queue` (347); `_placement_step` (373, 388, 401, 412); `crown_of` (434, 435); `_process` (444); `_draw_body` (471, 481, 521, 529)
- `client/map/range_layer.gd` — `_process` (357); `_draw_body` (399)
- `client/map/road_layer.gd` — `_colour` (227, 234); `draw` (241, 258, 259)
- `client/map/structure_layer.gd` — `draw_ghost` (148, 152); `_draw_inner` (174, 183, 184, 203)
- `client/map/unit_layer.gd` — `_owner_col` (83); `draw` (129, 133, 145, 164, 169, 176); `draw_nukes` (211, 215, 218, 226, 250); `_draw_munitions` (260, 262, 263, 268, 274, 280, 289, 290, 295, 298)
- `client/session.gd` — `move_warship` (30, 34); `local_sim` (220); `set_paused` (242)
- `client/ui/client_hud.gd` — `setup` (94, 131, 157); `show_over` (397, 404, 405); `_next_match_go` (433); `_build_spectate_pill` (553); `show_over_watched` (582, 583); `_update_spectate_pill` (594); `show_ally_card` (699); `start_tutorial` (792); `process` (876, 918, 919)
- `client/ui/title_screen.gd` — `_refresh_diff` (609)
- `client/ui/tutorial.gd` — `_process` (436, 437)
- `client/ui/ui_interact.gd` — `_send` (745)
- `client/ui/ui_rules.gd` — `rules` (90, 91); `cost` (332); `resolve_placement` (562); `_placement_exact` (645)

### Frame-loop access through inherited fields and methods

290 matching lines across 1 files. Numbers refer to base commit `a47712b`.

- `main.gd` — `_pf_line` (8, 10, 12); `_net_boot` (36, 37); `_bench_step` (103, 105, 108, 111, 114, 115, 116); `_pace_step` (133, 134, 137, 138, 139, 148, 150, 151, 157, 158, 159, 160, 162, 163, 165, 166, 167, 168, 172, 173); `_process_inner` (182, 183, 185, 190, 192, 210, 211, 215, 217, 222, 227, 233, 236, 242, 245, 252, 253, 254, 257, 260, 263, 270, 272, 278, 283, 287, 292, 293, 295, 296, 297, 298, 299, 304); `_animate_labels` (368, 376, 377); `set_speed_x` (393); `_focus_player` (409); `_focus_player_smooth` (413, 417); `_look27` (430, 433, 434, 435, 436, 439, 444, 451); `_texshot` (474, 477, 478, 479, 480, 483, 493, 495, 497, 501, 506, 507); `_rw_stats` (514, 515, 516, 517, 518, 520, 521); `_rw_start` (528, 532, 533, 537, 540); `_rwshot` (550, 551, 553, 559); `_r29_mid` (567); `_rw29` (585, 588, 594, 596, 598, 602, 603, 614, 616, 619, 620, 626, 633, 635, 637, 644); `_qualshot` (685, 688, 689, 690, 691, 694, 705, 711, 712, 713, 720, 721, 722); `_autoshot` (753, 756, 757, 758, 763, 764, 766, 767, 771, 772, 773, 775, 778, 780, 781, 782, 783, 786, 795, 796, 801, 805, 806, 807, 809, 811, 813, 814, 819, 824, 832, 833, 834, 836, 837, 838, 840, 841, 842, 848, 851, 852, 857, 859, 862, 865, 866, 868, 874, 877, 879, 883, 889, 891, 892, 893, 897, 902, 906, 911, 912, 914, 917, 918, 921, 922, 926, 929, 932, 933, 938, 942, 945, 946, 948, 952, 955, 960, 972, 974, 977, 978, 979, 997, 999, 1000, 1004, 1007, 1008, 1011, 1012, 1016, 1017, 1021, 1022, 1023, 1024, 1025, 1026, 1033, 1037, 1038, 1041, 1042, 1045, 1046, 1049, 1079); `_draw_overlay_inner` (1109, 1112, 1114, 1132, 1134, 1136, 1137, 1140, 1142, 1145, 1158, 1170, 1179, 1182); `_attack_at_cursor` (1394, 1396, 1400, 1401, 1403, 1405, 1406, 1408); `_map_click` (1424); `_unhandled_input` (1449, 1452, 1487, 1488, 1489, 1493, 1517, 1518); `_pop_tick` (1528, 1531, 1533, 1535); `_attract_begin` (1577, 1586, 1587, 1588, 1590); `_attract_check` (1597, 1598, 1599)

### Multiplayer access through the game object

140 matching lines across 5 files. Numbers refer to base commit `a47712b`.

- `net/intents.gd` — `apply` (10, 14, 16, 21, 23, 26, 29, 33, 37, 42, 46, 47, 51, 59, 62, 63); `move_warship` (71, 75)
- `net/mp_client.gd` — `on_message` (57, 59, 60, 74, 75, 76, 77, 78, 79, 84, 86, 90, 91, 93, 102, 103, 104, 105, 106, 115, 116, 118, 119, 121, 122, 131); `_play_event` (145, 165, 167)
- `net/mp_host.gd` — `start_match` (90, 91, 98, 100, 115); `any_placed` (126); `join` (179, 180, 182, 183, 184); `_broadcast_nation_info` (204); `leave` (294); `_client_nations` (312, 314); `_state_dict` (338, 340, 342, 343, 347); `on_tick` (371, 372, 377, 378, 379, 380); `check_end` (401, 410, 416, 417, 418, 419, 420, 424, 425, 426, 429, 430, 434, 437, 447, 451, 452, 453); `_admin_console` (498, 507, 513, 524, 525, 528, 529); `apply_intent` (534, 563, 580); `placements` (593); `_team_placements` (616); `_add_placement` (650, 652, 653); `make_teams` (680, 681, 687, 688, 695); `_send_teams` (702, 703, 706); `team_land` (712, 714, 715, 716, 717)
- `net/mp_node.gd` — `_process` (201, 230, 251, 252); `_report_result` (335)
- `net/rep.gd` — `encode_changes` (46, 47); `encode_snapshot` (54); `encode_tiles` (62); `apply_tiles` (94); `encode_nations` (101, 102); `apply_nations` (112, 113); `apply_lists` (169, 170, 171, 172); `_apply_attacks` (178, 190, 191)

## Detached tile reads and map effects

- The range overlay can read a render-owned tile mirror under `--sim-snapshot`. The initial publication copies ownership and fallout. Later publications transfer changed tile values, including fallout-only updates, through a journal independent of multiplayer's dirty list. Map generation and round start invalidate the mirror.
- Fallout glow, SAM interception effects, explosions, shake, structure removal and conquest effects now use queued values during the fixed-tick slice. Conquest stores the fallback position before ownership changes and reads the displayed name position when presenting the event.
- The initial snapshot probe covered range-overlay reads. Later sections track the expansion to other consumers.

## Tick-boundary input and draw consumers

- `--sim-queued-intents` queues solo `RWSession.send_intent` commands in FIFO order and drains them just before a new fixed tick. Commands carry scalar values. Retreat commands carry an attack ID, and the sim resolves the live attack at apply time. Round start and teardown discard pending commands. Network and spawn commands retain their existing paths.
- `--sim-snapshot` now supplies territory and fallout data for map drawing, including names, fronts, roads, unit markers, range rings and the fallout overlay. The mirror arrays are borrowed only for synchronous draw passes. Nation and unit records, paint state and frame-time mutations are still coupled to the game node.
- The software-rendered Chromium diagnostic held the World sim at tick 12 and let paint drain. Median frame interval went from 132.5 to 129.5 ms. That is a ceiling experiment in this environment, with both sim and repaint activity removed. It cannot establish the gain from a worker on a GPU-equipped device. The worker migration remains open.

## Nation and structure draw records

Under `--sim-snapshot`, the frame loop publishes selected nation and structure fields before painting and updating the HUD. The name layer, map palettes, and structure markers use the published records. The copy includes a separate read-only shot history so a launcher can update its reload list without changing a published frame. Round transitions invalidate the published records.

## Transport and warship draw records

With `--sim-snapshot`, the unit layer draws transports and warships from detached records. Transport paths and cumulative distances are copied. Viewer interpolation samples retain their network timestamps, and the selected warship is identified by UID. Aircraft transport heading and local warship smoothing live in render caches that expire with the unit and reset each round.

Trade ships, trains, missiles and other munitions still have live draw paths. The legacy fallback renderer also retains its original draw path. Those consumers and the fixed- and frame-time simulation ownership remain open before enabling a worker.

## Additional unit and projectile records

The opt-in draw snapshot now carries trade ships, missiles, planes, artillery and interceptor effects. Warship shells capture their target position when published. Drawing a missile arc can compute missing geometry without writing into the published record. The standard live path continues to use its existing cached arc.

Train drawing samples detached route records in snapshot mode. A main-thread capture step still resolves rail links and routes with the existing cache budgets. Rail cache budgeting, legacy fallback rendering, and the tick loop's shared state remain ownership boundaries for a worker.

The snapshot experiment also queues audio director playback. Each event retains the clock value from its original emission, so director cooldown checks use the same timestamps. The render visibility check stays at emission time.

Alliance request cards can also be queued in snapshot mode. The frame-time simulation now has a dedicated entry point covering trade, FX aging, air updates, donation cooldowns, alliance warnings and transport movement, in their original order. It still runs synchronously and uses two different clocks, both supplied by the frame loop.

Legacy playback now also uses queued presentation in snapshot mode. The simulation still chooses the stream and pitch and applies the original throttle before enqueuing playback, which preserves the draw order of the RNG. Playback no longer advances it. Camera visibility still affects which legacy events consume RNG.

## Map navigation worker

`--sim-worker-nav` moves the water-body census and navigation graph build to a worker during interactive map loading. The worker receives a private copy of the map and constructs its own graph. The scene thread keeps advancing the loading screen and takes ownership of the result after joining. It also joins on teardown. Startup, cached loads, and the default path keep their existing behavior.

In a seeded native Europe loading smoke test, the worker and inline path produced the same ownership, water-body, coastline and navigation-region hash. The longest loading-frame interval fell from 855 ms to 485 ms in that run. Total load time was 2.41 s inline and 2.59 s with the worker. This is a loading result. It does not test the live match tick loop or hardware browser frame rate.

## Fixed-tick scheduling boundary

`main.gd::_advance_fixed_ticks` now owns the time budget, tick accumulator, attack and AI resumption, and fixed-tick subsystem order. The frame loop calls it before frame-time simulation and the match-end checks. Host replication still runs after each completed tick. The regression test forces an attack pass and an AI pass to span frames and checks that input is consumed once and each subsystem runs in order.

The scheduler still uses the game node. Its fixed-tick dependencies include ownership changes that queue painting, legacy build and diplomacy side effects, and the host callback. The loading worker remains the only job that runs off the scene thread.

## Paint delivery boundary

In snapshot mode, fixed-tick slices journal tile repaint requests and alliance recolour requests. The scene thread consumes those requests before painting. Tile requests carry the four neighbour eligibility bits from the time of the change, so another capture in the same slice cannot change the queued tile order or erase an earlier repaint requirement. The existing paint queue still handles deduplication. Default mode keeps the immediate path.

The simulation still owns territory changes, border refreshes, and structure capture. The journal removes paint-queue mutation from the snapshot-mode fixed tick but leaves the tick and rendering on the scene thread.

## Missile alert ownership

Snapshot-mode host and solo alerts use a simulation-assigned launch ID and detached missile records. A separate interception journal lets the HUD resolve the alert after the missile leaves the next snapshot. IDs increase across round resets so a late alert cannot reuse a previous round's ID. The viewer keeps its existing replication and alert path.

## Economy worker experiment

Run the isolated accrual benchmark with `godot --headless --path . -s tests/perf_economy_worker.gd`. It uses the World owner count and synthetic seeded accrual inputs. It excludes city counting, elimination, live state application, and the other simulation passes. The inline and worker calculations produced identical results in 1,000 comparisons. On this machine the first run took 431 µs inline versus 494 µs via the worker at the median, and 557 versus 685 µs at the 95th percentile. This measures a worker that the tick must join immediately. It does not measure overlap with rendering. The current tick still needs updated balances before proceeding to arsenal and the rest of the simulation.

## Blast footprint preparation during play

With `--sim-worker-blasts`, a missile launch queues its circular footprint geometry by radius. Each job receives only a radius and produces ordered row spans. At impact, the sim filters the spans against current land and applies damage in the original order. An unfinished job falls back to the original scan without waiting. Round reset and teardown join outstanding jobs. This moves geometry preparation off the main thread and leaves gameplay mutation with the tick.

In an isolated native benchmark with a World-sized ownership array, a prepared radius-100 scan took 2.16 ms median versus 5.63 ms for the original scan. The benchmark measures tile selection only. It excludes damage, repaint, job submission and the rest of the frame. With the flag enabled, all five seeded World checkpoints matched and parity reported 463 passed, zero failures and five intentional skips.

## Detached attack pass replay

The native profiler accepts `--worker-attacks`. It copies the inputs to the existing attack pass and runs it on a worker with a private RNG, attack queues, nation records, and map arrays. The profiler joins before replaying the captures through the normal ownership function. Team games, real population, pending attack merges, player conquest effects, and structure captures use the inline path. This experiment is confined to the profiler.

With `--ticks=3000 --seed=12345 --navfree`, 2,528 passes used the worker and all five World checkpoints matched the inline run. Average attack time including copy, join and apply was 15.53 ms versus 9.34 ms inline. Average total tick time was 21.59 ms versus 14.49 ms inline. This verifies the copied pass for the measured sequence and shows the cost of copying and replay. It does not measure overlap with rendering. The live migration still needs a persistent worker-owned map and a way to advance frame-time simulation in the same RNG and input order.

## Live attack worker prototype

`--sim-worker-attacks` submits eligible solo conquest passes to Godot's worker pool. The fixed-tick scheduler polls without waiting for an unfinished result. The scene can render while the pass is in flight. At completion, the scheduler checks that the input state still matches and replays the captured tiles in order before starting AI. A state change, structure capture, or conquest needing the player-facing event takes the inline path. The worker is joined at teardown and round reset. Multiplayer hosts and viewers continue to use their existing paths.

The experiment queues solo intents and holds frame-time simulation updates while the attack job is pending. Those updates resume using accumulated time, so this mode can shift when frame-time RNG draws and movement occur. It is disabled by default. It does not yet preserve the live match's frame-by-frame timeline or put the complete simulation on the worker. The headless regression covers submission without a join, commit on a later frame, and an inline fallback after an intervening RNG change.

A seeded native headless run of 300 live World frames at 1× applied 41 worker results. Inline and worker runs measured 6.44 and 7.06 completed ticks per second respectively. The 95th-percentile frame interval rose from 46.67 ms to 56.27 ms. This single comparison includes copying and replay on the scene thread. It does not establish browser or phone performance.

The live attack worker now retains its private ownership and fallout arrays after a successful pass. It receives intervening tile changes before the next submission. A map revision rejects results if capture or fallout changes during a pass. Rejected results rebuild the private map from current state on the next submission. Terrain stays read-only during play and map generation joins the worker before changing it.

A subsequent 300-frame native smoke run measured 7.65 completed ticks/s and a 49.67 ms 95th-percentile frame interval with the worker flag. This is a single headless sample. Simulation still falls short of 10 ticks/s at 1× in that run.

## Attack replay and render publication

The seeded World profiler now submits and applies attacks through the production worker, joining the task before the remaining simulated tick stages. Bot-only structure captures replay in order through the normal ownership path. Captures involving the local player can fall back for presentation and sound. A rejected worker result journals its changed tiles for repair before the next submission.

The live scheduler preserves each deferred frame's movement deltas and runs the frame updates in order after the attack result. They can still observe a different point in the fixed-tick timeline than in inline mode. Territory and fallout snapshots publish with the render records and before synchronous map paint. The render accessors consume the latest published tile data without publishing from inside draw calls.

At seed 12345 with deterministic navigation, all five 3,000-tick World checkpoints matched the inline reference. Of the 3,000 attack passes, 2,665 used the worker. AI, naval, economy and the remaining fixed-tick subsystems still run on the scene thread.

The Godot 4.3 Web export ran the live attack worker in cross-origin-isolated software Chromium. The first four sampled windows reported 4–5 FPS with the worker and 4–6 FPS inline. The worker applied 18 passes by tick 20. The two runs advanced through different ticks and shared CPU with other tests, so these figures verify browser execution and do not establish a frame-rate gain. GPU-backed browser and phone performance remain unmeasured.

The attack HUD reads detached, immutable attack rows in snapshot mode. The frame loop no longer updates the unused legacy attack smoothing fields, so the worker can validate the live attack input directly. Pending merges can also use the worker. The scene thread applies the merge tail after replay because it needs the committed borders to rebuild attack frontiers. With this change the worker handled 2,999 of 3,000 seeded World attack passes, and all five checkpoints still matched the inline reference.

The final merge-worker Web smoke applied 22 attack passes by tick 23 and verified cross-origin isolation. Fallback nation labels now keep their animation values in render state. This removes the last render-only fields the attack worker stripped from nation records to validate its input.

The broader headless checks reproduced nine `test_nuke_flight` failures at both the starting commit `a47712b` and on `thread-sim`. Eight checks expect upstream flight times despite the listed nuke speed custom. The Scattershot warhead assertion fails on both revisions as well.

## AI tick preparation and frame effects

The worker now completes queued attack merges with private copies of the relevant border sets. Live replay and the worker use the same border update routine to preserve tile insertion order. The worker then prepares AI nation standings and unique attacker counts. The scene thread recalculates those inputs when the attack pass falls back, and recalculates counts if transport orders change while a job is running.

With `--sim-worker-attacks --sim-worker-ai-scan`, the same job scans borders for AI commanders scheduled to act this tick. When the AI uses a scan, it consumes random draws from the gameplay RNG in the original order. A map change after publication triggers an inline scan. AI decisions, naval, economy, arsenal, warships and trains continue on the scene thread.

All five seeded World checkpoints matched with the AI scan flag enabled. The worker ran 2,999 of 3,000 attack passes and supplied 6,736 of the first 6,747 AI scans in a separate 600-tick coverage run. The Godot 4.3 Web export reached 20 completed worker passes in cross-origin-isolated software Chromium.

The scene thread continues aging existing blast, shell, floating-text and fallout visuals while a worker task is pending. When the held simulation frames resume, effects only age for the new frame. This keeps the visual clock running and avoids advancing a new effect with earlier frame deltas.
