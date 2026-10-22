# The FOO Book

How much code does it take to make a FOO program? The first example below is
one line. Run it, change the message, then follow the lessons as your program
needs names, decisions, functions, and access to the system.

FOO is a compiled systems language with sentence-like source code. It builds
native programs through QBE and makes failures and memory ownership
explicit when those details matter.

QBE is the active native backend. See [QBE backend support](qbe.md) for
qualified targets and current limits.

This book has two layers:

- **Learn** pages teach the language with examples, exercises, and common
  mistakes.
- **Build and reference** pages explain practical workflows. The
  [specifications](../specs/README.md) define exact technical contracts.

Machine readers (automated tools such as language models) can use
[`/llm.txt`](https://fooregistry.web.app/llm.txt). It is generated from the
current language, library, project, testing, diagnostic, and platform chapters
on every website build. It deliberately excludes proposals, duplicated
specifications and changelog entries.

## Hello world

Top-level statements run directly:

```foo
display "Hello, world!".
```

Create and run a project:

```sh
foo new hello
cd hello
foo run
```

FOO also supports an explicit `start` function when an application benefits
from one. It does not require `start` or `give nothing.` for a one-line
program.

FOO uses a small, precise vocabulary. `plus` joins text or adds numbers. Give
a value a name when you need to reuse it:

```foo
constant name is "vibes".
display "Hello, " plus name plus "!".
```

Change the name and run the program again. Each sentence has a defined grammar
that the compiler checks before building it. The [language guide](language.md)
introduces those rules; later chapters cover functions, failures, and memory.

## Learn

Read these lessons in order when FOO is new to you.

1. **[Getting Started](start.md)** - Install FOO and create a project.
2. **[The Language](language.md)** - Learn statements, values, operators, decisions, and loops.
3. **[Functions](functions.md)** - Define operations, use sentence calls, handle failures, and clean up resources.

Each lesson ends with a safe experiment. Run `foo check` after each change so
the compiler can explain mistakes before the program is built.

## Build

Use these chapters when creating a real application or package.

4. **[Collections](collections.md)** - Work with sequences, maps, sets, queues, and stacks.
5. **[Modules and Packages](modules.md)** - Organize code and install dependencies.
6. **[Projects and Entry Points](projects.md)** - Configure entries, tests, benchmarks, and builds.
7. **[Data and Memory](memory.md)** - Understand records, regions, ownership, and low-level storage.
8. **[Patterns with Today's Language](patterns.md)** - Build constructors, codecs, state machines, capabilities, transactions, typed time, and properties from current features.
9. **[Systems](systems.md)** - Work with files, networks, processes, C, and the operating system.
10. **[Concurrency](concurrency.md)** - Choose tasks, threads, channels, locks, and atomics.
11. **[The Standard Library](library.md)** - Follow guided examples for common modules.
12. **[Standard Library Index](catalog.md)** - Find shipped modules and API surfaces.
13. **[Packages](packages.md)** - Resolve, lock, audit, and publish dependencies.
14. **[Testing](testing.md)** - Organize assertions, filters, watches, and native fixtures.
15. **[Benchmarking](benchmarking.md)** - Measure programs with warmups and repeated samples.
16. **[Optimization Under the Hood](tuning.md)** - Review optimization paths and evidence.
17. **[Performance](performance.md)** - Review measured FOO program times and their scope.

## Master and reference

These chapters describe compiler behavior, target configuration, and the exact
surface of the current language.

18. **[The Compiler](compiler.md)** - Follow source through checking and native builds.
19. **[Diagnostics](diagnostics.md)** - Read terminal, JSON, and editor errors.
20. **[Platforms](platforms.md)** - Build for desktop, ARM, WebAssembly, and freestanding targets.
21. **[Feature Status](status.md)** - Separate implemented behavior from future design.
22. **[Building Release Binaries](releasing.md)** - Package and sign compiler releases.
23. **[Reference](reference.md)** - Look up commands, vocabulary, and core types.
24. **[Advanced](advanced.md)** - Use allocators, native code, and hardware tuning.
25. **[Syntax Guide](syntax.md)** - Look up sentence forms.
26. **[QBE Backend Support](qbe.md)** - Review target coverage and qualification evidence.

## Further reference

These pages cover build inputs, runtime and hardware contracts, and project
maintenance:

- [Build Cache](cache.md) and [Linking](linking.md) explain artifact reuse and native inputs.
- [Build Dependencies](dependencies.md) and [Vendored Dependencies](vendor.md) identify tools, assets, and update rules.
- [Runtime](runtime.md), [Freestanding Runtime](freestanding.md), and [Hardware Targets](hardware.md) describe target services and setup.
- [Systems Capabilities](capabilities.md) and [Naming](naming.md) define access levels and repository naming rules.

Proposed systems design work is tracked separately from the current language:
see the [systems capability audit](capabilities.md) and the
[hardware and parallel computation goal](hardware.md).

## How to read an example

A complete `foo` code block can be placed in an `.iv` source file unless the
text immediately above it says it is only a fragment. Shell blocks contain CLI
commands; configuration blocks belong in `project.ivc`, and JSON lock examples
belong in `foo.ivl` as stated nearby.

Examples use the current vocabulary:

- `dynamic` for a changing value.
- `is` for one value and `are` for several values.
- one word for each filename, function, type, and value name.
- `define ... as ...` for a named type.
- `multiply`, `subtract`, and `divide` for arithmetic.
- `stop` and `skip` for loop control.
- postfix `try` for propagation and `fallback` for recovery.
- parenthesized calls as the canonical formatter output; sentence calls are an
  accepted shorthand only where their argument boundaries are unambiguous.
- `file` as the canonical filesystem module.

## Essential terms

| Term | Meaning |
| --- | --- |
| Value | Data such as `42`, `true`, or `"hello"`. |
| Type | The shape and allowed operations of a value. |
| Binding | A name connected to a value by `constant` or `dynamic`. |
| Scope | The region where a name is visible. |
| Module | One `.iv` file and its declarations. |
| Package | A versioned dependency containing one or more modules. |
| Failable | Able to return a typed failure instead of a success value. |
| Ownership | Responsibility for keeping and eventually releasing a resource. |
| Backend | The QBE path that produces native code for currently supported targets. |
| Native code | Instructions built to run directly on a chosen processor and operating system. |
| Runtime | Support code and services used while a compiled program is running. |
| Compiler | The tool that checks FOO source and translates it into an executable. |
| ABI | Binary rules that let separately compiled code call functions and exchange data. |
| Allocation | A request to reserve memory for data. |
| Inlining | Replacing a function call with the function's body during compilation. |
| Serialization | Turning a value into text or bytes that can be stored or sent. |
| Concurrency | Making progress on more than one piece of work during the same period. |
| Deterministic | Producing the same result from the same inputs. |
| Cache | Saved compiler work reused when its inputs remain valid. |

Start with [Getting Started](start.md), then continue to
[The Language](language.md).
