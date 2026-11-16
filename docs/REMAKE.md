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

Progress: 35734 of 52913 upstream lines accounted for (69 of 86 files; 11524 of those lines are files with no counterpart here: the Widgets kit, Roblox store / account / platform screens). Live in the game: the whole in-match HUD (top bar, command bar, status pill, spawn banner, leaderboard, attacks panel, event feed, nuke alert, hint cards, game menu, game over). The old HUD (ui_upstream/rw_hud.gd) still draws only the port's own speed chip. The map hover card is ported too. The right-click action ring is ported too. The title screen, the PLAY SOLO panel and the map picker are ported and live (the old menu and play dialog are removed). Left clicks on the map run through the ported UIInteract.on_click. Placement clicks (with the two-click nuke lock) run through it too; the build itself stays the game's try_build. The Arsenal window, the tutorial and the coach tips are ported and live. Not yet ported: map layers, the Arsenal window, tutorial and coach marks. The help window is ported.

Order: UITheme, GlassPanel -> UICtx, UIRules, widgets (CountLabel, RatioSlider, ShopSlot...) -> HUD (TopStatus,
Leaderboard, CommandBar, EventFeed, AttackPanel) -> map layers (MapSurface, StructureLayer, UnitLayer, FxLayer,
RangeLayer, RoadLayer, NameLayer, FrontLayer) -> screens (TitleScreen, PauseMenu, GameOver, Arsenal...) -> UIRoot, Main.

