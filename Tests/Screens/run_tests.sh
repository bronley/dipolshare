#!/bin/sh
set -eu

test_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(dirname -- "$(dirname -- "$test_directory")")
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/localsend-radar-tests.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

clang -fno-objc-arc -g -fsanitize=address,undefined -Wall -Wextra \
    -I "$project_directory/Sources/Screens" \
    "$test_directory/radar_layout_tests.m" \
    "$project_directory/Sources/Screens/LocalSendRadarLayout.m" \
    -framework Foundation -framework CoreGraphics \
    -o "$temporary_directory/radar_layout_tests"

"$temporary_directory/radar_layout_tests"
