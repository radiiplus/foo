# FOO 0.3.0

**Release type:** FOO

**Git tag:** `foo-v0.3.0`

FOO 0.3.0 makes builds faster and makes every toolchain operation easier to
follow. Compatible development builds now use faster C and Zig paths, compiler
caches are shared across projects, and parallel work adapts to the host while
leaving system headroom.

The CLI now presents check, build, run, package, publish, and toolchain work as
consistent live stages with timestamps, cache status, worker counts, elapsed
time, and concise summaries. Use `--explain` when deeper diagnostics are
needed.

Windows toolchain setup now uses WinHTTP and the system certificate store, so
portable and installer builds can provision Zig without OpenSSL.

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
| npm package | `foo-0.3.0.tgz` |
| Checksums | `SHA256SUMS.txt` |

FOO is available under your choice of the MIT License or Apache License 2.0.
