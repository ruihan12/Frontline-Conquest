#!/bin/sh
# Builds the Luau runtime (fernforestgames/luau-gdextension) for the three targets the game ships:
#   web (wasm32 side module, pthreads)  -> luau/ext/libgdluau.wasm, luau/ext/libgdluau.release.wasm
#   Linux x86_64 (headless tests, x86 servers) -> server_build/x86_64/libgdluau.linux[.release].x86_64.so
#   Linux aarch64 (the Oracle VM server)       -> server_build/aarch64/libgdluau.linux[.release].arm64.so
# Each target is built twice: godot-cpp template_debug (for the editor binary and debug exports; the files without
# ".release") and template_release (for release exports). A template_debug library must not run in a release
# engine: godot-cpp's debug allocator expects the engine to pad allocations, which a release engine does not, and
# the first mismatched free aborts ("free(): invalid pointer" on Linux, "Aborted(native code called abort())" on the
# web). luau/ext/gdluau.gdextension picks the right one by the debug / release feature tag.
# Needs: git, cmake >= 3.28, ninja, g++, g++-aarch64-linux-gnu, emsdk 4.0.11 (the version Godot 4.5.1's web
# templates were built with) activated in this shell for the web target.
# Usage: tools/luau_ext/build.sh <checkout dir> [web|x86_64|aarch64 ...]   (default: all three)
set -e
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${1:?checkout dir}"; shift
TARGETS="${*:-web x86_64 aarch64}"
REV=bc1b88da7121a6b049094a5eebc7e5b359bc8ac3   # luau-gdextension main, 2026-05-28 (luau 0.719, godot-cpp godot-4.5-stable)
[ -d "$SRC/.git" ] || git clone https://github.com/fernforestgames/luau-gdextension "$SRC"
git -C "$SRC" checkout -q "$REV"
# This revision still binds LuaState.to_string, which it no longer defines, so the bind lands on Object and fails
# ("Class 'Object' doesn't exist" at load). The game never calls it; drop the stale bind.
sed -i '/D_METHOD("to_string", "index")/d' "$SRC/src/lua_state.cpp"
PIC="-DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_CXX_FLAGS=-fPIC -DCMAKE_C_FLAGS=-fPIC"
# Linux: link glibc_compat.o so the library needs no glibc above 2.28 (what Godot 4.5.1 itself needs).
glibc_check() {
  v=$($1 -T "$2" | grep -oE 'GLIBC_[0-9.]+' | sort -Vu | tail -1)
  echo "$2: highest glibc symbol version $v"
  case $v in GLIBC_2.[0-9]|GLIBC_2.1[0-9]|GLIBC_2.2[0-8]) ;; *) echo "needs glibc above 2.28"; exit 1 ;; esac
}
for v in debug release; do
GT="-DGODOTCPP_TARGET=template_$v"
if [ $v = debug ]; then B=""; SUF=""; else B="-rel"; SUF=".release"; fi
for t in $TARGETS; do
  case $t in
  x86_64)
    gcc -O2 -fPIC -c "$REPO/tools/luau_ext/glibc_compat.c" -o "$SRC/compat_x86_64.o"
    cmake -S "$SRC" -B "$SRC/build-linux$B" -G Ninja -DCMAKE_BUILD_TYPE=Release $GT -DBUILD_TESTING=OFF $PIC \
      -DCMAKE_MODULE_LINKER_FLAGS="$SRC/compat_x86_64.o"
    cmake --build "$SRC/build-linux$B" --target gdluau
    glibc_check objdump "$SRC/build-linux$B/libgdluau.linux.x86_64."
    cp "$SRC/build-linux$B/libgdluau.linux.x86_64." "$REPO/server_build/x86_64/libgdluau.linux$SUF.x86_64.so" ;;
  aarch64)
    aarch64-linux-gnu-gcc -O2 -fPIC -c "$REPO/tools/luau_ext/glibc_compat.c" -o "$SRC/compat_aarch64.o"
    cmake -S "$SRC" -B "$SRC/build-aarch64$B" -G Ninja -DCMAKE_BUILD_TYPE=Release $GT -DBUILD_TESTING=OFF $PIC \
      -DCMAKE_TOOLCHAIN_FILE="$REPO/tools/luau_ext/aarch64-linux-gnu.cmake" -DCMAKE_MODULE_LINKER_FLAGS="$SRC/compat_aarch64.o"
    cmake --build "$SRC/build-aarch64$B" --target gdluau
    glibc_check aarch64-linux-gnu-objdump "$SRC/build-aarch64$B/libgdluau.linux.aarch64."
    cp "$SRC/build-aarch64$B/libgdluau.linux.aarch64." "$REPO/server_build/aarch64/libgdluau.linux$SUF.arm64.so" ;;
  web)
    # -fvisibility=hidden: otherwise the side module imports its own weak symbols ("resolved is not a function").
    # -sSUPPORT_LONGJMP=wasm: otherwise it needs invoke_* imports the main module does not export.
    W="-pthread -fPIC -sSIDE_MODULE=1 -fvisibility=hidden -sSUPPORT_LONGJMP=wasm"
    emcmake cmake -S "$SRC" -B "$SRC/build-web$B" -G Ninja -DCMAKE_BUILD_TYPE=Release $GT -DBUILD_TESTING=OFF \
      -DGODOTCPP_THREADS=ON -DCMAKE_CXX_FLAGS="$W -fvisibility-inlines-hidden" -DCMAKE_C_FLAGS="$W" \
      -DCMAKE_MODULE_LINKER_FLAGS="-sSIDE_MODULE=1 -pthread -sSUPPORT_LONGJMP=wasm"
    cmake --build "$SRC/build-web$B" --target gdluau
    cp "$SRC/build-web$B/libgdluau.emscripten.x86." "$REPO/luau/ext/libgdluau$SUF.wasm" ;;
  *) echo "unknown target $t"; exit 1 ;;
  esac
done
done
