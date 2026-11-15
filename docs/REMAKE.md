# Remake: line-by-line port of the upstream client

Upstream RoWorld (lukechatton/roworld, AGPL-3.0) is itself a Luau port of an older Godot project, so its
client code keeps Godot names and semantics (Control, Box, Panel, Label, tween_property...). This remake
translates each upstream client file back to GDScript under client/, one file per file, same function
names, same comments where they still apply. The simulation under sim/ already passes the parity suite and
is kept. Upstream at c422466 (2026-11-13).

Support files that are not upstream client files: client/defs.gd (Core/Defs constants), client/game_state.gd and client/session.gd (upstream's GameState / Session surface over this port's sim), client/world.gd (MapView surface over the camera), client/audio.gd, client/data/arsenal.gd (Data/Arsenal), client/ui/client_hud.gd (the host that becomes UIRoot), client/ui/icbm_slot.gd (port-only).

Art comes from upstream's assets/ folder, copied to assets/rw/ (AGPL-3.0, see assets/LICENSE-AGPL-3.0-RoWorld.txt).

Kept from the old port on purpose: the custom range system, ICBM toggle, countdown, speed slider, number
suffixes, click-sound rule, Tab console and settings.

Progress: 13522 of 52913 upstream lines accounted for (18 of 86 files). Live in the game: the whole in-match HUD (top bar, command bar, status pill, spawn banner, leaderboard, attacks panel, event feed, nuke alert, hint cards, game menu, game over). The old HUD (ui_upstream/rw_hud.gd) still draws only the port's own speed chip. Not yet ported: map clicks and the radial menu, map layers, the title screens, the Arsenal window.

Order: UITheme, GlassPanel -> UICtx, UIRules, widgets (CountLabel, RatioSlider, ShopSlot...) -> HUD (TopStatus,
Leaderboard, CommandBar, EventFeed, AttackPanel) -> map layers (MapSurface, StructureLayer, UnitLayer, FxLayer,
RangeLayer, RoadLayer, NameLayer, FrontLayer) -> screens (TitleScreen, PauseMenu, GameOver, Arsenal...) -> UIRoot, Main.

