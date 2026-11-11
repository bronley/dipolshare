#!/bin/sh
set -eu
tests=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project=$(dirname -- "$(dirname -- "$tests")")
build=$(mktemp -d "${TMPDIR:-/tmp}/localsend-contacts-tests.XXXXXX")
trap 'rm -rf "$build"' EXIT HUP INT TERM
xcrun clang -fno-objc-arc -fblocks -g -Wall -Wextra -Wno-unused-parameter \
    -fsanitize=address,undefined -fno-omit-frame-pointer -Ddlsym=ContactTestLookup \
    -I "$tests/Stubs" -I "$project/Sources/Sending/Contacts" \
    "$project/Sources/Sending/Contacts/ContactBackup.m" \
    "$project/Sources/Sending/Contacts/VCardWriter.m" "$tests/contacts_tests.m" \
    -framework Foundation -framework Contacts -o "$build/contacts-tests"
"$build/contacts-tests"
