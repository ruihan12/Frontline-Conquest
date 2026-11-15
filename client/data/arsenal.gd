# Port of src/shared/Data/Arsenal.luau: the Arsenal's catalogue (what Stars unlock).
# `local_id`: the item's id in this port's save (game/state.gd ARSENAL).
class_name ArsenalData
extends RefCounted

const ITEMS: Array[Dictionary] = [
	{
		"key": "mega", "local_id": "mega", "title": "Mega Nuke", "kind": "nuke", "icon": "mega",
		"tagline": "4x the blast of an Atom Bomb",
		"blurb": "A warhead with twice an Atom Bomb's radius: four times the ground, gone. Launches from your Missile Silos.",
		"perks": ["4X BLAST AREA", "2.5M GOLD A LAUNCH"],
		"plain": "A nuke that blows up 4 times the area of an Atom Bomb. Launch it from your Missile Silos.",
		"facts": ["4x blast", "Launch from silos"],
		"stars": 20000, "opens": ["mega"], "color": [0xE2483A, 0x7A1420],
	},
	{
		"key": "scatter", "local_id": "scatter", "title": "Scattershot", "kind": "nuke", "icon": "scatter",
		"tagline": "A nuke that brings 4 to 6 warheads",
		"blurb": "An Atom Bomb with 4 to 6 extra warheads that come down all around it. One SAM can't stop them all.",
		"perks": ["4-6 EXTRA WARHEADS", "BEATS A LONE SAM"],
		"plain": "One nuke that splits into 4 to 6 warheads. A single SAM can't stop them all.",
		"facts": ["4-6 warheads", "Beats SAMs"],
		"stars": 40000, "opens": ["scatter"], "color": [0xF08A24, 0x8A3A0C],
	},
	{
		"key": "reinforce", "local_id": "reinf", "title": "Reinforcements", "kind": "call", "icon": "reinforce",
		"tagline": "Troops for gold, on call",
		"blurb": "Call in a fifth of your troop cap at once for 100K gold. Ready again every 30 seconds.",
		"perks": ["+20% ARMY AT ONCE", "EVERY 30 SECONDS"],
		"plain": "Pay gold to get 20% more troops at once. Ready again every 30 seconds.",
		"facts": ["+20% troops", "Every 30 s"],
		"stars": 40000, "opens": ["reinforce"], "color": [0x35B86B, 0x0E5A34],
	},
	{
		"key": "artillery", "local_id": "art", "title": "Artillery", "kind": "structure", "icon": "artillery",
		"tagline": "Shells every enemy in range",
		"blurb": "A battery that fires on its own at every enemy within 45 tiles: their troops, and the structures it can reach.",
		"perks": ["FIRES ON ITS OWN", "+5,000 STARS"],
		"plain": "Build cannons that fire by themselves at every enemy within 45 tiles.",
		"facts": ["Fires by itself", "+5,000 free Stars"],
		"stars": 50000, "bonus": 5000, "opens": ["artillery"], "color": [0x4C8DF0, 0x1A3A8A],
	},
	{
		"key": "airfield", "local_id": "air", "title": "Air Strike", "kind": "structure", "icon": "airfield",
		"tagline": "Build Airfields that bomb 156 tiles away",
		"blurb": "Build Airfields and call air strikes: a 15-tile carpet that kills troops and wrecks structures. No SAM can stop one. Rearms in 30 seconds.",
		"perks": ["BUILD AIRFIELDS", "+5,000 STARS"],
		"plain": "Build airfields and bomb anything up to 156 tiles away. SAMs can't stop it.",
		"facts": ["156-tile range", "+5,000 free Stars"],
		"stars": 200000, "bonus": 5000, "opens": ["airfield", "airstrike"], "color": [0x2FB7C9, 0x0D5670],
	},
	{
		"key": "railgun", "local_id": "rail", "title": "Railgun", "kind": "structure", "icon": "railgun",
		"tagline": "Snipe anything, anywhere on the map",
		"blurb": "No range limit. One slug takes a level off every structure it hits and razes the small ones. Nothing intercepts it. Reloads in 25 seconds.",
		"perks": ["NO RANGE LIMIT", "CAN'T BE INTERCEPTED"],
		"plain": "Hit any building anywhere on the map. Nothing can stop the shot.",
		"facts": ["No range limit", "Unstoppable"],
		"stars": 500000, "opens": ["railgun", "slug"], "color": [0xA35BFF, 0x3D1A8A],
	},
	{
		"key": "stars2x", "local_id": "x2", "title": "2x Stars", "kind": "boost", "icon": "star",
		"tagline": "Every match pays double, forever",
		"blurb": "Doubles the Stars every match pays you, for good.",
		"perks": ["DOUBLE STARS", "EVERY MATCH"],
		"plain": "Every match pays you double Stars, forever.",
		"facts": ["2x Stars", "Every match"],
		"opens": [], "color": [0xFFC83D, 0x9A6200],
	},
	{
		"key": "reload2x", "local_id": "reload", "title": "Rapid Reload", "kind": "boost", "icon": "reload",
		"tagline": "Everything you own reloads twice as fast",
		"blurb": "Your Missile Silos, SAMs, Artillery, Airfields and Railguns all reload in half the time.",
		"perks": ["2X RELOAD SPEED", "ALL STRUCTURES"],
		"plain": "Your silos, SAMs, cannons, airfields and railguns reload twice as fast.",
		"facts": ["2x reload", "Everything you build"],
		"opens": [], "color": [0xE85BB0, 0x7A1A5A],
	},
]


static func item(key):
	if not (key is String):
		return null
	for it in ITEMS:
		if it.key == key:
			return it
	return null


## The item a build / launch kind belongs to; null for the kinds everyone has.
static func item_for(kind: String):
	for it in ITEMS:
		if kind in it.opens:
			return it
	return null


## The first item Stars buy that `owned` (key -> true) lacks.
static func next_goal(owned: Dictionary):
	for it in ITEMS:
		if it.has("stars") and not owned.get(it.key, false):
			return it
	return null


static var _renders := {}


## The item's render (assets/rw/arsenal/renders), or null. Kept: a texture nothing holds is freed
## before the frame that draws it.
static func render(key: String) -> Texture2D:
	if _renders.has(key):
		return _renders[key]
	var p := "res://assets/rw/arsenal/renders/%s.png" % key
	var t: Texture2D = load(p) if ResourceLoader.exists(p) else null
	_renders[key] = t
	return t
