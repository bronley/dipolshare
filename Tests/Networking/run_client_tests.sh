#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then
    echo "usage: $0 /path/to/native/openssl-build" >&2
    exit 2
fi
openssl_directory=$1
test_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_directory=$(dirname -- "$(dirname -- "$test_directory")")/Sources
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/localsend-tls-client.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
for identity in client server; do
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=LocalSend-Test-$identity" \
        -keyout "$temporary_directory/$identity.key" -out "$temporary_directory/$identity.crt" \
        2> "$temporary_directory/certificate-generation.log"
done
openssl pkcs12 -export -inkey "$temporary_directory/client.key" -in "$temporary_directory/client.crt" \
    -out "$temporary_directory/client.p12" -passout pass:test-password \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
clang -fno-objc-arc -g -fsanitize=address,undefined -Wall -Wextra -Werror \
    -DSecKeyRawSign=LocalSendTestSecKeyRawSign \
    -Wno-deprecated-declarations -include "$test_directory/security_legacy_declaration.h" \
    -I "$openssl_directory/include" -I "$source_directory/Networking" -I "$source_directory/Security" "$test_directory/client_harness.m" \
    "$source_directory/Networking/LocalSendHTTPSClient.m" "$source_directory/Networking/LocalSendHTTPResponseParser.m" "$source_directory/Networking/LocalSendConnectionActivity.m" "$source_directory/Security/LocalSendCertificateFingerprint.m" "$source_directory/Security/LocalSendTLS.m" \
    "$openssl_directory/libssl.a" "$openssl_directory/libcrypto.a" \
    -framework Foundation -framework Security -o "$temporary_directory/client_harness"
"$temporary_directory/client_harness" - 0 - progress
python3 "$test_directory/test_client_transport.py" --harness "$temporary_directory/client_harness" --fixtures "$temporary_directory"
