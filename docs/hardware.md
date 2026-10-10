# Hardware and Parallel Computation

Status: staged implementation. Current FOO supports fixed-width
`vector[N, T]`, lane-wise arithmetic and comparisons, `splat`, `shuffle`,
`permute`, `gather`, `scatter`, `select`, `reduce`, and CPU target profiles.
The `matrix` and `tensor` modules provide dense CPU values and operations.
`arch.runtime` queries CPU features usable by the process, and `cpu.add` runs
byte addition through AVX2, SSE2, NEON, or scalar code at runtime. Release
builds also vectorize eligible decimal sequence loops. The `gpu`
module discovers a Vulkan compute device and runs SPIR-V kernels with explicit buffers,
transfers, and completion. Private `function ... for gpu` declarations lower a
checked straight-line decimal 32 sequence subset to SPIR-V. Matrix and tensor
remain library records.

`gather` reads lanes from one vector using a vector of integer indices.
`scatter` returns a new vector after writing lanes in index order, so the last
write wins when indices repeat. Both check every index. `permute` selects
compile-time lanes from one vector. These operations run on the C and Zig
backends; they do not yet promise one hardware gather or scatter instruction.
`arch.target(feature)` reports the selected build target's SIMD features for
`sse2`, `avx2`, `avx512f`, `fma`, `neon`, and `sve`. `arch.runtime(feature)`
checks whether this process can use the requested instruction set.

`platform.page`, `width`, `alignment`, and `little` report the host's page
size, pointer width in bytes, maximum C alignment, and byte order.
`platform.supports` reports named runtime capabilities such as `"mapping"`,
`"position"`, `"locking"`, `"affinity"`, `"numa"`, and `"limits"`; unknown names
return false. An individual operation can still fail for a particular resource.

`topology.count` reports online logical processors, which can exceed the CPUs
allowed to the current process. `topology.current` reports the calling thread's
OS processor ID. `topology.pin(cpu)` returns an owned placement that remembers
the thread's previous affinity; call `topology.restore(placement)` once, on the
same thread, to restore it. Pinning may fail if the OS disallows the requested
processor. Windows IDs are processor-group number times 64 plus the number
within that group. Linux pinning accepts CPU IDs below `CPU_SETSIZE`.
Current-processor and affinity operations are available on
Windows and Linux; other POSIX targets return `MissingValue`.
`topology.allowed` counts processors the calling thread can use in its current
Windows processor group or Linux affinity mask.
`topology.nodes` reports the discovered NUMA node count, and
`topology.node(cpu)` maps an OS processor ID to its node. Use
`topology.place(node)` to pin the current thread to an available CPU in that
node; restore its prior affinity with `topology.restore`. These NUMA calls are
available on Windows and Linux and do not change memory allocation policy.

## Runtime Execution

Release builds for the hosted C and Zig backends recognize independent counted
loops over 32-bit or 64-bit decimal sequences. They support constant or
parameter starting
indices, up to two indexed reads, invariant scalar operands, fill and copy,
`plus`, `subtract`, `multiply`, `divide`, and a second arithmetic operation
with an invariant scalar on either side. Each loop writes one output sequence and increments
its index by one.
The optimizer selects the SIMD candidate through the compiler's evidenced
specialization selector. A runtime guard checks the input and output lengths,
overlap, lane count, and CPU features before dispatching to AVX-512F on the C
backend for large ranges, AVX2 or SSE2 on x86, or NEON on AArch64. Zig 0.16
uses AVX2 or SSE2 on x86 because its C compilation cannot build the per-function
AVX-512 path. The original checked scalar
loop remains the fallback for unsupported sizes, overlap, and bounds failures.
`--explain` reports `vectorize` when this path is selected. Dependent loops
remain scalar. Other loop forms and order-changing reductions are outside the
implemented automatic CPU vectorization contract.

`cpu.add(left, right, output)` takes equally sized byte slices, adds each lane
modulo 256, and writes into caller-owned output. Exact in-place output is
allowed; partial overlap fails. Runtime dispatch checks CPU and operating-system
support before using AVX2 or SSE2 on x86, uses NEON on AArch64, and otherwise
uses scalar code.

`simd.load/store` move four contiguous decimal32 lanes to and from sequences;
`simd.words/write` do the same for unsigned32, `simd.signed/assign` for
integer32, and `simd.pair/place` for two decimal64 lanes. Every operation
checks its offset and extent. These value operations are portable across C and
Zig; explicit shuffles and gathers do not promise one native instruction.

