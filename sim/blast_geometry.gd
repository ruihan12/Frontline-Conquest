extends RefCounted
## Worker-owned rows of a circular footprint, ordered top to bottom.
## Each row gives its y offset and inclusive horizontal extent.

var rows := PackedInt32Array()

func prepare(radius: float) -> void:
	var radius_sq := radius * radius
	var bound := ceili(radius)
	for dy in range(-bound, bound + 1):
		var remaining := radius_sq - float(dy * dy)
		if remaining < 0.0:
			continue
		var dx := floori(sqrt(remaining))
		# Correct at integer boundaries using the same comparison as the tile scan.
		if (dx + 1) * (dx + 1) + dy * dy <= radius_sq:
			dx += 1
		elif dx * dx + dy * dy > radius_sq:
			dx -= 1
		rows.append(dy)
		rows.append(dx)

func land_tiles(center: int, width: int, height: int, owners: PackedInt32Array) -> PackedInt32Array:
	var cx := center % width
	@warning_ignore("integer_division")
	var cy := center / width
	var result := PackedInt32Array()
	for i in range(0, rows.size(), 2):
		var y := cy + rows[i]
		if y < 0 or y >= height:
			continue
		var span := rows[i + 1]
		for x in range(maxi(0, cx - span), mini(width, cx + span + 1)):
			var tile := y * width + x
			if owners[tile] >= 0:
				result.append(tile)
	return result
