#!/bin/sh
# Web export plus the lazy files the pack leaves out (music tracks and the OpenFront maps' terrain).
# Usage: tools/build_web.sh <out dir>   (the Web preset excludes them from the pack; index.html loads them on demand)
set -e
OUT="${1:?out dir}"
mkdir -p "$OUT/lazy/music" "$OUT/lazy/maps"
godot --headless --path "$(dirname "$0")/.." --export-release "Web" "$OUT/index.html"
cp "$(dirname "$0")"/../sounds/upstream/music/*.ogg "$OUT/lazy/music/"
cp "$(dirname "$0")"/../maps/upstream/of_*.codes.bin "$(dirname "$0")"/../maps/upstream/of_*.tiles.bin "$OUT/lazy/maps/"
cp "$(dirname "$0")"/../release/serve.py "$(dirname "$0")"/../release/serve.bat "$OUT/"
du -sh "$OUT/index.pck" "$OUT/lazy"
