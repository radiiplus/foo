# Vendored dependency updates

## Inventory and header policy

| Dependency | Bundled form and provenance | Build use |
| --- | --- | --- |
| BLAKE3 1.8.7 | C sources and headers, commit `f3149ec5bb5449af877ba20377a11008ff499fa2`, Apache-2.0 | C crypto programs; portable, SSE2, and NEON sources as selected by target. |
| libsodium 1.0.22 | Windows x64 static library and matching headers, archive SHA-256 in `vendor/libsodium/README.md` | Windows C crypto programs; Linux package provisioner supplies the target build. |
| zlib 1.3.1 | Windows x64 static library and matching headers, source and library hashes in `vendor/zlib/README.md` | Windows C compression programs; Linux package provisioner supplies the target build. |
| SPIR-V Headers | `spirv.h`, commit `86f980c731e62ae4eaf383d320449d71687936bf`, MIT | Compiler GPU generation. |
| Vulkan Headers and volk | Headers commit `c46850864f4661461b0f6cb9922c058ffea4915e`; volk commit `0dc3ce00bf98b9f0b6fe708ca0f7eb74e2830173` | Vulkan programs only. The loader and driver come from the OS. |
| MoltenVK | Source snapshot commit `67b2682699d7903606b97a0392061d85d27d49e6` | Not linked in Windows builds; its macOS upstream dependencies and ICD are external. |

Headers for a bundled library stay at the same upstream revision as its
implementation or binary. Add more library headers only when a build actually
uses them and their license, revision, and target variants can be recorded.
The C standard library, platform SDK, and kernel headers remain supplied by
the selected target toolchain: copying host headers into `vendor/` would risk
ABI mismatches for cross-target builds. The Windows `stdlib.h`/`errno.h`
failure observed with a Linux-target C build on this host is a target-toolchain
configuration issue, not missing third-party headers.

## Patch log

| Date | Dependency | Local patch | Validation |
| --- | --- | --- | --- |
| 2026-10-09 | All above | No upstream source patch in this optimization pass. | Inventory and build gates inspected. |

Add a row for every future source patch, including the upstream revision,
changed files, reason, benchmark or correctness evidence, and the upstream
issue or pull request when one exists. Keep the original upstream archive or
commit retrievable, and store a reproducible patch against it.

## Update procedure

1. Record the current revision, license, target support, compiled sources,
   linked symbols, and raw baseline results for a representative FOO program.
2. Obtain the new upstream release from its authoritative source. Verify its
   release hash or commit and preserve its license and notices. Update headers
   together with matching sources or static libraries, including each target
   variant used by FOO.
3. Reapply local patches one at a time, review conflicts, and update the patch
   log. Confirm optional services remain linked only when imported.
4. Rebuild the native compiler and run the complete relevant library, native,
   backend, and platform tests. At minimum run `npm test`,
   `node bin/foo.mjs test lib --backend c`, and
   `node bin/foo.mjs test lib --backend zig` on available hosts, plus the
   dependency's own conformance tests and target cross-builds.
5. Repeat the same performance fixtures and parameters used for the baseline.
   Record raw samples, executable size, startup, peak memory, dependency
   versions, compiler flags, and hardware. Reject the patch if it regresses
   correctness, security, portability, or the intended workload without a
   documented trade-off.
