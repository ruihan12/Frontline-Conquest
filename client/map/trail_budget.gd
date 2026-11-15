# Port of src/client/Map/TrailBudget.luau.
# How much of the munitions in flight the unit layer draws: every trail dot and every target ring
# costs something to draw, so their number has a ceiling whatever the sim has in the air.
#
# A munition's trail is a dot every TRAIL_STEP along the arc it has flown, MAX at most. All the
# munitions in flight share BUDGET dots a redraw: with more of them than the budget feeds whole
# trails, each keeps only its newest dots (the tail behind it), down to none. MIRV warheads lose
# their target rings while many fly.
class_name TrailBudget
extends RefCounted

## The most dots one trail has.
const MAX := 160
## Dots a redraw draws for all the trails together.
const BUDGET := 800
## A MIRV warhead's target ring is drawn while no more than this many munitions are in flight.
const RING_MAX := 24


## With `flying` trailed munitions in the air: [the dots each one keeps (MAX: its whole trail;
## 0: none), whether MIRV warheads get their target rings].
static func allowance(flying: int) -> Array:
	@warning_ignore("integer_division")
	return [mini(MAX, BUDGET / maxi(flying, 1)), flying <= RING_MAX]
