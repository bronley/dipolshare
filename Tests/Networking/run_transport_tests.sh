#!/bin/sh
set -eu

# A native macOS OpenSSL build is needed here; the app's ARMv7 libraries are
# verified separately against the iOS SDK and on the phone.
if [ "$#" -ne 1 ]; then
    echo "usage: $0 /path/to/native/openssl-build" >&2
    exit 2
fi
openssl_directory=$1
test_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_directory=$(dirname -- "$(dirname -- "$test_directory")")/Sources
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/localsend-tls-receive.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

for identity in server client; do
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -subj "/CN=LocalSend-Test-$identity" \
        -keyout "$temporary_directory/$identity.key" -out "$temporary_directory/$identity.crt" \
        2> "$temporary_directory/certificate-generation.log"
done
openssl pkcs12 -export -inkey "$temporary_directory/server.key" \
    -in "$temporary_directory/server.crt" -out "$temporary_directory/server.p12" \
    -passout pass:test-password -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES -macalg sha1

clang -fno-objc-arc -g -fsanitize=address -Wall -Wextra \
    -Wno-unused-parameter -Wno-deprecated-declarations \
    -include "$test_directory/security_legacy_declaration.h" \
    -I "$openssl_directory/include" -I "$source_directory/Networking" -I "$source_directory/Security" \
    -I "$source_directory/Shared" -I "$(dirname "$source_directory")/Vendor/JSONKit" \
    "$test_directory/transport_harness.m" "$source_directory/Networking/LocalSendReceiveServer.m" "$source_directory/Networking/LocalSendIncomingConnection.m" \
    "$source_directory/Security/LocalSendTLS.m" "$source_directory/Networking/LocalSendConnectionActivity.m" "$source_directory/Shared/LocalSendJSON.m" \
    "$(dirname "$source_directory")/Vendor/JSONKit/JSONKit.m" \
    "$openssl_directory/libssl.a" "$openssl_directory/libcrypto.a" \
    -framework Foundation -framework Security \
    -o "$temporary_directory/transport_harness"
python3 "$test_directory/test_transport.py" \
    --harness "$temporary_directory/transport_harness" --fixtures "$temporary_directory"
