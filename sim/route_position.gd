extends RefCounted

static func sample(bt: Dictionary) -> Array:
	var cum: PackedFloat32Array = bt.cum
	var pts: PackedVector2Array = bt.pts
	var d: float = bt.d
	var m := 1
	while m < cum.size() - 1 and cum[m] < d: m += 1
	var seg := maxf(0.001, cum[m] - cum[m - 1])
	var p := pts[m - 1].lerp(pts[m], clampf((d - cum[m - 1]) / seg, 0, 1))
	return [p, (pts[m] - pts[m - 1]).normalized(), m]
