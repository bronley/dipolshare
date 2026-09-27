#!/bin/bash
# Build pinned OpenSSL for LocalSend ARMv7/iOS 5 on a modern Mac with Xcode.
set -euo pipefail

openssl_version='3.5.8'
expected_source_checksum='a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2'
source_url="https://github.com/openssl/openssl/releases/download/openssl-${openssl_version}/openssl-${openssl_version}.tar.gz"

if [[ ${1:-} == '--help' || ${1:-} == '-h' ]]; then
    cat <<'USAGE'
Usage: build-openssl.sh OUTPUT_DIRECTORY [VERIFIED_SOURCE_ARCHIVE]

Produces ARMv7 libraries
USAGE
    exit 0
fi
if [[ $# -lt 1 || $# -gt 2 ]]; then
    printf '%s\n' 'Usage: build-openssl.sh OUTPUT_DIRECTORY [VERIFIED_SOURCE_ARCHIVE]' >&2
    exit 2
fi
if [[ $(uname -s) != 'Darwin' ]]; then
    printf '%s\n' 'This build requires macOS and Xcode.' >&2
    exit 2
fi
for required_tool in xcrun perl python3 curl make tar shasum; do
    if ! command -v "$required_tool" >/dev/null 2>&1; then
        printf 'Required tool is missing: %s\n' "$required_tool" >&2
        exit 2
    fi
done
output_directory=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1")
if [[ -e "$output_directory" || -L "$output_directory" ]]; then
    printf 'Output path already exists; choose a new directory: %s\n' "$output_directory" >&2
    exit 2
fi
build_jobs=${LOCALSEND_BUILD_JOBS:-4}
if [[ ! "$build_jobs" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' 'LOCALSEND_BUILD_JOBS must be a positive integer.' >&2
    exit 2
fi
sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
build_directory=$(mktemp -d "${TMPDIR:-/tmp}/localsend-openssl.XXXXXX")
build_succeeded=0
clean_up_build_directory() {
    if [[ "$build_succeeded" == 1 ]]; then
        rm -rf -- "$build_directory"
    else
        printf 'Build stopped; temporary source and logs remain at: %s\n' "$build_directory" >&2
    fi
}
trap clean_up_build_directory EXIT
staging_directory="$build_directory/output"
mkdir -p "$staging_directory"
if [[ $# == 2 ]]; then
    source_archive=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$2")
    if [[ ! -f "$source_archive" ]]; then
        printf 'Source archive does not exist: %s\n' "$source_archive" >&2
        exit 2
    fi
else
    source_archive="$build_directory/openssl-${openssl_version}.tar.gz"
    curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
        --output "$source_archive" "$source_url"
fi
actual_source_checksum=$(shasum -a 256 "$source_archive")
actual_source_checksum=${actual_source_checksum%% *}
if [[ "$actual_source_checksum" != "$expected_source_checksum" ]]; then
    printf 'Source checksum mismatch. Expected %s; got %s.\n' "$expected_source_checksum" "$actual_source_checksum" >&2
    exit 1
fi
# Derive a repeatable build timestamp from the checksum-verified release archive.
release_timestamp=$(python3 - "$source_archive" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1], 'r:gz') as archive:
    print(max(int(member.mtime) for member in archive.getmembers()))
PY
)
tar -xzf "$source_archive" -C "$build_directory"
source_directory="$build_directory/openssl-${openssl_version}"
configure_arguments=(ios-xcrun no-shared no-module no-tests no-apps no-asm no-legacy
              no-dtls no-ssl3 no-comp -miphoneos-version-min=5.0
              -DOPENSSL_AES_CONST_TIME -DBROKEN_CLANG_ATOMICS
              --prefix=/usr/local/localsend-openssl)
# Clear inherited compiler options that would silently change the recorded build.
# DEVELOPER_DIR remains honored, so xcrun uses the Xcode selected by the operator.
build_environment=(env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS
        -u LDLIBS -u AR -u ARFLAGS -u RANLIB -u AS -u ASFLAGS
        -u __CNF_CFLAGS -u __CNF_CPPFLAGS -u __CNF_LDFLAGS
        "SOURCE_DATE_EPOCH=$release_timestamp" ZERO_AR_DATE=1 LC_ALL=C)
(
    cd "$source_directory"
    "${build_environment[@]}" ./Configure "${configure_arguments[@]}" 2>&1 | tee "$staging_directory/configure-armv7.log"
    "${build_environment[@]}" make -j"$build_jobs" build_libs 2>&1 | tee "$staging_directory/build-armv7.log"
)
cp "$source_directory/libssl.a" "$staging_directory/libssl-${openssl_version}-armv7.a"
cp "$source_directory/libcrypto.a" "$staging_directory/libcrypto-${openssl_version}-armv7.a"
cp "$source_directory/configdata.pm" "$staging_directory/configdata-armv7.pm"
cp "$source_directory/LICENSE.txt" "$staging_directory/LICENSE-OpenSSL.txt"
# Apache 2.0 requires preservation of upstream NOTICE when one is supplied.
# OpenSSL 3.5.8 has no root NOTICE, but preserve it for an intentionally updated pin.
for notice_filename in NOTICE NOTICE.txt; do
    if [[ -f "$source_directory/$notice_filename" ]]; then
        cp "$source_directory/$notice_filename" "$staging_directory/NOTICE-OpenSSL.txt"
        break
    fi
done

python3 - "$source_directory" "$staging_directory" "$openssl_version" "$expected_source_checksum" \
    "$source_url" "$sdk_path" "$release_timestamp" "$build_jobs" "${configure_arguments[@]}" <<'PY'
import gzip, hashlib, json, pathlib, re, shlex, shutil, subprocess, sys, tarfile
source, stage = map(pathlib.Path, sys.argv[1:3])
version, source_sha, source_url, sdk, epoch, jobs = sys.argv[3:9]
configure = sys.argv[9:]

def run(*command):
    return subprocess.run(command, check=True, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

headers = stage / 'include' / 'openssl'
headers.mkdir(parents=True)
for header in sorted((source / 'include' / 'openssl').glob('*.h')):
    shutil.copyfile(header, headers / header.name)
for required in ('configuration.h', 'opensslconf.h', 'opensslv.h', 'ssl.h',
                 'rsa.h', 'err.h', 'rand.h'):
    if not (headers / required).is_file():
        raise SystemExit('Missing required public/generated header: ' + required)

symbols = set()
for library in ('ssl', 'crypto'):
    path = stage / ('lib%s-%s-armv7.a' % (library, version))
    if run('xcrun', 'lipo', '-archs', str(path)).strip() != 'armv7':
        raise SystemExit('Library does not contain exactly the ARMv7 architecture')
    undefined = run('xcrun', 'nm', '-u', str(path))
    if re.search(r'\b___atomic_\w+', undefined):
        raise SystemExit('Unsupported compiler atomic helper remained in ' + path.name)
    for line in run('xcrun', 'nm', '-gU', str(path)).splitlines():
        match = re.match(r'^\s*[0-9a-fA-F]+\s+[A-Za-z]\s+(\S+)\s*$', line)
        if match:
            symbols.add(match.group(1))
if not {'_SSL_new', '_SSL_connect', '_SSL_accept', '_RSA_sign'} <= symbols:
    raise SystemExit('Defined-symbol extraction did not find expected OpenSSL exports')
(stage / 'OpenSSLHiddenSymbols.txt').write_text('\n'.join(sorted(symbols)) + '\n')
aes_symbols = run('xcrun', 'nm', str(source / 'crypto/aes/libcrypto-lib-aes_core.o'))
if re.search(r'\b_[Tt][ed][0-9]+\b', aes_symbols):
    raise SystemExit('AES lookup tables remained; expected the constant-time AES build')
minimum = run('xcrun', 'otool', '-l',
              str(source / 'crypto/libcrypto-lib-threads_pthread.o'))
if not re.search(r'cmd LC_VERSION_MIN_IPHONEOS\s+cmdsize \d+\s+version 5\.0\b', minimum):
    raise SystemExit('Object does not declare the expected iOS 5.0 deployment target')

# Stable header archive metadata; generated headers retain upstream comments.
archive_path = stage / ('OpenSSLHeaders-%s.tar.gz' % version)
archive_files = sorted((stage / 'include').rglob('*.h'))
archive_files += [stage / 'LICENSE-OpenSSL.txt']
notice = stage / 'NOTICE-OpenSSL.txt'
if notice.exists():
    archive_files.append(notice)
with archive_path.open('wb') as output:
    with gzip.GzipFile(filename='', mode='wb', fileobj=output, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as tar:
            for path in archive_files:
                info = tar.gettarinfo(str(path), arcname=str(path.relative_to(stage)))
                info.uid = info.gid = 0
                info.uname = info.gname = ''
                info.mode = 0o644
                info.mtime = 0
                with path.open('rb') as content:
                    tar.addfile(info, content)
manifest = {
    'openssl_version': version,
    'source_url': source_url,
    'source_sha256': source_sha,
    'source_date_epoch': int(epoch),
    'architecture': 'armv7',
    'deployment_target': '5.0',
    'sdk_path': sdk,
    'compiler': run('xcrun', '--sdk', 'iphoneos', 'cc', '--version').strip(),
    'xcode': run('xcodebuild', '-version').strip(),
    'configure_argv': ['./Configure'] + configure,
    'configure_command': shlex.join(['./Configure'] + configure),
    'build_argv': ['make', '-j' + jobs, 'build_libs'],
    'public_header_count': len(list(headers.glob('*.h'))),
    'hidden_symbols_count': len(symbols),
    'upstream_notice_present': notice.exists(),
    'checks': ['ARMv7 archives', 'iOS 5.0 object deployment target',
               'No compiler atomic helper imports', 'No AES Te/Td lookup tables'],
    'files': {},
}
for path in sorted(stage.iterdir()):
    if path.is_file():
        data = path.read_bytes()
        manifest['files'][path.name] = {
            'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()
        }
(stage / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY
mkdir -p "$(dirname "$output_directory")"
# Refuse a path created by another process while the long build was running.
if [[ -e "$output_directory" || -L "$output_directory" ]]; then
    printf 'Output path appeared during the build: %s\n' "$output_directory" >&2
    exit 1
fi
mv "$staging_directory" "$output_directory"
build_succeeded=1
printf 'OpenSSL artifacts are ready in: %s\n' "$output_directory"
printf '%s\n' 'Next: link the app, verify final Mach-O exports/dependencies, and test on iOS 5–6.'
