# The audio surface UICtx.sfx plays through (upstream: Audio/AudioDirector as the UI uses it), over
# the game's audio director (audio_upstream/audio_director.gd). Sounds the UI asks for are the local
# player's own actions, so the director's "your events only" gate lets them through.
class_name RWAudio
extends RefCounted

var g  # main.gd


func _init(main) -> void:
	g = main


func has_sfx(sfx_name: String) -> bool:
	return g.audio_dir != null and g.audio_dir.has_sfx(sfx_name)


func play_sfx(sfx_name: String, volume_db: float = 0.0, pitch_jitter: float = 0.04, pitch: float = -1.0) -> void:
	if g.audio_dir == null:
		return
	g.audio_dir.play_sfx(sfx_name, volume_db, pitch_jitter, pitch, g.PLAYER, true, sfx_name.begins_with("ui_"))


func is_music_enabled() -> bool:
	return bool(g.music_on_setting())


func set_music_enabled(on: bool) -> void:
	if on != is_music_enabled():
		g.hud_toggle_music()


## The player's music level, 0..1 (the port's saved vol_music).
func music_volume() -> float:
	return float(g.save.get("settings", {}).get("vol_music", 0.5))


func set_music_volume(v: float, save: bool = false) -> void:
	if not g.save.has("settings"):
		g.save["settings"] = {}
	g.save.settings["vol_music"] = clampf(v, 0.0, 1.0)
	g._apply_volumes()
	if save:
		g.write_save()


func is_pops_enabled() -> bool:
	return g.audio_dir != null and g.audio_dir.is_pops_enabled()


func set_pops_enabled(on: bool) -> void:
	if g.audio_dir != null:
		g.audio_dir.set_pops_enabled(on)
