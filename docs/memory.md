# Chapter 4 — Data and memory

## Values and types

FOO's built-in values include integers, decimals, booleans, text, and `nothing`. Compound values include records, choices, sequences, optional values, fallible values, pointers, and function values.

```iv
record User {
  name of type text.
  active of type boolean.
}

constant person is User { name: "Ada", active: true }.
```

An `optional T` represents either a value or no value. A `fallible T` represents either a value or an `Error`; they are different concepts and compose deliberately.

## Scope storage

By default, FOO gives each block of code a private storage area. You can create a sequence or record without managing that area yourself. Before allowing a value to leave the block, the compiler checks that its storage will still exist. If it cannot prove that, it asks you to change the program.

```iv
function label(value of type integer) of type text {
  constant result is format value.
  give result.
}
```

The returned text must be owned by a region that outlives the function. The compiler may move or copy it when that is part of the proven implementation; the source-level contract is that the returned value remains valid.

## Explicit allocation

Programs that need a known lifetime can use an allocator value implementing the allocator contract:

```iv
constant arena is memory arena.
constant buffer is allocate 1024 using arena.
after { release buffer using arena. }
```

An allocator must say how it gives space, takes space back, lines it up, records who owns it, and reports failure. These rules are its promise to the rest of the program.

## Pointers and layout

The one pointer spelling is `pointer to T`:

```iv
mutable item of type pointer to integer is nothing.
```

Pointers are useful for FFI, explicit layout, and devices. Most application code should prefer a sequence, record, or library handle. Pointer arithmetic, raw addresses, packed fields, volatile access, and alignment control require `unsafe`, `machine`, or `hardware` capability as appropriate.

Records use their normal FOO layout unless an ABI attribute changes it. `#[repr(C)]` requests C-compatible field order and alignment. `#[packed]` removes padding for a deliberately packed representation; reading an unaligned field still requires the correct safe access operation.
