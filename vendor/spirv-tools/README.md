# Vendored SPIR-V validation

FOO validates Vulkan 1.3 shader products with `spirv-val` from SPIRV-Tools.
The Windows x64 executable was extracted from LunarG Vulkan SDK 1.4.363.0
(SPIRV-Tools v2026.4). The Linux x64 executable comes from Ubuntu 22.04's
`spirv-tools` package `2022.1+1.3.204.0-2` (SPIRV-Tools v2022.2-dev).
The binaries and notices are SHA-256 locked in `vendor/manifest.json`.

SPIRV-Tools is Apache-2.0 licensed. `LICENSE` contains the license text;
`COPYRIGHT.linux` records Ubuntu's package attribution and `NOTICE.sdk` is
LunarG's SDK notice. The Windows executable depends on the system MSVC/UCRT
runtime; the Linux executable depends on the host glibc and C++ runtime.

These are build-time validators, not Vulkan loaders or device drivers.
`FOO_SPIRV_VAL` can select another validator explicitly. The macOS validator
and MoltenVK runtime remain unqualified because no macOS host is available.