`gpu.available` reports whether a Vulkan loader and compute device are present.
`gpu.open` owns a logical device and queue. `reserve`, `upload`, `download`,
`prepare`, `bind`, `launch`, and `finish` provide explicit execution. Buffers
use coherent host-visible memory and remain mapped while owned. Transfers and
dispatch complete before returning. Bound buffers cannot be disposed until the
kernel is discarded. Programs call `discard`, `dispose`, and `close` for owned
resources. `gpu.capacity` reports the device workgroup limit; dispatch also
checks the kernel's local-memory limit. `gpu.supports` recognizes `shared`,
`atomic`, `subgroup`, and `mapping`. `gpu.view/edit` borrow coherent host-visible
bytes from an owned buffer; keep the buffer live and serialize host access with
dispatch. Subgroup preparation requires compute-stage subgroup
ballot support from the selected device.
`gpu.plane` and `gpu.volume` launch two- and three-dimensional ranges with
checked local dimensions and buffer coverage. Generated `gpu.index`,
`gpu.local`, and `gpu.group` are row-major linear IDs in every launch shape.

The implemented FOO kernel subset takes decimal 32 sequence parameters and uses
`gpu.index`, `gpu.local`, and `gpu.group` for indexed reads and writes in 1D,
2D, and 3D ranges. It supports straight-line `plus`, `subtract`, `multiply`,
and `divide`. `gpu.prepare` takes
a compile-time kernel name, generates SPIR-V, and compiles it on the opened
device. `gpu.send` and `gpu.receive` transfer decimal 32 sequences. The launch
checks every bound buffer can cover the requested count. `gpu.dispatch` takes
an explicit workgroup size that must divide the total count. `gpu.shared`
allocates compile-time sized decimal 32 workgroup storage; its local-ID access
requires a group no larger than the allocation. `gpu.barrier`
synchronizes global and local workgroup memory. `gpu.atomic` performs wrapping
unsigned 32 addition on a writable device sequence; `gpu.push` and `gpu.pull`
transfer unsigned 32 sequences. Straight-line kernels make barrier participation
uniform. Unsupported effects or control flow fail
compilation. For example:

```text
function shade(left sequence of constant decimal 32, right sequence of constant decimal 32, output sequence of decimal 32) giving nothing for gpu {
  constant index is gpu.index.
  set output at index to (left at index) plus (right at index).
}

constant kernel is gpu.prepare(device, "shade") try.
```

`gpu.lane`, `gpu.subgroup`, and `gpu.width` expose subgroup location and size.
`gpu.broadcast` broadcasts a decimal 32 value from lane zero. Preparation
rejects these operations when the selected device lacks subgroup ballot support.

The lower-level `vulkan` module accepts caller-supplied SPIR-V bytes and an
explicit descriptor count and initial workgroup width. It exposes device
enumeration, byte buffers, binding, and checked 1D/2D/3D dispatch. This path
does not validate shader memory access; callers must provide matching bindings
and buffer sizes. The adapter requests portability extensions for MoltenVK
when the loader reports them. MoltenVK source is vendored, but its binary and
macOS loader setup remain external to the FOO build.

## Goal

FOO source should describe numerical operations in FOO terms while the compiler
selects legal CPU SIMD instructions, GPU execution, or a portable implementation
for the declared target. A native instruction remains available through a
target-checked native contract when the portable operations are insufficient.

Value shape and execution placement are separate decisions. A scalar, vector,
matrix, or tensor describes data and operations; none silently moves data to a
GPU. Choosing a GPU requires an explicit device, buffer ownership, transfer,
kernel launch, and completion dependency. The compiler may remove a transfer
only after proving that the program observes the same result and effects.

## Semantic Contract

- Fixed-width `vector[N, T]` has exactly `N` lanes. A target may use one
  register, several registers, or scalar code. A scalable-vector target such as
  SVE needs a separate length-independent execution model; its runtime lane
  count must not silently change the meaning of `N`.
- Masks are typed lane predicates. `select` and masked memory operations must
  define which lanes are read or written, including fault and bounds behavior.
- Integer overflow, conversion, and indexed access retain FOO's checked
  behavior. Floating-point contraction, reassociation, rounding, exceptional
  values, and mixed precision need explicit modes before an optimizer changes
  their results. A fused multiply-add is a distinct operation unless a selected
  mode permits contraction.
- Gather, scatter, shuffle, and reductions need defined index rules and
  reduction order. Parallel execution cannot invent a deterministic result for
  an order-sensitive reduction without a specified order.
- Host, device, shared, constant, and private memory have explicit ownership,
  lifetimes, visibility, and synchronization. A buffer, image, or texture is a
  resource kind; its location does not follow from its element type.
- A kernel is validated against its declared target capabilities. It may use
  only operations, address spaces, atomics, and call effects available there.
  Workgroup barriers require uniform participation. Launch sizes, streams,
  and scratch memory are explicit controls with checked limits.
