#!/bin/sh
set -eu

test_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(dirname -- "$(dirname -- "$test_directory")")
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/localsend-json-tests.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

clang -fno-objc-arc -g -fsanitize=address,undefined -Wall -Wextra \
    -I "$project_directory/Sources/Shared" -I "$project_directory/Vendor/JSONKit" \
    "$test_directory/json_tests.m" \
    "$project_directory/Sources/Shared/LocalSendJSON.m" \
    "$project_directory/Vendor/JSONKit/JSONKit.m" \
    -framework Foundation -o "$temporary_directory/json_tests"

"$temporary_directory/json_tests"
