# Port of upstream src/server/Party.luau (the rules only): who is in a party, who leads, the invites.
# Members are plain ids (int) with a display name; `now` is seconds. Nothing here touches the network:
# a service (or the local preview model) owns one Party and pushes state(id) to each member.
class_name Party
extends RefCounted

## Players in a party at most (upstream: 8 since 2026-11-01).
const MAX_SIZE := 8
## An invite waits this long for an answer.
const INVITE_TTL_S := 60.0
## A player invites the same player again only this long after.
const INVITE_GAP_S := 3.0

signal changed(ids: Array)

var names := {}                # id -> display name (everyone known to the party service)
var _groups := {}              # key -> {key, leader, members: Array}
var _of := {}                  # id -> key
var _invites := {}             # target id -> {from id -> sent at}
var _seq := 0
var _clock := Callable()


func _init(clock: Callable = Callable()) -> void:
	_clock = clock


func now() -> float:
	return _clock.call() if _clock.is_valid() else Time.get_ticks_msec() / 1000.0


func name_of(id: int) -> String:
	return str(names.get(id, "Player"))


func key_of(id: int) -> String:
	return str(_of.get(id, ""))


func members(id: int) -> Array:
	var g: Dictionary = _groups.get(key_of(id), {})
	return (g.members as Array).duplicate() if not g.is_empty() else [id]


func is_leader(id: int) -> bool:
	var g: Dictionary = _groups.get(key_of(id), {})
	return g.is_empty() or g.leader == id


## What `id` sees: {members: [{uid, name, leader}], leader (am I), invites: [{uid, name}], max}.
func state(id: int) -> Dictionary:
	var out_members: Array = []
	var g: Dictionary = _groups.get(key_of(id), {})
	if not g.is_empty() and g.members.size() > 1:
		for m: int in g.members:
			out_members.append({"uid": m, "name": name_of(m), "leader": m == g.leader})
	var out_invites: Array = []
	var t := now()
	var box: Dictionary = _invites.get(id, {})
	for from: int in box:
		if t - float(box[from]) <= INVITE_TTL_S and names.has(from):
			out_invites.append({"uid": from, "name": name_of(from)})
	out_invites.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.uid < b.uid)
	return {"members": out_members, "leader": g.is_empty() or g.leader == id, "invites": out_invites, "max": MAX_SIZE}


## `from` invites `target`. Returns {ok, reason}.
func invite(from: int, target: int) -> Dictionary:
	if target == from or not names.has(target):
		return {"ok": false, "reason": "Pick someone to invite."}
	var key := key_of(from)
	if key != "" and key_of(target) == key:
		return {"ok": false, "reason": name_of(target) + " is already in your party."}
	var g: Dictionary = _groups.get(key, {})
	if not g.is_empty() and g.members.size() >= MAX_SIZE:
		return {"ok": false, "reason": "A party holds %d players." % MAX_SIZE}
	var t := now()
	if not _invites.has(target):
		_invites[target] = {}
	var box: Dictionary = _invites[target]
	if box.has(from) and t - float(box[from]) < INVITE_GAP_S:
		return {"ok": false, "reason": ""}
	box[from] = t
	changed.emit([target])
	return {"ok": true, "reason": ""}


## `target` accepts `from`'s invite: they join `from`'s party (made if `from` had none) and leave their own.
func accept(target: int, from: int) -> Dictionary:
	var box: Dictionary = _invites.get(target, {})
	if not box.has(from) or now() - float(box[from]) > INVITE_TTL_S or not names.has(from):
		return {"ok": false, "reason": "That invite has expired."}
	box.erase(from)
	var key := key_of(from)
	var g: Dictionary = _groups.get(key, {})
	if not g.is_empty() and g.members.size() >= MAX_SIZE:
		changed.emit([target])
		return {"ok": false, "reason": "That party is full."}
	if _of.has(target):
		leave(target)
	if g.is_empty():
		_seq += 1
		key = "%d:%d" % [from, _seq]
		g = {"key": key, "leader": from, "members": [from]}
		_groups[key] = g
		_of[from] = key
	g.members.append(target)
	_of[target] = key
	changed.emit(g.members.duplicate())
	return {"ok": true, "reason": ""}


func decline(target: int, from: int) -> void:
	(_invites.get(target, {}) as Dictionary).erase(from)
	changed.emit([target])


## `id` leaves (the next member leads when the leader leaves; one left alone is no party).
func leave(id: int) -> void:
	var key := key_of(id)
	var g: Dictionary = _groups.get(key, {})
	_of.erase(id)
	if g.is_empty():
		changed.emit([id])
		return
	g.members.erase(id)
	var touched: Array = [id]
	if g.leader == id and not g.members.is_empty():
		g.leader = g.members[0]
	if g.members.size() <= 1:
		for m: int in g.members:
			_of.erase(m)
		_groups.erase(key)
	touched.append_array(g.members)
	changed.emit(touched)


func kick(leader: int, member: int) -> void:
	var g: Dictionary = _groups.get(key_of(leader), {})
	if g.is_empty() or g.leader != leader or member == leader or not g.members.has(member):
		return
	leave(member)


## `id` left the server: out of the party, invites to and from them gone.
func removed(id: int) -> void:
	leave(id)
	_invites.erase(id)
	var touched: Array = []
	for target: int in _invites:
		if (_invites[target] as Dictionary).erase(id):
			touched.append(target)
	names.erase(id)
	if not touched.is_empty():
		changed.emit(touched)
