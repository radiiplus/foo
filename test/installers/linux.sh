#!/bin/sh
set -eu

repository=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
compiler=${1:-"$repository/.artifacts/linuxfoo"}
if [ ! -x "$compiler" ]; then
  echo "Linux FOO executable required: $compiler" >&2
  exit 2
fi
case $(uname -m) in
  x86_64) host_architecture=amd64 ;;
  aarch64) host_architecture=arm64 ;;
  *) echo "Unsupported Linux package test architecture: $(uname -m)" >&2; exit 2 ;;
esac
architecture=${2:-$host_architecture}
runner=
if [ "$architecture" != "$host_architecture" ]; then
  if [ "$architecture" != arm64 ]; then
    echo "Cross execution is not configured for Debian architecture $architecture" >&2
    exit 2
  fi
  runner=${FOO_QEMU_AARCH64:-qemu-aarch64}
  if ! command -v "$runner" >/dev/null 2>&1; then
    echo "ARM64 package execution requires FOO_QEMU_AARCH64 or qemu-aarch64" >&2
    exit 2
  fi
fi
run_compiler() {
  if [ -n "$runner" ]; then "$runner" "$1" version
  else "$1" version
  fi
}
compiler_version=$(run_compiler "$compiler" | sed -n 's/^compiler //p')
test -n "$compiler_version"
upgrade_version=$compiler_version+test1
for tool in dpkg-deb fakeroot gpg node readelf tar; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Linux package gate requires $tool" >&2
    exit 2
  fi
done

test_output=${FOO_TEST_ARTIFACT_DIR:-$(node "$repository/test/location.mjs")}
mkdir -p "$test_output"
workspace=$(mktemp -d "$test_output/foo-release-test.XXXXXX")
trap 'rm -rf "$workspace"' EXIT INT TERM
source_dir=$workspace/source
output_dir=$workspace/output
installed=$workspace/installed
mkdir -p "$source_dir/bin" "$source_dir/assets" "$output_dir" "$installed"
distribution=$(dirname "$(dirname "$compiler")")
staged=false
if [ -f "$distribution/foo.artifact.json" ]; then
  cp -a "$distribution/." "$source_dir/"
  staged=true
else
  cp "$compiler" "$source_dir/bin/foo"
  cp "$repository/assets/dark.svg" "$source_dir/assets/dark.svg"
  cp "$repository/LICENSE" "$repository/LICENSE-MIT" "$repository/LICENSE-APACHE" "$source_dir/"
fi
printf 'first\n' > "$source_dir/upgrade-marker"

sh "$repository/installers/linux/package.sh" "$compiler_version" "$source_dir" "$output_dir" "$architecture"
package=$output_dir/foo-$architecture.deb
test -f "$package"
test "$(dpkg-deb -f "$package" Version)" = "$compiler_version"
dpkg-deb -f "$package" Description | grep -Fq 'QBE as its native output backend'
dpkg-deb -f "$package" Description | grep -Fq 'License: MIT OR Apache-2.0'
dpkg-deb -f "$package" Description | grep -Fq 'not sandboxed'
dpkg-deb -f "$package" Depends | grep -Fq 'libssl3'
dpkg-deb --fsys-tarfile "$package" | tar -xOf - ./usr/share/metainfo/io.github.radiiplus.foo.metainfo.xml | grep -Fq '<project_license>MIT OR Apache-2.0</project_license>'
dpkg-deb --fsys-tarfile "$package" | tar -xOf - ./usr/share/metainfo/io.github.radiiplus.foo.metainfo.xml | grep -Fq '<url type="help">https://github.com/radiiplus/foo/blob/main/docs/start.md</url>'
dpkg-deb --fsys-tarfile "$package" | tar -tf - | grep -Fq './usr/share/icons/hicolor/256x256/apps/io.github.radiiplus.foo.png'
if dpkg-deb --ctrl-tarfile "$package" | tar -tf - | grep -Eq '(^|/)postinst$'; then
  echo 'Debian installation must not provision a backend' >&2
  exit 1
