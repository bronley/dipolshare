#!/bin/sh
set -eu

test_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(dirname -- "$(dirname -- "$test_directory")")
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/localsend-receiver-tests.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

clang -fno-objc-arc -fblocks -g -fsanitize=address,undefined \
    -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations \
    -I "$project_directory/Sources/Receiving" \
    -I "$project_directory/Sources/Networking" \
    -I "$project_directory/Sources/Security" \
    -I "$project_directory/Sources/Shared" \
    -I "$project_directory/Vendor/JSONKit" \
    "$test_directory/receiver_tests.m" \
    "$project_directory/Sources/Shared/LocalSendJSON.m" \
    "$project_directory/Vendor/JSONKit/JSONKit.m" \
    -framework Foundation -framework Security \
    -o "$temporary_directory/receiver_tests"

"$temporary_directory/receiver_tests" "$temporary_directory/data"