| Upstream file | Lines | Godot file | Status |
|---|---:|---|---|
| src/client/Main.luau | 645 | client/main.gd | part: top bar (client/topbar.gd, lines 105-420); boot and key binds to do |
| src/client/Session.luau | 1775 | client/session.gd | todo |
| src/client/init.client.luau | 19 | client/init.client.gd | todo |
| src/client/UI/AlertBanner.luau | 260 | client/ui/alert_banner.gd | done, live |
| src/client/UI/Arsenal.luau | 1368 | client/ui/arsenal.gd | todo |
| src/client/UI/ArsenalButton.luau | 304 | client/ui/arsenal_button.gd | todo |
| src/client/UI/ArsenalDemo.luau | 1462 | client/ui/arsenal_demo.gd | todo |
| src/client/UI/AttacksPanel.luau | 462 | client/ui/attacks_panel.gd | done, live |
| src/client/UI/Banner.luau | 188 | client/ui/banner.gd | todo |
| src/client/UI/BorderTracker.luau | 327 | client/ui/border_tracker.gd | todo |
| src/client/UI/BuildButton.luau | 486 | client/ui/build_button.gd | done, live |
| src/client/UI/BusyChip.luau | 118 | client/ui/busy_chip.gd | todo |
| src/client/UI/ChestView.luau | 117 | client/ui/chest_view.gd | todo |
| src/client/UI/Coach.luau | 477 | client/ui/coach.gd | todo |
| src/client/UI/CommandBar.luau | 965 | client/ui/command_bar.gd | done, live (+ port-only ICBM slot) |
| src/client/UI/CountLabel.luau | 68 | client/ui/count_label.gd | done |
| src/client/UI/CrateButton.luau | 381 | client/ui/crate_button.gd | todo |
| src/client/UI/CrateOpening.luau | 1520 | client/ui/crate_opening.gd | todo |
| src/client/UI/EventFeed.luau | 616 | client/ui/event_feed.gd | done, live (toasts, alliance cards) |
| src/client/UI/FillBar.luau | 208 | client/ui/fill_bar.gd | done |
| src/client/UI/FlagShop.luau | 867 | client/ui/flag_shop.gd | todo |
| src/client/UI/FloatText.luau | 90 | client/ui/float_text.gd | todo |
| src/client/UI/GameOver.luau | 1174 | client/ui/game_over.gd | done, live (paid take-over card left out) |
| src/client/UI/GeneralButton.luau | 354 | client/ui/general_button.gd | todo |
| src/client/UI/GeneralOffer.luau | 444 | client/ui/general_offer.gd | todo |
| src/client/UI/GlassPanel.luau | 216 | client/ui/glass_panel.gd | ported |
| src/client/UI/GlobeNotice.luau | 251 | client/ui/globe_notice.gd | todo |
| src/client/UI/HelpOverlay.luau | 712 | client/ui/help_overlay.gd | todo |
| src/client/UI/HoldRing.luau | 71 | client/ui/hold_ring.gd | todo |
| src/client/UI/Leaderboard.luau | 663 | client/ui/leaderboard.gd | done, live (head shots / cosmetic flags left out) |
| src/client/UI/Locker.luau | 964 | client/ui/locker.gd | todo |
| src/client/UI/MapPicker.luau | 340 | client/ui/map_picker.gd | todo |
| src/client/UI/NextMatch.luau | 161 | client/ui/next_match.gd | todo |
| src/client/UI/PartyPanel.luau | 471 | client/ui/party_panel.gd | todo |
| src/client/UI/PauseMenu.luau | 853 | client/ui/pause_menu.gd | done, live (Settings row opens the port's own Settings window) |
| src/client/UI/PlaceConfirm.luau | 221 | client/ui/place_confirm.gd | todo |
| src/client/UI/Prices.luau | 117 | client/ui/prices.gd | todo |
| src/client/UI/RadialMenu.luau | 756 | client/ui/radial_menu.gd | todo |
| src/client/UI/RatioSlider.luau | 254 | client/ui/ratio_slider.gd | done, live |
| src/client/UI/RotateCard.luau | 65 | client/ui/rotate_card.gd | todo |
| src/client/UI/ShopButton.luau | 268 | client/ui/shop_button.gd | todo |
| src/client/UI/ShopLayout.luau | 59 | client/ui/shop_layout.gd | todo |
| src/client/UI/ShopSlot.luau | 356 | client/ui/shop_slot.gd | done, live |
| src/client/UI/SpawnOverlay.luau | 320 | client/ui/spawn_overlay.gd | done, live (head shots left out) |
| src/client/UI/StarterButton.luau | 340 | client/ui/starter_button.gd | todo |
| src/client/UI/StarterOffer.luau | 776 | client/ui/starter_offer.gd | todo |
| src/client/UI/Takeover.luau | 285 | client/ui/takeover.gd | todo |
| src/client/UI/TargetCard.luau | 445 | client/ui/target_card.gd | todo |
| src/client/UI/Telemetry.luau | 533 | client/ui/telemetry.gd | todo |
| src/client/UI/TitleScreen.luau | 1703 | client/ui/title_screen.gd | part: GradientText (client/ui/gradient_text.gd) |
| src/client/UI/Tooltip.luau | 314 | client/ui/tooltip.gd | done, live (slot hint cards) |
| src/client/UI/TopStatus.luau | 509 | client/ui/top_status.gd | done, live |
| src/client/UI/TouchRouter.luau | 120 | client/ui/touch_router.gd | todo |
| src/client/UI/TrayFit.luau | 63 | client/ui/tray_fit.gd | done |
| src/client/UI/Tutorial.luau | 652 | client/ui/tutorial.gd | todo |
| src/client/UI/UIAdvisor.luau | 917 | client/ui/ui_advisor.gd | todo |
| src/client/UI/UICtx.luau | 1490 | client/ui/ui_ctx.gd | done (Roblox-only drawing / module helpers left out) |
| src/client/UI/UIInteract.luau | 1745 | client/ui/ui_interact.gd | todo |
| src/client/UI/UIKern.luau | 11 | client/ui/ui_kern.gd | todo |
| src/client/UI/UILayoutProbe.luau | 215 | client/ui/ui_layout_probe.gd | todo |
| src/client/UI/UIMaps.luau | 102 | client/ui/ui_maps.gd | todo |
| src/client/UI/UIRoot.luau | 2636 | client/ui/ui_root.gd | todo |
| src/client/UI/UIRules.luau | 1383 | client/ui/ui_rules.gd | part: catalogue, costs, availability, bulk (lines 1-765); placement / primary / radial come with UIInteract |
| src/client/UI/UITheme.luau | 1955 | client/ui/ui_theme.gd | ported (glyph metric tables dropped: Godot measures text natively) |
| src/client/UI/UnitCard.luau | 305 | client/ui/unit_card.gd | todo |
| src/client/UI/Widgets.luau | 3151 | (native Godot Controls) | not needed: upstream emulates Godot Control / Container / Label / Button / Tween on Roblox; animation helpers ported as client/ui/ui_fx.gd |
| src/client/Map/AtlasReady.luau | 46 | client/map/atlas_ready.gd | todo |
| src/client/Map/FalloutGlow.luau | 713 | client/map/fallout_glow.gd | todo |
| src/client/Map/FrameClock.luau | 21 | client/map/frame_clock.gd | todo |
| src/client/Map/FrontLayer.luau | 411 | client/map/front_layer.gd | todo |
| src/client/Map/FxLayer.luau | 1015 | client/map/fx_layer.gd | todo |
| src/client/Map/MapCamera.luau | 554 | client/map/map_camera.gd | todo |
| src/client/Map/MapInput.luau | 731 | client/map/map_input.gd | todo |
| src/client/Map/MapSurface.luau | 1517 | client/map/map_surface.gd | todo |
| src/client/Map/MapView.luau | 985 | client/map/map_view.gd | todo |
| src/client/Map/NameLayer.luau | 762 | client/map/name_layer.gd | todo |
| src/client/Map/RangeLayer.luau | 717 | client/map/range_layer.gd | todo |
| src/client/Map/RoadLayer.luau | 672 | client/map/road_layer.gd | todo |
| src/client/Map/StructureLayer.luau | 633 | client/map/structure_layer.gd | todo |
| src/client/Map/TrailBudget.luau | 34 | client/map/trail_budget.gd | todo |
| src/client/Map/UnitLayer.luau | 742 | client/map/unit_layer.gd | todo |
| src/client/Map/ViewRules.luau | 145 | client/map/view_rules.gd | todo |
| src/client/Map/WakeRoute.luau | 211 | client/map/wake_route.gd | todo |
| src/client/Audio/AudioDirector.luau | 1376 | client/audio/audio_director.gd | todo |
| src/client/Audio/MusicMood.luau | 75 | client/audio/music_mood.gd | todo |
| src/client/Audio/Playlist.luau | 90 | client/audio/playlist.gd | todo |
