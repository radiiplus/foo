# Vendored Vulkan compute support

`include/vulkan/vk_platform.h` and `include/vulkan/vulkan_core.h` come from
KhronosGroup/Vulkan-Headers commit `c46850864f4661461b0f6cb9922c058ffea4915e`.
They are licensed under Apache-2.0 OR MIT; see `LICENSE.headers.md`.

`volk.c` and `volk.h` come from zeux/volk commit
`0dc3ce00bf98b9f0b6fe708ca0f7eb74e2830173` and are MIT licensed; see
`LICENSE.volk.md`. The generated program compiles these sources when it uses
the FOO Vulkan service. The Vulkan loader and vendor drivers are supplied by
the operating system. `volk` loads device entry points directly.
