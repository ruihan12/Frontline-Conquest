# Port of src/client/Map/FrameClock.luau.
# The client's frame time: the real one, except while a film steps time itself, a frame at a time,
# so a capture of each frame plays back smoothly. (Upstream: Dev/Film in Studio. Here: the game's
# screenshot runs can set `film`.)
class_name FrameClock
extends RefCounted

## While filming: {"t": seconds, "dt": this frame's seconds}; empty otherwise.
static var film := {}


static func now() -> float:
	return float(film.t) if not film.is_empty() else Time.get_ticks_usec() / 1000000.0


static func dt(real: float) -> float:
	return float(film.dt) if not film.is_empty() else real
