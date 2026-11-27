extends RefCounted
## Clones dictionary records and preserves their identity links across a worker job.

var originals: Array[Dictionary] = []
var copies: Array[Dictionary] = []

func copy(value: Variant) -> Variant:
	if value is Dictionary:
		for i in originals.size():
			if is_same(originals[i], value): return copies[i]
		var detached := {}
		originals.append(value)
		copies.append(detached)
		for key in value:
			detached[key] = copy(value[key])
		return detached
	if value is Array:
		return value.map(copy)
	if typeof(value) >= TYPE_PACKED_BYTE_ARRAY:
		return value.duplicate()
	return value

func copy_fields(fields: Dictionary) -> Dictionary:
	var detached := {}
	for key in fields:
		detached[key] = copy(fields[key])
	return detached

func rebind(value: Variant) -> Variant:
	if value is Dictionary:
		for i in copies.size():
			if is_same(copies[i], value): return originals[i]
		return rebind_fields(value)
	if value is Array:
		return value.map(rebind)
	return value

func rebind_fields(fields: Dictionary) -> Dictionary:
	var rebound := {}
	for key in fields:
		rebound[key] = rebind(fields[key])
	return rebound

func same_records(other) -> bool:
	if originals.size() != other.originals.size(): return false
	for i in originals.size():
		if not is_same(originals[i], other.originals[i]): return false
	return true
