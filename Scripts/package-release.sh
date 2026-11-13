#!/bin/sh
set -eu

project_directory=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_directory"
: "${THEOS:?Set THEOS to the Theos installation directory}"
command -v magick >/dev/null
command -v ldid >/dev/null
command -v python3 >/dev/null

package_id=$(awk '/^Package:/ {print $2}' control)
version=$(awk '/^Version:/ {print $2}' control)
ipa="$project_directory/packages/${package_id}_${version}.ipa"
deb="$project_directory/packages/${package_id}_${version}_iphoneos-arm.deb"

make package DEV_TESTING=0 FINALPACKAGE=1 PACKAGE_FORMAT=ipa \
    THEOS_OBJ_DIR_NAME=obj/production \
    DipolShare_CODESIGN_FLAGS="-S$project_directory/Configuration/production.entitlements" -j4

staging_directory=$(mktemp -d "${TMPDIR:-/tmp}/dipol-release.XXXXXX")
trap 'rm -rf "$staging_directory"' EXIT HUP INT TERM
unzip -q "$ipa" -d "$staging_directory/ipa"
mkdir -p "$staging_directory/package/Applications" "$staging_directory/package/DEBIAN"
app="$staging_directory/package/Applications/DipolShare.app"
mv "$staging_directory/ipa/Payload/DipolShare.app" "$app"

icons="$project_directory/build/cydia-icons"
mkdir -p "$icons"
pad_icon() {
    magick -size "$2" canvas:none "Resources/Images/$1" \
        -geometry "$3" -compose Copy -composite "PNG32:$icons/$1"
    cp "$icons/$1" "$app/$1"
}
pad_icon Localsend.png 59x60 +1+0
pad_icon Localsend@2x.png 118x120 +2+1
pad_icon Icon-72.png 74x76 +1+1
pad_icon Icon-72@2x.png 148x152 +2+2

ldid -SConfiguration/production.entitlements "$app/DipolShare"
cat control Configuration/cydia.control > "$staging_directory/package/DEBIAN/control"
installed_size=$(du -sk "$staging_directory/package/Applications" | awk '{print $1}')
printf 'Installed-Size: %s\n' "$installed_size" >> "$staging_directory/package/DEBIAN/control"
cp Configuration/cydia.postinst "$staging_directory/package/DEBIAN/postinst"
chmod 755 "$staging_directory/package/DEBIAN" "$staging_directory/package/DEBIAN/postinst"
COPYFILE_DISABLE=1 tar --format=ustar --uid 0 --gid 0 --uname root --gname wheel \
    -czf "$staging_directory/control.tar.gz" -C "$staging_directory/package/DEBIAN" .
COPYFILE_DISABLE=1 tar --format=ustar --uid 0 --gid 0 --uname root --gname wheel \
    -czf "$staging_directory/data.tar.gz" -C "$staging_directory/package" Applications
printf '2.0\n' > "$staging_directory/debian-binary"
python3 - "$staging_directory" <<'PY'
from pathlib import Path
import sys

directory = Path(sys.argv[1])
with (directory / 'package.deb').open('wb') as archive:
    archive.write(b'!<arch>\n')
    for name in ('debian-binary', 'control.tar.gz', 'data.tar.gz'):
        data = (directory / name).read_bytes()
        header = f'{name:<16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(data):<10}`\n'
        archive.write(header.encode('ascii'))
        archive.write(data)
        if len(data) % 2:
            archive.write(b'\n')
PY
mv "$staging_directory/package.deb" "$deb"
printf 'IPA: %s\nCydia: %s\nPadded icons: %s\n' "$ipa" "$deb" "$icons"
