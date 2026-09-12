# Type Lattice (MVL-1)

## Primitives
- **Integers**: `i8`, `i16`, `i32`, `i64`, `i128`, `u8`, `u16`, `u32`, `u64`, `u128`, `usize`, `isize`. Overflow panics in dev, wraps in release unless `unsafe` math is used.
- **Eval Integers**: `evalint`. Resolved at compile time. Coerces to any integer width fitting the value.
- **Floats**: `f16`, `f32`, `f64`, `f128`. 
- **Eval Floats**: `evalfloat`. Resolved at compile time.
- **Boolean**: `bool` (`true`, `false`).
- **Unit**: `()` (zero-sized, single value).
- **String**: `str` (immutable slice of bytes, guaranteed valid UTF-8 at creation, no null terminator required).

## Composites
- **Arrays**: `[N]T`. Fixed size `N` (must be `evalint`). Stored inline.
- **Slices**: `[]T`. Fat pointer (pointer + length). Bounds-checked on access.
- **Tuples**: `(T, U, ...)`. Heterogeneous, fixed size. Accessed via `.0`, `.1`.
- **Structs**: `struct { field: Type; }`. Fields are zero-initialized by default. Layout is compiler-optimized unless `#[repr(c)]` is applied.
- **Enums**: `enum { A, B = 5, C }`. Backed by the smallest integer fitting all values. No payloads in MVL-1.

## Modifiers
- **Optionals**: `?T`. Represents `T` or `null`. Size equals `T` (null-pointer optimization applied where possible).
- **Errors**: `!T`. Represents `T` or `Error`. Size equals `T` plus hidden error metadata (see `errors.md`).
- **Pointers**: `*T`. Raw, unmanaged pointer. No bounds or null checks. Requires `unsafe` block to dereference or perform arithmetic.

## Functions
- **Type**: `fn(A, B) -> C`. First-class values. Captures are not supported in MVL-1 (no closures).