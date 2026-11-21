# Web input smoke test (headless Chrome)

Plays the real solo flow in the exported web build with CDP mouse/key events: leaves the
first-run tutorial, PLAY SOLO -> START on World, clicks an unclaimed tile to spawn, waits for the
deploy timer, clicks unclaimed land (adjacent, or `TARGET=far` = same-continent wilderness 15+
tiles from the border) and checks that a land attack starts, territory grows and no boat is sent.
`BUILD=1` then presses 1 and clicks our own land to build a City.

The game exposes its state to the page only through a test probe that is NOT in the shipped
build. Apply it to a scratch copy before exporting:

    git apply tools/web_input_test/probe.patch        # adds main._fctest_tick (needs ?fctest)
    godot --headless --path . --export-release Web /tmp/fc_web/index.html
    git checkout -- main.gd
    PORT=8072 ROOT=/tmp/fc_web python3 tools/web_input_test/serve.py &
    UDIR=/tmp/fc_prof PRE=tools/web_input_test/pre_menu.txt TARGET=far BUILD=1 \
      node tools/web_input_test/clicktest.mjs "http://127.0.0.1:8072/?fctest&fcgold"

`?fcgold` tops the player's gold up to 1e9 so the City is affordable. Use a fresh `UDIR` each run
(the first-run tutorial is what `pre_menu.txt` leaves). Prints `RESULT ATTACK_OK|ATTACK_FAIL` and
`BUILD BUILD_OK|BUILD_FAIL`. Coordinates in pre_menu.txt assume a 1600x900 window.
