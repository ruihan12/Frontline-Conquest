#!/bin/sh
# Builds the Luau runtime (fernforestgames/luau-gdextension) for the three targets the game ships:
#   web (wasm32 side module, pthreads)  -> luau/ext/libgdluau.wasm
#   Linux x86_64 (headless tests, x86 servers) -> server_build/x86_64/libgdluau.linux.x86_64.so
#   Linux aarch64 (the Oracle VM server)       -> server_build/aarch64/libgdluau.linux.arm64.so
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
PIC="-DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_CXX_FLAGS=-fPIC -DCMAKE_C_FLAGS=-fPIC"
# Linux: link glibc_compat.o so the library needs no glibc above 2.28 (what Godot 4.5.1 itself needs).
glibc_check() {
  v=$($1 -T "$2" | grep -oE 'GLIBC_[0-9.]+' | sort -Vu | tail -1)
  echo "$2: highest glibc symbol version $v"
  case $v in GLIBC_2.[0-9]|GLIBC_2.1[0-9]|GLIBC_2.2[0-8]) ;; *) echo "needs glibc above 2.28"; exit 1 ;; esac
}
for t in $TARGETS; do
  case $t in
  x86_64)
    gcc -O2 -fPIC -c "$REPO/tools/luau_ext/glibc_compat.c" -o "$SRC/compat_x86_64.o"
    cmake -S "$SRC" -B "$SRC/build-linux" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF $PIC \
      -DCMAKE_MODULE_LINKER_FLAGS="$SRC/compat_x86_64.o"
    cmake --build "$SRC/build-linux" --target gdluau
    glibc_check objdump "$SRC/build-linux/libgdluau.linux.x86_64."
    cp "$SRC/build-linux/libgdluau.linux.x86_64." "$REPO/server_build/x86_64/libgdluau.linux.x86_64.so" ;;
  aarch64)
    aarch64-linux-gnu-gcc -O2 -fPIC -c "$REPO/tools/luau_ext/glibc_compat.c" -o "$SRC/compat_aarch64.o"
    cmake -S "$SRC" -B "$SRC/build-aarch64" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF $PIC \
      -DCMAKE_TOOLCHAIN_FILE="$REPO/tools/luau_ext/aarch64-linux-gnu.cmake" -DCMAKE_MODULE_LINKER_FLAGS="$SRC/compat_aarch64.o"
    cmake --build "$SRC/build-aarch64" --target gdluau
    glibc_check aarch64-linux-gnu-objdump "$SRC/build-aarch64/libgdluau.linux.aarch64."
    cp "$SRC/build-aarch64/libgdluau.linux.aarch64." "$REPO/server_build/aarch64/libgdluau.linux.arm64.so" ;;
  web)
    # -fvisibility=hidden: otherwise the side module imports its own weak symbols ("resolved is not a function").
    # -sSUPPORT_LONGJMP=wasm: otherwise it needs invoke_* imports the main module does not export.
    W="-pthread -fPIC -sSIDE_MODULE=1 -fvisibility=hidden -sSUPPORT_LONGJMP=wasm"
    emcmake cmake -S "$SRC" -B "$SRC/build-web" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
      -DGODOTCPP_THREADS=ON -DCMAKE_CXX_FLAGS="$W -fvisibility-inlines-hidden" -DCMAKE_C_FLAGS="$W" \
      -DCMAKE_MODULE_LINKER_FLAGS="-sSIDE_MODULE=1 -pthread -sSUPPORT_LONGJMP=wasm"
    cmake --build "$SRC/build-web" --target gdluau
    cp "$SRC/build-web/libgdluau.emscripten.x86." "$REPO/luau/ext/libgdluau.wasm" ;;
  *) echo "unknown target $t"; exit 1 ;;
  esac
done
