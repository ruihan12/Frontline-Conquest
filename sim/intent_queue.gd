extends RefCounted
## FIFO of detached local commands. A reset drops any commands from the old round.

var _pending: Array[Dictionary] = []
var _mutex := Mutex.new()

func submit(intent: Dictionary) -> void:
	var command := {}
	for key in intent:
		if not (key is String or key is StringName):
			continue
		var value: Variant = intent[key]
		if key == "attack" and intent.get("type") == "retreat" and value is Dictionary:
			command["attack_id"] = int(value.get("aid", -1))
		elif typeof(value) in [TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME]:
			command[key] = value
	_mutex.lock()
	_pending.append(command)
	_mutex.unlock()

func take() -> Array[Dictionary]:
	_mutex.lock()
	var commands := _pending
	_pending = []
	_mutex.unlock()
	return commands
