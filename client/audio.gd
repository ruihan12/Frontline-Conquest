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
