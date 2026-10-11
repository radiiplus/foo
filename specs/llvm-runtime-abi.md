# FOO runtime ABI v1

`foo.runtime.pointer.v1` is the LLVM-to-runtime boundary, distinct from the
platform's native C ABI. FOO bodies and their control flow are LLVM IR. Existing
runtime providers and native services are compiled as C; they are not replaced
by new stub implementations. No C adapter may interpret a FOO function body.

## Calling and representation

An imported operation has `void bridge(void *out, const void *p0, ...)`.
Each input points to an addressable value, and a non-void output points to
caller-owned storage of the result's complete size. Inputs are borrowed for the
duration of the call; the adapter copies their values before invoking a native
provider. Void outputs pass null. The caller provides valid storage, including
for failed operations. Adapters never assume LLVM aggregate parameters/returns
have the same register or stack assignment as Clang's C ABI.

The reciprocal `foo_llvm_gate_<hex-name>` has the same pointer convention. A
typed native callback/export compiled by Clang calls that gate. This handles
native calling conventions, aggregate returns and callbacks through one
marshalling rule. Internal direct FOO calls remain internal LLVM calls.
Indirect calls pass through a typed native adapter. Calling convention names
are validated, never guessed; x64 Windows uses the platform's unified ordinary
C/system/stdcall convention, with vectorcall explicitly delegated to Clang.

Public foreign exports keep their declared symbol spelling and are marked for
export on Windows. Language-private functions are not implicitly DLL exports.
Bridge names are compiler-owned. C import symbol names are validated before
generation. Arbitrary library addresses must have the declared foreign
function type; code and data addresses are not interchangeable.

The currently qualified layout is little-endian Windows x64, with eight-byte
pointers. Target triple/data layout and tool versions belong in build/cache
identity. `layout.nim` measures addressable layouts and the generated C runtime
checks sizes, alignments and record field offsets with static assertions.
Booleans occupy one byte in memory. Integers have a semantic width distinct
from their rounded 8/16/32/64/128-bit storage. Text/bytes are `{data, length}`;
text lengths are bytes, not Unicode scalar counts, and embedded zeros are not
terminators. Generic sequence lengths count elements. A failable value contains
an error identity pointer followed by its aligned payload; null means success.
Only the active payload is read. Native `FooResult` remains the existing
service result, translated by a runtime adapter into the typed FOO result.

## Ownership, cleanup and failures

Ownership is determined by the existing library/provider contract, not by
pointer ABI spelling. Returned owned buffers/handles must be released through
their matching provider. A view is borrowed and cannot outlive its owner.
Transfers invalidate the sender according to the frontend's ownership checks;
adapters do not duplicate ownership. A successful close consumes its resource;
the existing runtime decides repeated-close and failed-close behavior.
Allocation uses the existing allocator and registry. Region allocations are
freed by region close; scoped cleanup runs in reverse registration order on
normal and error paths. A provider is responsible for partial failure cleanup.
Shutdown runs after the entry result is observed and after language cleanup.

Error identity is preserved as the provider's stable error string. Issue trails
remain the existing bounded, nonallocating, thread-local frames; propagation
must not allocate, replace identity, or read an inactive result payload. Panic
is nonreturning; abort and explicit process exit are ordering barriers and keep
their existing cleanup behavior (abort does not promise normal shutdown).

Callbacks crossing threads/tasks use native thunks, never raw internal LLVM
aggregate-call addresses. The scheduler retains its existing ownership of
handoff contexts, cancellation state, timers and joins. Callback arguments and
resources cannot be released until their documented completion/join boundary.
Borrowed callback state cannot escape a synchronous call unless the source
contract explicitly permits it. GPU buffers, transfers, dispatch and fences
retain their existing Vulkan ownership and completion contracts; kernel
compilation remains direct SPIR-V, separate from host LLVM lowering.

## I/O and platform policy

Each operation keeps its own result and source issue slot. An operation may be
coalesced only with a proof that handle identity, byte ordering, partial-write
behavior, failure injection, observable errors and task interactions are
unchanged. `sync`, `replace`, reads following writes, locks, spawn/exit/abort,
stdout/stderr changes, and cross-task/thread boundaries are barriers.
Unknown effects are barriers. No implicit deferred error or success is allowed.

Batching starts disabled. Explain reports must describe accepted and rejected
candidates and the gate policy; a threshold is not an optimization proof.
Failure-injection and crash-consistency runs must retain a synchronous,
nonbatched path. Linux must probe io_uring at runtime and retain a synchronous
or readv/writev fallback when unavailable or restricted. Windows must use only
already-supported overlapped/IOCP paths; IoRing availability is not assumed.
macOS defaults to portable paths. Platform failures must remain real provider
errors, not fabricated successful no-ops.

Platform and service qualification is tracked by executable tests; this ABI
document does not certify untested platforms or hardware/GPU devices.