- Subgroups are a portable concept with target-dependent size. Portable code
  cannot assume a fixed warp or wavefront width. Lane exchange and reduction
  state their behavior when only some lanes are active.

The following broader vector and kernel sketches are proposed, not executable
FOO today:

```text
constant values of type vector[8, decimal 32] is ...
constant result is values multiply scale plus bias.

kernel calculate(input, output) {
  constant index is invocation.index.
  output[index] is input[index] multiply 2.
}
```

## Compiler Shape

FOO should keep one parser and type system, then extend its typed IR with
explicit vector and parallel operations. Shape and layout specialization happen
before target lowering. The IR must retain address spaces, masks, memory
effects, barriers, atomic orders, launch dimensions, and capability requirements
so neither the C/Zig CPU paths nor a GPU backend can erase a required effect.

The CPU path provides a portable reference implementation and selected SIMD
lowering for AVX2, AVX-512, NEON, and scalable-vector targets where semantics
permit it. A kernel also needs a CPU execution path for testing and fallback.
The first GPU lowering path covers straight-line decimal 32 maps through
Vulkan compute on the hosted C and Zig backends. MoltenVK is vendored for a
future tested macOS path. Backend availability is queried at runtime.

## Roadmap

Implemented CPU baseline: fixed vectors and the vector operations above;
owned row-major decimal `matrix` values with addition, multiplication, column
bias, rectangular transpose, checked rectangular crop, row and column sums,
and elementwise multiplication;
owned row-major
decimal `tensor` values with shape validation, indexed reads, addition,
scaling, elementwise multiplication, explicit trailing-axis broadcasting,
reshape, checked axis permutation, axis crop, axis concatenation, and
checked axis sums. Each reduction returns owned storage and uses zero as the
sum of an empty dimension. Tensor axis sums remove that axis from the result
shape, including a rank-one reduction to a scalar.
`tensor.broadcast` accepts a smaller source rank by treating missing leading
axes as singleton axes. Each aligned source extent must equal its target extent
or be one. The result owns its shape and expanded values; `tensor.hadamard`
requires equal shapes and never broadcasts implicitly.
`tensor.product` multiplies rank-three row-major decimal batches. Equal batch
extents pair directly; a singleton batch broadcasts to the other input. The
inner matrix extents must match, and the result owns its shape and values.
Transforms return independent values that their owners release.
Runtime CPU feature checks and dispatched byte addition are implemented.
Vulkan compute discovery, typed and byte transfers, FOO kernel lowering for
straight-line decimal 32 maps, explicit one-, two-, and three-dimensional
workgroups, local and group IDs, shared decimal storage, unsigned 32 atomic
addition, barriers, capability checks, shader compilation, and synchronous
launch are implemented on hosted C and Zig builds. The C path has been
executed on an Intel Vulkan device; the Zig and macOS paths need hardware runs.

| Stage | Capabilities | Acceptance |
| --- | --- | --- |
| Foundation | Vector types, masks, lane arithmetic, reductions, shuffle, permute, gather, scatter, CPU feature detection, explicit alignment, SIMD loads and stores | Scalar and SIMD results agree on supported targets, including bounds, overflow, masks, and floating-point modes; generated instruction selection is inspected and benchmarked. |
| Advanced GPU model | Software CPU fallback, broader subgroup operations, private memory controls, streams, fences, typed asynchronous transfers, and further device backends | A kernel runs through the CPU reference path and one GPU backend with matching results and checked ownership, synchronization, and capability errors. |
| Compiler | Compile-time vector specialization, automatic vectorization, kernel validation, parallel IR, CPU SIMD lowering, GPU lowering, target capability checking, layout specialization, device optimization | Source is unchanged across supported targets; unsupported operations fail during checking; optimization preserves the semantic contract and reports selected paths. |
| Advanced | Matrix and tensor operations, mixed precision, FP16, BF16, INT8, INT4, matrix acceleration such as AMX and tensor cores, shared-memory tiling, asynchronous pipelines, accelerator abstraction | Operations have explicit shape, precision, accumulation, layout, and resource contracts, with correctness and performance evidence per target. |

Automatic vectorization and placement are optimizations, not promises attached
to a spelling such as `parallel`. CPU threads, CPU SIMD, and GPU execution have
different costs and effects; selection must be visible through build diagnostics
and measurements. Native contracts remain the escape hatch for instructions
that the portable model cannot yet express.

This work shares foundations with persistent storage and networking: type and
layout introspection, generated specialized code, byte views, lifetime checks,
atomics, structured errors, and an effect-aware IR. A capability belongs in FOO
when these projects need the same general operation, rather than when one
application needs a special keyword.
