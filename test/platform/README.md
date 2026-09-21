# Target validation

The target, backend, and build Nim suites check platform compilation, WASI features,
and Windows debug output.
It does not execute the cross-compiled binaries.

For Linux execution and hardware validation, build the compiler with
`npm run build`, install the pinned Linux backend and QEMU, then run:

```sh
node test/platform/gates.mjs
```

Append check names to rerun only those checks, for example
`node test/platform/gates.mjs arm riscv`. Available names are `existing`,
`evaluation`, `aggregate`, `allocator`, `hardware`, `arm` and `riscv`.

On Windows, run this command inside WSL 2. Keep a separate Linux toolchain
installation when sharing the checkout: set `FOO_HOME` to a dedicated Linux
directory such as `$HOME/.foo`, and run `node tools/toolchain.mjs` with that same
environment. Keep this installation on WSL's Linux filesystem to avoid extracting
thousands of backend files through the Windows mount. The compiler build is portable JavaScript; the backend executables
and capability receipts are host-specific.

The runner checks scalar evaluation, static storage and managed allocation on
both backends, then probes compile-time function execution, aggregate static
initializers and the custom Allocator declaration contract. Each is a success
requirement, not an assertion that unsupported behavior should stay unsupported.
It continues after failures and exits nonzero if any requirement fails.

Hardware validation provisions the hardware capability, builds the shared
`fixtures/arm.iv` and `fixtures/riscv.iv` without a runtime, checks their ELF
entry addresses and runs them on QEMU's virtual boards. Each guest must produce
the expected serial marker before the runner stops it. The linker scripts place
the programs in each board's RAM; neither fixture assumes an initialized stack.
QEMU's [generic ELF loader](https://www.qemu.org/docs/master/system/generic-loader.html)
sets the CPU's program counter to the validated entry symbol. These are
freestanding executables, not Linux kernel images or OpenSBI payloads.

Generated sources, IR dumps, binaries and the versioned result report remain in
`.artifacts/test/gates-*`. The runner requires `qemu-system-aarch64` and
`qemu-system-riscv64`; registering a different simulator through `FOO_SIMULATOR`
does not supply those board runners. A hardware receipt alone does not prove
all target execution gates pass.
