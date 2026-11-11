#!/bin/sh
set -eu

test_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(dirname -- "$(dirname -- "$test_directory")")
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/dipol-photo-saver-tests.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

clang -fno-objc-arc -fblocks -g -fsanitize=address,undefined \
    -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations \
    -I "$test_directory/Stubs" -I "$project_directory/Sources/Receiving" \
    "$test_directory/photo_library_saver_tests.m" \
    "$project_directory/Sources/Receiving/PhotoLibrarySaver.m" \
    -framework Foundation -o "$temporary_directory/photo_saver_tests"

"$temporary_directory/photo_saver_tests" "$temporary_directory"
