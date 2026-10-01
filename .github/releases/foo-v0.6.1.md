# FOO 0.6.1

**Release type:** FOO

**Git tag:** `foo-v0.6.1`

FOO 0.6.1 separates public build products from compiler working files.
Applications, static libraries, and shared libraries now publish to a
project-local `target/` directory by default, or to a safe directory selected
with `build.output`. FOO creates that directory automatically, restores a
missing public product from its build cache, and keeps generated backend files,
objects, reports, and cache metadata under `.artifacts/`.

The release also includes foo.iv 2.6.1. The extension recognizes
statement-leading bare zero-argument calls before postfix `try`, gives failure,
matching, and cleanup words dedicated scopes, and recognizes qualified
lowercase names in explicit type positions. Scope, rendered-color, and
real-source snapshot coverage protects the updated grammar.

The testing guide now states how selected file paths differ from imports inside
those files, with execution coverage for sibling modules and modules under the
configured source root.

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
| npm package | `foo-0.6.1.tgz` |
| VS Code extension | `foo.iv-2.6.1.vsix` |
| OpenPGP public key | `key.asc` |
| Checksums | `SHA256SUMS.txt` |

FOO is available under your choice of the MIT License or Apache License 2.0.
