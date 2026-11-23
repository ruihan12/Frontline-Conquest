# Luau attack-kernel prototype (2026-11-23)

Feasibility test for running the attack pass in Luau (fernforestgames/luau-gdextension) in a Godot web export.
Not wired into the game. `main.gd` runs the same condensed kernel (heap queue, neighbour pushes, loss/time maths,
owner + border upkeep; 2000x1000, 760 attacks, 2 tiles/attack/tick, 200 ticks) in GDScript and in `kernel.luau`.

Result (Godot 4.5 web debug export, headless Chromium, software GL, same machine):
- identical checksum `[784620642503, 112503]` in both
- GDScript 31.3 ms/tick (worst 50 ms); Luau 10.3 ms/tick (worst 26 ms) -> ~3.0x
- `buffer.readi32/writei32` loops are NOT faster than GDScript in wasm (call overhead); plain tables are.
- No Luau native codegen on web (interpreter only).

Build recipe for the extension (not in upstream repo, which has no web target):
1. emsdk 4.0.x, Godot 4.5 editor + `web_dlink_*` export templates, export preset with extensions_support + thread_support.
2. `emcmake cmake -S . -B build -DGODOTCPP_THREADS=ON -DBUILD_TESTING=OFF \
   -DCMAKE_CXX_FLAGS="-pthread -fPIC -sSIDE_MODULE=1 -fvisibility=hidden -fvisibility-inlines-hidden -sSUPPORT_LONGJMP=wasm" \
   -DCMAKE_C_FLAGS="-pthread -fPIC -sSIDE_MODULE=1 -fvisibility=hidden -sSUPPORT_LONGJMP=wasm" \
   -DCMAKE_MODULE_LINKER_FLAGS="-sSIDE_MODULE=1 -pthread -sSUPPORT_LONGJMP=wasm"`; `cmake --build build --target gdluau`
   (the output `libgdluau.emscripten.x86.` is the wasm side module; copy to `bin/libgdluau.wasm`).
   Without -fvisibility=hidden the module imports its own weak symbols and dies with "resolved is not a function";
   without wasm longjmp it needs `invoke_vii`.
3. `luau.gdextension`: `web.release.wasm32` / `web.debug.wasm32` entries. Export with `include_filter="*.luau"`.
4. Known: logs "Class 'Object' doesn't exist" at load (harmless so far); Luau C++ exception paths (`__cxa_throw`) are unresolved imports.

Not done: integration. owner_map/border/nations live in GDScript; a real port needs the hot state owned by Luau.