fi
mkdir -p "$installed/var/lib/dpkg"
: > "$installed/var/lib/dpkg/status"
dpkg --force-not-root --force-script-chrootless --force-depends --force-architecture --root="$installed" --install "$package" >/dev/null
test "$(dpkg --admindir="$installed/var/lib/dpkg" -s foo | sed -n 's/^Version: //p')" = "$compiler_version"
run_compiler "$installed/opt/foo/bin/foo" | grep -Fq "compiler $compiler_version"
test "$(cat "$installed/opt/foo/upgrade-marker")" = first
if [ "$staged" = true ]; then
  test -f "$installed/opt/foo/foo.artifact.json"
  test -f "$installed/opt/foo/toolchain/assets.json"
  test -f "$installed/opt/foo/vendor/manifest.json"
  test -d "$installed/opt/foo/vendor/moltenvk"
  test "$(node -p "require('$installed/opt/foo/foo.artifact.json').architecture")" = \
    "$(if [ "$architecture" = amd64 ]; then printf x64; else printf arm64; fi)"
fi

export GNUPGHOME=$workspace/gnupg
mkdir -m 700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key \
  'FOO release test <release-test@example.invalid>' rsa2048 sign 0 >/dev/null 2>&1
FOOSIGNER=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')
export FOOSIGNER
test -n "$FOOSIGNER"
node "$repository/tools/sign.mjs" "$source_dir/bin/foo"
node "$repository/tools/sign.mjs" --verify "$source_dir/bin/foo"
printf '%s  %s\n' "$(sha256sum "$source_dir/bin/foo" | cut -d ' ' -f 1)" bin/foo > "$source_dir/SHA256SUMS"
node "$repository/tools/sign.mjs" --manifest "$source_dir/SHA256SUMS"
node "$repository/tools/sign.mjs" --verify --manifest "$source_dir/SHA256SUMS"
if FOOSIGNER=0000000000000000000000000000000000000000 \
    node "$repository/tools/sign.mjs" --verify --manifest "$source_dir/SHA256SUMS" >/dev/null 2>&1; then
  echo 'A manifest signed by a different key passed signer verification' >&2
  exit 1
fi
printf 'corrupt\n' >> "$source_dir/SHA256SUMS"
if node "$repository/tools/sign.mjs" --verify --manifest "$source_dir/SHA256SUMS" >/dev/null 2>&1; then
  echo 'A changed checksum manifest passed signature verification' >&2
  exit 1
fi
sed -i '$d' "$source_dir/SHA256SUMS"
cp "$source_dir/bin/foo" "$workspace/tampered"
cp "$source_dir/bin/foo.asc" "$workspace/tampered.asc"
printf x >> "$workspace/tampered"
if node "$repository/tools/sign.mjs" --verify "$workspace/tampered" >/dev/null 2>&1; then
  echo 'A changed binary passed signature verification' >&2
  exit 1
fi

printf 'second\n' > "$source_dir/upgrade-marker"
sh "$repository/installers/linux/package.sh" "$upgrade_version" "$source_dir" "$output_dir" "$architecture"
test "$(dpkg-deb -f "$package" Version)" = "$upgrade_version"
printf 'keep\n' > "$workspace/user-project"
dpkg --force-not-root --force-script-chrootless --force-depends --force-architecture --root="$installed" --install "$package" >/dev/null
test "$(dpkg --admindir="$installed/var/lib/dpkg" -s foo | sed -n 's/^Version: //p')" = "$upgrade_version"
test "$(cat "$installed/opt/foo/upgrade-marker")" = second
test "$(cat "$workspace/user-project")" = keep
node "$repository/tools/sign.mjs" --verify "$installed/opt/foo/bin/foo"
(cd "$installed/opt/foo" && sha256sum -c SHA256SUMS)
node "$repository/tools/sign.mjs" --verify --manifest "$installed/opt/foo/SHA256SUMS"
run_compiler "$installed/opt/foo/bin/foo" | grep -Fq "compiler $compiler_version"
echo 'Linux Debian package, offline signing, fresh installation and dpkg upgrade passed'
