# FOO 0.8.0

FOO 0.8.0 expands the standard library to 72 modules and publishes its API and
source through the registry. Packages can include a validated SVG icon, shown
in registry listings and package details. The release also adds Vulkan-backed
GPU compute, guarded vector paths for sequence operations, and improvements to
native compilation, diagnostics, and documentation.

The included `foo.iv` 2.7.0 VS Code extension follows the updated language
grammar and editor diagnostics. See `CHANGELOG.md` for the full list of changes.

## Downloads

| Platform | Installer | Portable archive |
| --- | --- | --- |
| Windows x64 | `foo-windows-x64.exe` | `foo-windows-x64.zip` |
| Linux x64 | `foo-amd64.deb` | `foo-linux-x64.tar.gz` |
| Linux ARM64 | `foo-arm64.deb` | `foo-linux-arm64.tar.gz` |

The npm archive is `foo-0.8.0.tgz`, the editor extension is
`foo.iv-2.7.0.vsix`, and `foo-v0.8.0-source.tar.gz` contains the release source.
Verify downloads against `SHA256SUMS.txt` and its detached signature using
`key.asc`. Windows artifacts have detached signatures but no Authenticode
publisher certificate.

FOO is available under the MIT License or Apache License 2.0.
