#!/bin/sh
set -eu
test_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(dirname -- "$(dirname -- "$test_directory")")
source_directory=$project_directory/Sources
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/localsend-discovery-tests.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
clang -fno-objc-arc -fblocks -g -fsanitize=address,undefined -Wall -Wextra \
    -Wno-unused-parameter -Wno-incomplete-implementation -Wno-protocol \
    -I "$test_directory/Stubs" -I "$source_directory/Discovery" \
    -I "$source_directory/Receiving" -I "$source_directory/Networking" \
    -I "$source_directory/Security" -I "$source_directory/Shared" \
    -I "$project_directory/Vendor/JSONKit" \
    "$test_directory/refresh_tests.m" "$source_directory/Discovery/LocalSendDiscovery.m" \
    "$source_directory/Discovery/LocalSendDiscoveryMessage.m" \
    "$source_directory/Networking/LocalSendConnectionActivity.m" \
    "$source_directory/Shared/LocalSendJSON.m" "$project_directory/Vendor/JSONKit/JSONKit.m" \
    -framework Foundation -framework Security -o "$temporary_directory/refresh_tests"
"$temporary_directory/refresh_tests"
