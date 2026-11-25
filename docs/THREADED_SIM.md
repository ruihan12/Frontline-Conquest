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
