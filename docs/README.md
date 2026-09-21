# The FOO Book

FOO is a sentence-like systems language. A `.iv` file is a self-contained compilation unit: its path supplies its namespace, and `public` declarations are the only declarations exported to users of that file. FOO describes intent in readable sentences; the compiler chooses a safe implementation for the target.

This documentation is written as a book. Read it from the beginning when learning FOO, or use the chapter links as a reference after you know the language. Each chapter answers three questions: what a programmer writes, what the program means, and what the compiler is allowed to do underneath.

## Contents

1. [Introduction](intro.md) — the problem FOO is designed to solve.
2. [Getting started](start.md) — installation and the first complete program.
3. [Language](language.md) — declarations, expressions, control flow, and errors.
4. [Data and memory](memory.md) — values, ownership, lifetimes, allocation, and layout.
5. [Systems](systems.md) — files, processes, networking, C, and native code.
6. [Concurrency](concurrency.md) — tasks, threads, channels, and atomics.
7. [Library](library.md) — the standard library and its contracts.
8. [Packages](packages.md) — projects, dependencies, versions, and publishing.
9. [Compiler](compiler.md) — IR, optimization, caching, backends, and the native implementation.
10. [Platforms](platforms.md) — targets, capabilities, and portability.
11. [Reference](reference.md) — the compact language index.
12. [Advanced](advanced.md) — compile-time execution, allocators, kernels, and hardware.
13. [Syntax guide](syntax.md) — one plain-language explanation and example for each syntax form.

The chapters use one sample application, a small line counter, to introduce ideas gradually. You can keep its source in `main.iv` while reading and extend it as each chapter adds a new concept.

Every page identifies whether a feature belongs to the language, library, compiler, or native layer. Technical words are explained when they first appear. Examples are intended to be copied into `.iv` files and checked with `foo check`.

## How to read an example

FOO examples show complete sentences, including their terminating periods and braces. A declaration such as `constant lines is 0.` creates a binding; a statement such as `give lines.` leaves a function. When an example uses a library name, the `use` line is part of the example and is not implied by the surrounding text.

The phrase “underneath” describes an implementation possibility, not an extra syntax requirement. A FOO programmer writes `copy source into destination.`; the compiler may lower it to a checked library call, a C operation, or an instruction selected for the target. The observable result and the documented safety rules remain the same.

## Words you may meet

| Word | Plain meaning |
| --- | --- |
| value | A piece of information, such as `42` or `"hello"`. |
| type | The kind of information a value holds. |
| scope | The part of a program where a name can be used. |
| pointer | A value that tells the program where another value is stored. |
| allocator | A helper that gives out memory and takes it back. |
| backend | The part that turns FOO into a runnable program. |
| native | Code that speaks directly to a computer or operating system. |
| cache | Saved work that lets the next build finish sooner. |

If a chapter uses a word that is not in this table, it explains the word before relying on it.
