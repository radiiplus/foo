# Vendored MoltenVK source

This source snapshot comes from KhronosGroup/MoltenVK commit
`67b2682699d7903606b97a0392061d85d27d49e6` and is licensed under
Apache-2.0; see `LICENSE`. Its upstream build uses Xcode and additional
dependencies listed in `ExternalRevisions` and fetched by `fetchDependencies`.
Those dependencies and a compiled MoltenVK library are not bundled here.

On macOS, build this source with the upstream scripts, install or configure
the resulting Vulkan ICD, and make its loader visible to FOO. The adapter
requests Vulkan portability enumeration and the portability subset device
extension when available. This source snapshot and adapter have not been
compiled or exercised on macOS in the Windows test environment.
