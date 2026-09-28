# FOO 0.5.0

**Release type:** FOO

**Git tag:** `foo-v0.5.0`

FOO 0.5.0 removes deprecated language forms and makes the compiler,
standard library, documentation, generated LLM reference, language server, and
VS Code extension agree on one canonical public surface.

The release also replaces quadratic persistent-sequence append behavior with a
shared geometric buffer and mutable newest-version tail. Older sequence
versions retain their logical lengths and branch through a measured copy path.
Expanded composition tests cover module resolution, public APIs, generics,
records, choices, failures, testing, and both native backends. Every FOO code
block in the documentation is now compile-checked or marked as an intentional
diagnostic example.

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
| npm package | `foo-0.5.0.tgz` |
| VS Code extension | `foo.iv-2.5.0.vsix` |
| OpenPGP public key | `key.asc` |
| Checksums | `SHA256SUMS.txt` |

FOO is available under your choice of the MIT License or Apache License 2.0.
