#!/usr/bin/env bash
# Called by stage.sh as `build.sh <src> <out>`; leaves rustplug.so in <out>.
set -euo pipefail
SRC="$1"
OUT="$2"
cargo build --quiet --release --manifest-path "$SRC/Cargo.toml" --target-dir "$SRC/target"
cp "$SRC/target/release/librustplug.so" "$OUT/rustplug.so"
