# Native interfaces

Version: 1.

Ordinary FOO uses portable declarations and library calls. Native interfaces
require system capability; assembly and machine sentences require machine
capability. A capability never makes an unsupported target operation available.

## Explicit boundaries

`native c { ... }` contains C declarations at file scope or C statements inside
a private function. The C frontend checks that payload. It cannot capture FOO
locals. File-level C symbols need explicit foreign declarations before FOO can
call them.

```iv
native c {
  #include <stdio.h>
  int answer(void) { return 44; }
}
extern "C" function answer() of type integer 32.
```

A named native function binds only its declared parameters and result:

```iv
native c function increment(value of type integer 32) of type integer 32 {
  return value + 1;
}
```

The signature uses the C ABI and accepts only foreign-compatible types. Declare
native functions at file scope; they are private. Public functions may call private implementations through
ordinary FOO signatures, but cannot contain native blocks or expose a native
function declaration directly. The same restriction applies during publishing.

`native { ... }` chooses the portable C interface by default. Advanced project
configuration may select assembly instead. Explicit `native c` and `native asm`
override that default. Both native interfaces work with either compiler backend.
Native operations have unknown effects: the FOO optimizer cannot eliminate,
merge or move them across observable operations.

## Assembly

`native asm { ... }` accepts raw assembly for the selected architecture. Declare
modified registers through `build.native.clobbers`. Raw assembly has implicit
memory and condition-code clobbers and must return normally to its caller.

For parameter/result bindings, use a native function and string constraints.
`result` names its output value; parameters keep their declared names:

```iv
native asm function mirror(value of type unsigned 64) of type unsigned 64 {
  "movq %[value], %[result]"
    : [result] "=r"(result)
    : [value] "r"(value)
    : "memory", "cc"
}
```

This example requires x86-64. The compiler validates operands, constraints and
clobbers. Use [extended assembly constraints](https://gcc.gnu.org/onlinedocs/gcc/Extended-Asm.html)
to describe all inputs, outputs and modified machine state. Clobbers do not
replace synchronization or make native pointer access safe.

## Machine sentences

| Sentence | Meaning |
| --- | --- |
| `atomic add counter by 1.` | Sequentially consistent atomic addition to mutable integer storage |
| `bits set flag at position 4.` | Set a zero-based bit in a mutable integer |
| `bits clear flag at position 7.` | Clear a zero-based bit in a mutable integer |
| `memory align buffer to 64.` | Require the existing address to have this alignment; panic if it does not |
| `register rax is value.` | Write a target register for this operation; its value is not preserved across later statements |
| `call system call 39` | Invoke a direct system call and return its signed machine result |

Atomic and bit updates support 8-, 16-, 32- and 64-bit integers. Bit positions
are checked against the storage width. Atomic storage must not be accessed
concurrently through non-atomic aliases. Alignment requires a positive constant
power of two and a pointer or nonempty mutable sequence; it does not move,
reallocate or release storage.

Direct system calls currently target Linux x86-64, AArch64 and RISC-V. They
accept up to six integer/pointer arguments following `with`, separated by commas.
Numbers, argument meanings and negative error results follow the target kernel
ABI. For example, Linux x86-64 call 39 obtains the process ID. Other operating
systems reject this operation with a target diagnostic; portable programs use
standard-library services. Stack/frame registers and unsupported register names
are rejected.

Legacy backend-pinned `native zig` and string-constraint `asm` forms remain
available to existing private backend code. They do not provide the portable
parameter isolation of the interfaces above and are excluded from public APIs.
