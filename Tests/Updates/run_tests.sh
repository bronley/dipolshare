#!/bin/sh
set -eu
project_directory=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/dipol-update-tests.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
clang -fno-objc-arc -fblocks -g -fsanitize=address,undefined -Wall -Wextra \
    -Wno-unused-parameter -Wno-deprecated-declarations \
    -I "$project_directory/Sources/Application" \
    -I "$project_directory/Sources/Shared" -I "$project_directory/Vendor/JSONKit" \
    "$project_directory/Tests/Updates/update_tests.m" \
    "$project_directory/Sources/Application/UpdateManifest.m" \
    "$project_directory/Sources/Application/UpdateChecker.m" \
    "$project_directory/Sources/Shared/JSON.m" "$project_directory/Vendor/JSONKit/JSONKit.m" \
    -framework Foundation -o "$temporary_directory/update_tests"
"$temporary_directory/update_tests" "$@"
