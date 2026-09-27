#!/bin/bash
# Rebuild the iOS 4.2 ARMv6/ARMv7 OpenSSL archives on a modern Mac.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo 'Usage: build-openssl-ios4.sh OUTPUT_DIRECTORY [SOURCE_ARCHIVE]' >&2
    exit 2
fi

version=3.5.8
source_sha=a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2
source_url="https://github.com/openssl/openssl/releases/download/openssl-${version}/openssl-${version}.tar.gz"
output=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1")
if [[ -e "$output" ]]; then
    echo "Output path already exists: $output" >&2
    exit 2
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/localsend-openssl-ios4.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

if [[ $# == 2 ]]; then
    archive=$2
else
    archive="$work/openssl-${version}.tar.gz"
    curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
        --output "$archive" "$source_url"
fi
actual_sha=$(shasum -a 256 "$archive" | awk '{print $1}')
if [[ "$actual_sha" != "$source_sha" ]]; then
    echo "Source SHA-256 mismatch: $actual_sha" >&2
    exit 1
fi

for arch in armv6 armv7; do
    src="$work/$arch"
    mkdir -p "$src"
    tar -xzf "$archive" -C "$src" --strip-components=1
    if [[ "$arch" == armv6 ]]; then
        python3 - "$src/Configurations/15-ios.conf" <<'PY'
import sys
path = sys.argv[1]
data = open(path).read()
needle = '    "ios-xcrun" => {'
replacement = '''    "ios-armv6-xcrun" => {
        inherit_from     => [ "ios-common" ],
        CC               => "xcrun -sdk iphoneos cc",
        cflags           => add("-arch armv6 -fno-common"),
        asm_arch         => 'armv4',
        perlasm_scheme   => "ios32",
    },
'''
if data.count(needle) != 1:
    raise SystemExit('Unexpected OpenSSL iOS target configuration')
open(path, 'w').write(data.replace(needle, replacement + needle))
PY
        target=ios-armv6-xcrun
    else
        target=ios-xcrun
    fi
    (
        cd "$src"
        ./Configure "$target" no-shared no-module no-tests no-apps no-asm \
            no-legacy no-dtls no-ssl3 no-comp -miphoneos-version-min=4.2 \
            -DOPENSSL_AES_CONST_TIME -DBROKEN_CLANG_ATOMICS \
            --prefix=/usr/local/localsend-openssl > "$work/configure-$arch.log" 2>&1
        ZERO_AR_DATE=1 make -j"${LOCALSEND_BUILD_JOBS:-4}" build_libs > "$work/build-$arch.log" 2>&1
    )
    if [[ $(xcrun lipo -archs "$src/libssl.a") != "$arch" ||
          $(xcrun lipo -archs "$src/libcrypto.a") != "$arch" ]]; then
        echo "Incorrect architecture in $arch OpenSSL archive" >&2
        exit 1
    fi
    if ! xcrun otool -l "$src/crypto/libcrypto-lib-threads_pthread.o" \
        | grep -A2 'LC_VERSION_MIN_IPHONEOS' | grep -q 'version 4.2'; then
        echo "Incorrect minimum OS in $arch OpenSSL object" >&2
        exit 1
    fi
    if xcrun nm -u "$src/libcrypto.a" "$src/libssl.a" 2>/dev/null \
        | grep -Eq '___atomic_[[:alnum:]_]*'; then
        echo "Unsupported atomic helper in $arch OpenSSL archive" >&2
        exit 1
    fi
done

if ! cmp -s "$work/armv6/include/openssl/configuration.h" \
             "$work/armv7/include/openssl/configuration.h"; then
    echo 'Generated public configurations differ by architecture' >&2
    exit 1
fi
mkdir -p "$work/output"
for lib in ssl crypto; do
    xcrun lipo -create "$work/armv6/lib${lib}.a" "$work/armv7/lib${lib}.a" \
        -output "$work/output/lib${lib}-${version}-ios4.a"
done
cp "$work"/configure-*.log "$work"/build-*.log "$work/output/"
mkdir -p "$(dirname "$output")"
mv "$work/output" "$output"
shasum -a 256 "$output"/*.a
