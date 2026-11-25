# What the title screen's party panel talks to. This base is the local preview: a Party with a few
# stand-in players on "this server" (nothing leaves the PC). A network model overrides the four
# hooks (_send_action, online_players, local_id, state) and emits `changed`.
class_name PartyModel
extends RefCounted

const PartyCore := preload("res://net/party.gd")

signal changed

var party: PartyCore
var me := 1
var enabled := true
var _fake := [[2, "Ava"], [3, "Bruno"], [4, "Chen"], [5, "Dara"], [6, "Eli"], [7, "Fay"], [8, "Gus"], [9, "Hana"], [10, "Ivo"]]


func _init(my_name: String = "You") -> void:
	party = PartyCore.new()
	party.names[me] = my_name
	for p: Array in _fake:
		party.names[p[0]] = p[1]
	party.changed.connect(func(ids: Array) -> void:
		if ids.has(me):
			changed.emit())


func state() -> Dictionary:
	return party.state(me)


## Share code of this player ("" = no codes: the local preview).
func code() -> String:
	return ""


## False while the party hub can't be reached.
func is_online() -> bool:
	return true


func join_code(_c: String) -> void:
	pass


func local_id() -> int:
	return me


## Players that could be invited (not already in the party), sorted by name.
func online_players() -> Array:
	var inside := {}
	for m: Dictionary in state().members:
		inside[m.uid] = true
	var out: Array = []
	for id: int in party.names:
		if id != me and not inside.has(id):
			out.append({"uid": id, "name": party.name_of(id)})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.name.to_lower() < b.name.to_lower())
	return out


## Panel buttons: invite / accept / decline / kick / leave. Returns the reason text on a refusal, else "".
func act(action: String, uid: int = 0) -> String:
	var r := {"ok": true, "reason": ""}
	match action:
		"invite": r = party.invite(me, uid)
		"accept": r = party.accept(me, uid)
		"decline": party.decline(me, uid)
		"kick": party.kick(me, uid)
		"leave": party.leave(me)
	if action == "invite" and r.ok:
		_preview_reply(uid)
	return str(r.reason)


## Preview only: a stand-in player accepts an invite a moment later.
func _preview_reply(uid: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	await tree.create_timer(1.2).timeout
	party.accept(uid, me)


## Preview / tests: a stand-in player invites you.
func preview_invite_from(uid: int) -> void:
	party.invite(uid, me)
