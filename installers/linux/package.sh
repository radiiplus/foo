#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: build.sh VERSION SOURCE_DIR OUTPUT_DIR" >&2
  exit 2
fi

version=$1
source_dir=$(realpath "$2")
output_dir=$(realpath -m "$3")
package_root=$(mktemp -d)
trap 'rm -rf "$package_root"' EXIT INT TERM

if [ ! -x "$source_dir/bin/foo" ]; then
  echo "missing executable: $source_dir/bin/foo" >&2
  exit 1
fi

install -d \
  "$package_root/DEBIAN" \
  "$package_root/opt/foo" \
  "$package_root/usr/bin" \
  "$package_root/usr/share/doc/foo" \
  "$package_root/usr/share/icons/hicolor/scalable/apps" \
  "$package_root/usr/share/metainfo" \
  "$output_dir"

cp -a "$source_dir/." "$package_root/opt/foo/"
find "$package_root/opt/foo" -type d -exec chmod 0755 {} +
find "$package_root/opt/foo" -type f -exec chmod 0644 {} +
chmod 0755 "$package_root/opt/foo/bin/foo"
ln -s /opt/foo/bin/foo "$package_root/usr/bin/foo"
install -m 0644 "$source_dir/assets/dark.svg" \
  "$package_root/usr/share/icons/hicolor/scalable/apps/io.github.radiiplus.foo.svg"
install -m 0644 "$source_dir/LICENSE" "$package_root/usr/share/doc/foo/copyright"
install -m 0644 "$source_dir/LICENSE-MIT" "$package_root/usr/share/doc/foo/LICENSE-MIT"
install -m 0644 "$source_dir/LICENSE-APACHE" "$package_root/usr/share/doc/foo/LICENSE-APACHE"

installed_size=$(du -sk "$package_root/opt/foo" | cut -f1)
cat > "$package_root/DEBIAN/control" <<EOF
Package: foo
Version: $version
Section: devel
Priority: optional
Architecture: amd64
Installed-Size: $installed_size
Maintainer: radiiplus <radiiplus@users.noreply.github.com>
Homepage: https://github.com/radiiplus/foo
Depends: libc6
Description: Readable systems programming language
 FOO checks, formats, tests, builds, and runs sentence-like .iv programs,
 with C and Zig available as native output backends.
EOF

sed "s/@VERSION@/$version/g" "$(dirname "$0")/io.github.radiiplus.foo.metainfo.xml.in" \
  > "$package_root/usr/share/metainfo/io.github.radiiplus.foo.metainfo.xml"
chmod 0644 "$package_root/DEBIAN/control" \
  "$package_root/usr/share/metainfo/io.github.radiiplus.foo.metainfo.xml"

fakeroot dpkg-deb --build --root-owner-group "$package_root" \
  "$output_dir/foo-v$version-linux-x64.deb"
