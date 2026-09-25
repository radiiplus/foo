# FOO 0.2.1

**Release type:** FOO

**Git tag:** `foo-v0.2.1`

FOO 0.2.1 fixes managed Zig installation and improves the Debian setup
experience. The installer provisions the pinned Zig backend automatically,
while offline installations can retry safely on first use.

See `CHANGELOG.md` for the complete release notes.

## Release Files

| Type | File |
| --- | --- |
| Windows x64 installer | `foo-windows-x64.exe` |
| Linux x64 installer | `foo-amd64.deb` |
| Linux ARM64 installer | `foo-arm64.deb` |
| Windows x64 archive | `foo-windows-x64.zip` |
| Linux x64 archive | `foo-linux-x64.tar.gz` |
| Linux ARM64 archive | `foo-linux-arm64.tar.gz` |
| npm package | `foo-0.2.1.tgz` |
| Checksums | `SHA256SUMS.txt` |

Ubuntu under Termux/proot on an ARM64 device should install `foo-arm64.deb`
inside the Ubuntu session. The package targets glibc and is not an Android
Termux binary.

FOO is available under your choice of the MIT License or Apache License 2.0.
