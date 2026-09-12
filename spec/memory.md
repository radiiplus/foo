# Memory Model (MVL-1)

Memory management is strictly three-tiered. Default initialization is **always zeroed**. Uninitialized memory requires explicit opt-in.

## Tier 1: Scope Arenas (Default)
- Every function invocation implicitly owns a "scope arena".
- `alloc[T](n)` allocates `n` elements of `T` from the current scope arena.
- **Deallocation**: Automatic upon scope exit. No `free` is required or permitted for Tier 1 allocations.
- **Escape**: Data allocated in a child scope cannot be returned or stored in a parent scope unless explicitly moved via `share` (MVL-2 feature) or copied. In MVL-1, returning a pointer to a local allocation is a compile-time error.

## Tier 2: Explicit Allocators (Library Authors)
- The `Allocator` trait defines: `alloc`, `free`, `resize`.
- Standard implementations:
  - `page`: Direct OS page allocation.
  - `smp`: Thread-safe general-purpose allocator.
  - `arena`: Bump allocator over a provided buffer.
  - `fixed`: Fixed-size buffer allocator (fails if full).
  - `debug`: Wraps any allocator, tracking leaks, double-frees, and alignment violations (enabled by default in `dev` mode).
- Usage: `let ptr = allocator.alloc[T](n);` followed by explicit `allocator.free(ptr);`.

## Tier 3: Unsafe Raw Operations (Experts)
- Inside `unsafe { }` blocks:
  - Raw pointer arithmetic (`ptr.add(n)`).
  - Manual memory mapping (`mmap`).
  - Custom allocator implementations.
  - Direct address manipulation.

## Initialization
- `let x: i32 = 0;` (Zeroed, default).
- `let x: i32 = uninit;` (Explicitly uninitialized. Reading before writing is undefined behavior. Only permitted in `unsafe` blocks or for specific FFI interop).