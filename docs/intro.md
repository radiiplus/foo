# Chapter 1 — What FOO is

FOO is for programs that need both a readable surface and control over resources. It treats ordinary code as a conversation about values and operations, then gives progressively more control when an application reaches the operating system or hardware.

## A small language with a long reach

The first useful FOO program is deliberately ordinary:

```iv
function answer() of type integer {
  give 42.
}

start() {
  constant value is answer().
  display value.
  give nothing.
}
```

The function has a name, parameters if it needs them, a result type, and a body. `give` makes the result explicit. `start()` is the entry point. There is no module wrapper because the file is already a compilation unit.

FOO does not ask a beginner to choose an allocator, an ABI, a calling convention, or a CPU instruction. Those choices belong to later layers. When they become necessary, the language makes the boundary visible instead of silently changing the meaning of ordinary code.

## Intent and implementation

Consider a copy:

```iv
copy source into destination.
```

This sentence establishes the semantic operation: destination receives the bytes represented by source, subject to the memory contract of both values. The compiler can select a safe overlap-aware routine, a vectorized implementation, or a platform intrinsic. A target change may therefore change the generated instructions while leaving the FOO source unchanged.

The distinction matters. FOO syntax is not Zig syntax, C syntax, or an assembly dialect. Those are substrates used after semantic analysis. A program should remain understandable when read without knowing which substrate was selected.

## Four layers

Language features define meaning. Library features package useful operations. Compiler features select and verify an implementation. Native features expose a platform deliberately. The same feature can be explained at each layer without mixing their vocabularies:

| Layer | Question it answers | Examples |
| --- | --- | --- |
| Language | What does this program mean? | `function`, `when`, `fallible` |
| Library | How do I perform a common task? | `file read`, `sequence sort` |
| Compiler | How should this target execute it? | caching, inlining, `-mcpu` |
| Native | How do I cross a platform boundary? | `native c`, registers, interrupts |

## The learning path

Start with declarations, values, and control flow. Add records, sequences, and errors before learning allocation. Use the standard library for files and networking before writing native code. Learn concurrency after ownership and errors are familiar. Finally, use the native layer for a measured requirement: an ABI, a device, an instruction, or a platform facility.

This order is not a restriction on experienced systems programmers. It is a way to keep the common path small while retaining a complete path to the machine.

## What FOO feels like

FOO sentences are meant to be read aloud. A reader can usually tell whether a line creates a name, calls an operation, chooses a path, or returns a result.

```iv
constant name is "Ada".
display name.
```

The first line gives a name a value. The second line asks the output library to show it. The compiler checks the types and lifetime without changing the way the sentence reads.

## What FOO is not

FOO is not a collection of hidden shortcuts for C, Zig, or assembly. Those tools may produce the final program, but they stay behind a boundary. A small command-line tool and a device driver are both FOO programs; each uses only the features it needs.
