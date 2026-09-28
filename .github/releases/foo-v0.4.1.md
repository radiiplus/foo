# FOO 0.4.1

**Release type:** FOO

**Git tag:** `foo-v0.4.1`

FOO 0.4.1 is a compiler, Linux compatibility, test workflow, language-server,
and documentation patch release.

Basic Zig programs using built-in `display` no longer depend on generated C
service headers or libc. Host GCC builds avoid the Clang-only `-target` option,
flat projects keep test and benchmark sources out of application discovery,
and `foo test` now uses the same staged progress interface as other operations.

The language server now follows the compiler's complete analysis pipeline, so
top-level execution, current failure syntax, imports, expansion, linting, type
checking, and capability diagnostics agree with `foo check`. Editor diagnostics
also carry stable FOO codes, exact ranges, suggestions, and fixes.

Linux x64 and ARM64 binaries are signed with the FOO release key. Verify the
detached signatures included beside each ELF binary using `key.asc`, and verify
every uploaded artifact with `SHA256SUMS.txt`.

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
| npm package | `foo-0.4.1.tgz` |
| VS Code extension | `foo.iv-2.4.1.vsix` |
| OpenPGP public key | `key.asc` |
| Checksums | `SHA256SUMS.txt` |

FOO is available under your choice of the MIT License or Apache License 2.0.
