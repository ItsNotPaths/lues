#!/usr/bin/env bash
# Called by stage.sh as `build.sh <src> <out>`; leaves cxxplug.so in <out>.
set -euo pipefail
${CXX:-c++} -shared -std=c++17 -fPIC -O2 -g -Wall -Wextra -Werror -fvisibility=hidden \
    -I"$LUES_INCLUDE" -o "$2/cxxplug.so" "$1"/*.cpp
