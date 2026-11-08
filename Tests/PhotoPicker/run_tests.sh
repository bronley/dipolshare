#!/bin/sh
set -eu

test_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(dirname -- "$(dirname -- "$test_directory")")
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/dipol-photo-loader-tests.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

clang -fno-objc-arc -fblocks -g -fsanitize=address,undefined \
    -Wall -Wextra -Wno-unused-parameter \
    -I "$test_directory/Stubs" -I "$project_directory/Sources/Screens/PhotoPicker" \
    "$test_directory/loader_tests.m" \
    "$project_directory/Sources/Screens/PhotoPicker/PhotoLibraryLoader.m" \
    "$project_directory/Sources/Screens/PhotoPicker/PickerAsset.m" \
    -framework Foundation -o "$temporary_directory/loader_tests"
"$temporary_directory/loader_tests"
