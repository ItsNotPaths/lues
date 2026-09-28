#!/usr/bin/env bash
# Builds <src> into <out>/<name>/<name>.so. A non-C plugin ships an executable build.sh,
# run as `build.sh <src> <out>/<name>` with LUES_INCLUDE set.
set -euo pipefail

SRC="$(cd "${1:?usage: stage.sh <plugin-src-dir> <out-dir>}" && pwd)"
OUT="${2:?usage: stage.sh <plugin-src-dir> <out-dir>}"
NAME="$(basename "$SRC")"
INCLUDE="$(cd "$(dirname "$0")/../include" && pwd)"
DEST="$OUT/$NAME"
SO="$DEST/$NAME.so"
mkdir -p "$DEST"

if [ -x "$SRC/build.sh" ]; then
    LUES_INCLUDE="$INCLUDE" "$SRC/build.sh" "$SRC" "$DEST"
elif ls "$SRC"/*.c >/dev/null 2>&1; then
    # -g: a fault trace names frames instead of raw offsets.
    ${CC:-cc} -shared -std=c11 -fPIC -O2 -g -Wall -Wextra -Werror -fvisibility=hidden \
        -I"$INCLUDE" -o "$SO" "$SRC"/*.c
else
    echo "stage.sh: $SRC holds no .c and no build.sh" >&2
    exit 1
fi
[ -f "$SO" ] || { echo "stage.sh: no $SO after the build" >&2; exit 1; }
