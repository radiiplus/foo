# Chapter 9: The Compiler (From English to Machine Code)

You have been writing beautiful, English-like sentences, but computers don't speak English. They speak machine code (1s and 0s). 

The FOO compiler parses and checks source, lowers it to an intermediate form,
and asks the selected backend to produce code for the requested target.

Let’s look at the three-step magic trick the compiler performs.

---

## 1. The Three-Step Pipeline

When you run `foo build`, the compiler goes through three distinct phases:

### Step 1: Parse & Check (The Proofreader)
First, the **Parser** reads your sentences and builds a grammar tree. Then, the **Type Checker** (the "Bouncer") verifies that your logic is sound. 
*   *Can you add text to a number?* No.
*   *Did you handle the error?* Yes.
If parsing or checking fails, compilation stops before the program runs.

### Step 2: Lower to IR (The Blueprint)
Once your code is proven safe, FOO lowers it into an **Intermediate Representation (IR)**. Think of this as a strict, simplified blueprint of your program. It strips away the "English" words and converts everything into pure logic. 
This is where FOO applies sealing checks for supported ownership, lifetime, and
ordering contracts. The checker rejects violations it can prove; native code
still has to honor its declared contract.

### Step 3: Emit & Optimize (The Factory)
Finally, the compiler takes that blueprint and translates it into a language your computer can actually build: **C** or **Zig**. 
It also applies semantics-preserving optimization (speed improvements that do
not change the program's meaning) and selects runtime paths that
are compatible with the declared target and CPU profile.

---

## 2. Multiple Backends: C and Zig

FOO is unique because it doesn't just target one backend (code generator). It can translate your code into two of the most powerful systems languages in the world.

### The C Backend (Universal)
Select the C11 backend with `--backend c`.
**The Benefit:** C runs on everything. If you want your FOO program to run on a massive cloud server, a Raspberry Pi, or a legacy Windows machine, the C backend is your best friend.

### The Zig Backend (Modern Speed)
FOO uses the Zig backend by default.
The managed Zig toolchain provides the default native build and cross-target
path. Generated code still follows FOO's checked semantics; choosing this
backend is not a separate language safety mode or a performance guarantee.

```sh
# Build using the C backend
foo build --backend c

# Build using the default Zig backend
foo build
```

---

## 3. Optimization (`opt`): The Hardware Tuner

FOO's optimizer preserves one source-level contract while choosing compatible
implementations for the selected target. Generic types are specialized (turned
into versions for exact types) before
emission, repeated pure decimal expressions can be shared, and unused pure
results can be removed. Checked integer arithmetic, failures, cleanup, I/O,
volatile access (reads and writes that must happen exactly as written), and
atomics (shared operations completed as one step) keep their observable behavior.

FOO calls the broader rule **execution specialization**. For each operation,
the compiler considers exact build-time facts, values only known while the
program runs, and capabilities promised by the selected target. It first asks
whether the operation, temporary value, allocation, copy, or boundary is needed
at all. Only then does it choose a faster implementation.

For example, postfix `try` remains ordinary typed success/failure control flow.
The backend can test and propagate the error without an exception runtime, but
it must still preserve the error value, trace, and cleanup. Generic
specialization similarly removes runtime type selection when the exact type is
already known.

Runtime byte transfer is adaptive (it selects an implementation from the known
conditions). AVX2 (processor instructions that handle several bytes at once)
handles the measured 128 through 256-byte range on a matching x86-64 release
target. A machine-capability x86-64 build may use `rep movsb` (an x86 instruction
for copying a block of bytes) for non-overlapping transfers from 1 KiB through
8 KiB. AArch64 and Zig use their selected overlap-safe paths; unsupported sizes
and targets retain the portable implementation. Hosted C task pools use IOCP
(Windows completion events) on Windows and epoll/eventfd (Linux readiness and
wake-up services) on Linux; scoped tasks, Zig, and other targets use the
threaded fallback. Socket readiness (whether network work can proceed) and
suspended continuations (saved work that will resume later) are not yet attached
to those event queues.

The optimizer also reviews **boundaries** between functions, allocations,
representations, libraries, schedulers, serialization buffers, and the
operating system. It currently removes redundant conversions, block-local
non-escaping stack slots, adjacent private pure call boundaries, and proven
synchronous task callbacks. Typed scalar and record codecs generate direct JSON
field code. Effectful loop fusion, cross-block storage placement, and suspended
continuation frames remain design work because their failure, cleanup,
ownership, scheduling, ABI (binary rules between compiled components), and
wire-format contracts (the exact bytes used when data is stored or sent) need
broader proofs.

See [Optimization Under the Hood](tuning.md) for the selection hierarchy,
boundary and fusion rules, required implementation review, semantic limits,
cache inputs, and benchmark requirements.

---

## 4. Caching: The Time Machine

You know how rebuilding a project can sometimes take minutes? FOO hates waiting.

FOO uses a build planner (the component that orders build work) and two cache
levels. The project cache reuses a whole
artifact (generated build output) only when the project, backend, target, CPU,
options, and compiler
inputs still match. Zig's shared cache can reuse lower-level backend work across
projects. A changed input invalidates the affected cache identity; FOO does not
claim source-file incremental linking (rejoining only changed compiled pieces)
where the backend cannot provide it.

Internal generated files and cache metadata stay in `.artifacts/`. After a
successful build, FOO publishes only the completed app or library into
`target/`, or the project-relative directory selected by `build.output`. A
cache hit recreates a missing published product without recompiling it.

### Adaptive build paths

FOO uses one operation interface for builds, runs, package changes, publishing,
and toolchain setup. It shows real source files and stages, an activity flow,
elapsed time, and a final summary. The activity blocks show that work is moving;
only a finished operation displays `100%`. Add `--explain` when paths, digests,
registry endpoints, and other diagnostic context are useful.

Build operations also show the active build path and the number of jobs
available. Ordinary development builds use the fast path and leave CPU and
memory headroom for the rest of the system. Native interop, extra native
sources, safety checks, custom linking, and release optimization select a
compatibility or optimized path. Those paths use a higher job limit and briefly
state why they were selected.

Zig builds share reusable compiler data across FOO projects. Finished project
artifacts use a separate project cache; an unchanged build reports that it was
reused and skips compilation. Set `FOO_BUILD_JOBS` when a machine needs an
explicit worker limit.

---

## 5. Native Interop (calling non-FOO code): The Escape Hatch

Sometimes, standard code isn't enough. Maybe you need to talk directly to a graphics card, or use a specific CPU instruction.

FOO exposes foreign declarations and verified native contracts for operations
that the portable language or standard library cannot express.

```foo
extern "C" function add(left integer, right integer) giving integer.
```

The declaration gives FOO a checked call signature. The linked native symbol
must obey that ABI and signature; `foo bind` can generate declarations from a C
header.

---

## Summary: The Compiler Philosophy

The FOO Compiler is designed to be your **Safety Net** and your **Speed Demon**. 
*   It catches your mistakes before you run the code.
*   It removes provably unnecessary work before making remaining work faster.
*   It specializes compatible paths for your target without changing semantics.
*   It gives you the choice between the universality of C and the modern speed of Zig.

In the next chapter, we will look at **Platforms**, where we will learn how to build FOO programs for Windows, Mac, Linux, and even the web!
