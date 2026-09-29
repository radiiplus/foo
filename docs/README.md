# The FOO Book

FOO is a compiled systems language (a language translated before it runs and
suited to low-level software) with sentence-like source code, explicit failure
handling (errors are visible in the program's types), controlled memory, and C
and Zig native backends (code generators that produce programs for the target
machine).

This book has two layers:

- **Learn** pages teach one topic at a time with small examples, expected
  behavior, exercises, and common mistakes.
- **Build and reference** pages explain complete subsystems and provide exact
  contracts for production work.

Machine readers (automated tools such as language models) can use
[`/llm.txt`](https://fooregistry.web.app/llm.txt). It is generated from the
current language, library, project, testing, diagnostic, and platform chapters
on every website build. It deliberately excludes proposals, duplicated
specifications, historical performance reports, and changelog entries.

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

## Learn

Read these lessons in order when FOO is new to you.

1. **[Introduction](intro.md)** - Understand what FOO is designed to do.
2. **[Getting Started](start.md)** - Install FOO and create a project.
3. **[FOO Basics](basics.md)** - Write statements, blocks, comments, and top-level code.
4. **[Variables](variables.md)** - Use constants, dynamic values, inference, and scope.
5. **[Types and Values](types.md)** - Learn primitive, optional, failable, and compound types.
6. **[Operators](operators.md)** - Write arithmetic, comparisons, and Boolean logic.
7. **[Conditions and Loops](flow.md)** - Use `when`, `otherwise`, `match`, `while`, and `for each`.
8. **[Functions](functions.md)** - Define operations, results, public APIs, and generics.
9. **[Expressions and English Grammar](expressions.md)** - Use sentence calls, defaults, overloads, guards, closures, and intentional mutation.
10. **[Language Foundations](foundations.md)** - Understand inference, absence, comparison, generics, modules, memory, effects, concurrency, time, tooling, and design boundaries.

Each lesson ends with a safe experiment. Run `foo check` after each change so
the compiler can explain mistakes before the program is built.

## Build

Use these chapters when creating a real application or package.

11. **[The Language](language.md)** - See the core language as one connected system.
12. **[Collections](collections.md)** - Work with sequences, maps, sets, queues, and stacks.
13. **[Error Handling](errors.md)** - Use postfix `try`, `fallback`, and `after`.
14. **[Modules and Packages](modules.md)** - Organize code and install dependencies.
15. **[Projects and Entry Points](projects.md)** - Configure entries, tests, benchmarks, and builds.
16. **[Data and Memory](memory.md)** - Understand records, regions, ownership, and low-level storage.
17. **[Patterns with Today's Language](patterns.md)** - Build constructors, codecs, state machines, capabilities, transactions, typed time, and properties from current features.
18. **[Systems](systems.md)** - Work with files, networks, processes, C, and the operating system.
19. **[Concurrency](concurrency.md)** - Choose tasks, threads, channels, locks, and atomics.
20. **[The Standard Library](library.md)** - Follow guided examples for common modules.
21. **[Standard Library Index](catalog.md)** - Find all shipped modules by task, compare abstraction levels, and read common API surfaces.
22. **[Packages](packages.md)** - Resolve, lock, audit, and publish dependencies.
23. **[Testing](testing.md)** - Organize assertions, filters, watches, and native fixtures.
24. **[Benchmarking](benchmarking.md)** - Measure programs with warmups and repeated samples.
25. **[Optimization Under the Hood](tuning.md)** - Understand execution specialization, boundary and work elimination, fusion rules, adaptive paths, and measured evidence.
26. **[Performance Report](performance.md)** - Review current measurements, sequence behavior, runtime telemetry, and profiling decisions.

## Master and reference

These chapters describe compiler behavior, target configuration, and the exact
surface of the current language.

27. **[The Compiler](compiler.md)** - Follow source through checking, optimization, and native backends.
28. **[Diagnostics](diagnostics.md)** - Read grouped terminal, JSON, and editor errors.
29. **[Platforms](platforms.md)** - Build for desktop, server, ARM, WebAssembly, and freestanding targets.
30. **[Feature Status](status.md)** - Separate implemented behavior from future design.
31. **[Building Release Binaries](releasing.md)** - Build Windows and Linux compiler binaries, use WSL, sign Linux output, and package platform icons.
32. **[Reference](reference.md)** - Look up commands, vocabulary, and core types quickly.
33. **[Advanced](advanced.md)** - Use allocators, protocol controls, native code, and hardware tuning.
34. **[Syntax Guide](syntax.md)** - Look up complete sentence forms.

## How to read an example

A complete `foo` code block can be placed in an `.iv` source file unless the
text immediately above it says it is only a fragment. Shell blocks contain CLI
commands; JSON blocks belong in `project.json` or `foo.lock` as stated nearby.

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
| Backend | The C or Zig path that produces native code. |
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
[FOO Basics](basics.md).