| Upstream file | Lines | Godot file | Status |
|---|---:|---|---|
| src/client/Main.luau | 645 | client/main.gd | part: top bar (client/topbar.gd, lines 105-420); boot and key binds to do |
| src/client/Session.luau | 1775 | client/session.gd | todo |
| src/client/init.client.luau | 19 | - | not applicable: Roblox script entry |
| src/client/UI/AlertBanner.luau | 260 | client/ui/alert_banner.gd | done, live |
| src/client/UI/Arsenal.luau | 1368 | client/ui/arsenal.gd | done, live (replaces the old shop window; Stars only, no purchases; this port's prices) |
| src/client/UI/ArsenalButton.luau | 304 | client/ui/arsenal_button.gd | done, live (title screen, opens the Arsenal window) |
| src/client/UI/ArsenalDemo.luau | 1462 | - | not ported: the Arsenal preview shows the item's render instead of the animated demo |
| src/client/UI/AttacksPanel.luau | 462 | client/ui/attacks_panel.gd | done, live |
| src/client/UI/Banner.luau | 188 | client/ui/banner.gd | done, live (THE WAR BEGINS) |
| src/client/UI/BorderTracker.luau | 327 | client/borders.gd | replaced: its surface answered by the game (no tracked border set) |
| src/client/UI/BuildButton.luau | 486 | client/ui/build_button.gd | done, live |
| src/client/UI/BusyChip.luau | 118 | client/ui/busy_chip.gd | done, live (shown while a match is built, with progress) |
| src/client/UI/ChestView.luau | 117 | - | not applicable: crate store (Robux) |
| src/client/UI/Coach.luau | 477 | client/ui/coach.gd | done, live (first-match tips; "Show tips again" resets them) |
| src/client/UI/CommandBar.luau | 965 | client/ui/command_bar.gd | done, live (+ port-only ICBM slot) |
| src/client/UI/CountLabel.luau | 68 | client/ui/count_label.gd | done |
| src/client/UI/CrateButton.luau | 381 | - | not applicable: crate store (Robux) |
| src/client/UI/CrateOpening.luau | 1520 | - | not applicable: crate store (Robux) |
| src/client/UI/EventFeed.luau | 616 | client/ui/event_feed.gd | done, live (toasts, alliance cards) |
| src/client/UI/FillBar.luau | 208 | client/ui/fill_bar.gd | done |
| src/client/UI/FlagShop.luau | 867 | - | not applicable: flag shop (Robux) |
| src/client/UI/FloatText.luau | 90 | client/ui/float_text.gd | done, live |
| src/client/UI/GameOver.luau | 1174 | client/ui/game_over.gd | done, live (paid take-over card left out) |
| src/client/UI/GeneralButton.luau | 354 | - | not applicable: paid offer |
| src/client/UI/GeneralOffer.luau | 444 | - | not applicable: paid offer |
| src/client/UI/GlassPanel.luau | 216 | client/ui/glass_panel.gd | ported |
| src/client/UI/GlobeNotice.luau | 251 | - | not applicable: Roblox EditableImage permission notice |
| src/client/UI/HelpOverlay.luau | 712 | client/ui/help_overlay.gd | done, live (key list and credits are this port's) |
| src/client/UI/HoldRing.luau | 71 | client/ui/hold_ring.gd | done (touch long-press ring; driven by MapInput, not ported yet) |
| src/client/UI/Leaderboard.luau | 663 | client/ui/leaderboard.gd | done, live (head shots / cosmetic flags left out) |
| src/client/UI/Locker.luau | 964 | - | not applicable: cosmetics locker (accounts) |
| src/client/UI/MapPicker.luau | 340 | client/ui/map_picker.gd | done, live (tabs are the port's three map tables; REROLL chip on Random) |
| src/client/UI/NextMatch.luau | 161 | - | not applicable: multiplayer lobby |
| src/client/UI/PartyPanel.luau | 471 | - | not applicable: Roblox parties |
| src/client/UI/PauseMenu.luau | 853 | client/ui/pause_menu.gd | done, live (Settings row opens the port's own Settings window) |
| src/client/UI/PlaceConfirm.luau | 221 | client/ui/place_confirm.gd | done, wired (touch placement; dormant with a mouse) |
| src/client/UI/Prices.luau | 117 | - | not applicable: Robux prices |
| src/client/UI/RadialMenu.luau | 756 | client/ui/radial_menu.gd | done, live (segments drawn as vectors, not masks) |
| src/client/UI/RatioSlider.luau | 254 | client/ui/ratio_slider.gd | done, live |
| src/client/UI/RotateCard.luau | 65 | - | not applicable: phone rotate prompt |
| src/client/UI/ShopButton.luau | 268 | - | not applicable: flag shop (Robux) |
| src/client/UI/ShopLayout.luau | 59 | - | not applicable: flag shop (Robux) |
| src/client/UI/ShopSlot.luau | 356 | client/ui/shop_slot.gd | done, live |
| src/client/UI/SpawnOverlay.luau | 320 | client/ui/spawn_overlay.gd | done, live (head shots left out) |
| src/client/UI/StarterButton.luau | 340 | - | not applicable: paid starter pack |
| src/client/UI/StarterOffer.luau | 776 | - | not applicable: paid starter pack |
| src/client/UI/Takeover.luau | 285 | - | not applicable: paid take-over |
| src/client/UI/TargetCard.luau | 445 | client/ui/target_card.gd | done, live (opens when "select before attacking" is on) |
| src/client/UI/Telemetry.luau | 533 | - | not applicable: analytics |
| src/client/UI/TitleScreen.luau | 1703 | client/ui/title_screen.gd | done, live (solo parts; public matches, queue, party and store buttons not applicable; port's BOT PLAYERS row) |
| src/client/UI/Tooltip.luau | 314 | client/ui/tooltip.gd | done, live (slot hint cards) |
| src/client/UI/TopStatus.luau | 509 | client/ui/top_status.gd | done, live |
| src/client/UI/TouchRouter.luau | 120 | - | not applicable: multi-touch routing on Roblox |
| src/client/UI/TrayFit.luau | 63 | client/ui/tray_fit.gd | done |
| src/client/UI/Tutorial.luau | 652 | client/ui/tutorial.gd | done, live (starts by itself for a new save; includes Data/Tutorial's steps) |
| src/client/UI/UIAdvisor.luau | 917 | client/ui/ui_advisor.gd | done for this port: threats, tips, rookie floor, war_begins. Its event handlers are not needed (the game writes those feed lines itself) |
| src/client/UI/UICtx.luau | 1490 | client/ui/ui_ctx.gd | done (Roblox-only drawing / module helpers left out) |
| src/client/UI/UIInteract.luau | 1745 | client/ui/ui_interact.gd | done except touch input (connect_input, _set_touch: with MapInput) |
| src/client/UI/UIKern.luau | 11 | - | not needed: Godot applies the font's kerning itself |
| src/client/UI/UILayoutProbe.luau | 215 | - | not applicable: Roblox safe-area / top-bar probing |
| src/client/UI/UIMaps.luau | 102 | client/ui/ui_maps.gd | done, live |
| src/client/UI/UIRoot.luau | 2636 | client/ui/ui_root.gd | todo |
| src/client/UI/UIRules.luau | 1383 | client/ui/ui_rules.gd | done (placement and sea reach ask the game; + port-only gold donation item) |
| src/client/UI/UITheme.luau | 1955 | client/ui/ui_theme.gd | ported (glyph metric tables dropped: Godot measures text natively) |
| src/client/UI/UnitCard.luau | 305 | client/ui/unit_card.gd | done, live (warship selection and move orders) |
| src/client/UI/Widgets.luau | 3151 | (native Godot Controls) | not needed: upstream emulates Godot Control / Container / Label / Button / Tween on Roblox; animation helpers ported as client/ui/ui_fx.gd |
| src/client/Map/AtlasReady.luau | 46 | - | not applicable: Roblox asset preloading |
| src/client/Map/FalloutGlow.luau | 713 | client/map/fallout_glow.gd | todo |
| src/client/Map/FrameClock.luau | 21 | client/map/frame_clock.gd | done (library) |
| src/client/Map/FrontLayer.luau | 411 | client/map/front_layer.gd | todo |
| src/client/Map/FxLayer.luau | 1015 | client/map/fx_layer.gd | todo |
| src/client/Map/MapCamera.luau | 554 | client/map/map_camera.gd | done, live (drives the game's Camera2D: eased zoom to the pointer, drag inertia, focus glides, title drift) |
| src/client/Map/MapInput.luau | 731 | client/map/map_input.gd | todo |
| src/client/Map/MapSurface.luau | 1517 | client/map/map_surface.gd | todo |
| src/client/Map/MapView.luau | 985 | client/map/map_view.gd | todo |
| src/client/Map/NameLayer.luau | 762 | client/map/name_layer.gd | todo |
| src/client/Map/RangeLayer.luau | 717 | client/map/range_layer.gd | todo |
| src/client/Map/RoadLayer.luau | 672 | client/map/road_layer.gd | todo |
| src/client/Map/StructureLayer.luau | 633 | client/map/structure_layer.gd | todo |
| src/client/Map/TrailBudget.luau | 34 | client/map/trail_budget.gd | done (library; the game's own unit drawing does not use it yet) |
| src/client/Map/UnitLayer.luau | 742 | client/map/unit_layer.gd | todo |
| src/client/Map/ViewRules.luau | 145 | client/map/view_rules.gd | done (library over this port's SimRules) |
| src/client/Map/WakeRoute.luau | 211 | client/map/wake_route.gd | done (library; the game's own boat curve still draws the wakes) |
| src/client/Audio/AudioDirector.luau | 1376 | audio_upstream/audio_director.gd | done earlier (one file holds AudioDirector, MusicMood, Playlist) |
| src/client/Audio/MusicMood.luau | 75 | audio_upstream/audio_director.gd | done earlier (one file holds AudioDirector, MusicMood, Playlist) |
| src/client/Audio/Playlist.luau | 90 | audio_upstream/audio_director.gd | done earlier (one file holds AudioDirector, MusicMood, Playlist) |
