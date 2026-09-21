# Consolidation

Version: 1.

The following forms are excluded from FOO v1. Each replacement communicates one
defined concept. Distinct width parameters, import aliases and error-specific
cleanup conditions are meaningful parameters, not alternate names for one type.

| Removed form | Canonical form | Reason |
| --- | --- | --- |
| `module name { ... }`, namespace blocks | File-level declarations | Package and file path define the boundary |
| `address to T` | `pointer to T` | Same pointer semantics |
| `reference to T` | `pointer to T` | No separate reference type |
| `array of T` | `sequence of T` | One bounded sequence view |
| `function(A, B) of type C` | `function taking (A, B) giving C` | One callable type syntax |
| `[T: Ord]` | `[T]` with `where T is Ord` | One sentence-like constraint clause |
| `#[derive(Equatable, Hash)]` | `derives Equatable, Hash` | Derivation belongs to the type declaration |
| `equals` | `is` in an expression | One equality operator |
| `does not equal` | `is not` | One inequality operator |
| `is less than`, `is greater than` | `less than`, `greater than` | One comparison spelling each |
| `is at least`, `is at most` | `not (a less than b)`, `not (a greater than b)` | Avoid duplicate ordered comparisons; valid for totally ordered operands |
| `value[index]` | `value at index` | Indexing is separate from type arguments |
| Bare action calls such as `display value.` | `display(value).` | One call grammar, including calls within expressions |
| Bare `give.` | `give nothing.` | Unit is an explicit value |
| `on leave call.`, `on leave { ... }` | `after { ... }` | One cleanup construct |
| `repeat until n reaches limit` | `while n less than limit` | Counter repetition uses ordinary loop semantics |
| `advance n.` | `set n to n plus 1.` | Mutation has one assignment statement |
| `native zig { ... }`, standalone `asm { ... }` | `native { ... }` | Substrate selection belongs to a verified native contract |
| `use "c" function ...`, `use c "header.h".` | `extern "C" function ...` and native-interface dependencies | One explicit foreign boundary; header tooling is not ordinary source syntax |
| `use "provider" function ...`, including runtime-prefixed providers | Typed public FOO declarations and native interfaces | No implementation provider in ordinary APIs |
| `for c` on function declarations/types | `extern "C" function ...` declaration metadata | One place to specify the foreign ABI |
| `c record`, `c union`, `#[repr(c)]` | Verified native-interface layout metadata | Foreign representation does not create ordinary FOO type aliases |
| `#[start]` | `start()` | Entry discovery selects a declared start, never an arbitrary function |
| `#[interrupt]`, `#[naked]`, `#[volatile]`, `#[target_feature(...)]` | Native contract effects and target requirements | Machine/hardware requirements stay at their boundary |
| `evaluate` | `eval { ... }` | One compile-time declaration form |
| `embed[T]("path")` | `embed("path")` | Embedded resources have one byte-sequence result type |
| `expression context "message"` | Error identity and trace contract | No second error-chaining operator |
| Unit-suffixed numeric literals | Ordinary library quantity constructors | Sizes and durations are library values |
| `integer 64`, `unsigned 64`, `decimal 64` | `integer`, `unsigned`, `decimal` | Canonical default-width spellings |
| Target aliases `linux`, `windows`, `darwin`, `aarch64-freestanding` | Explicit target names in targets.md | Architecture is part of target identity |
| Raw target triples and build backend selection | Versioned target descriptor | Configuration expresses required behavior |
| `registry+name@version` dependency strings | Named dependencies with exact/caret versions | Registry identity comes from the dependency name and configured registry |

Text `\n` remains a literal escape needed for interchange; formatted text
expressions use `newline`. This is a lexical encoding rule, not a second line
break value. Block and documentation comments retain distinct structural roles.

Unit nothing and optional absence share a literal with an explicit contextual
conversion, not separate null/nil spellings. Byte, character and text are distinct
semantic types, not numeric or sequence aliases. The full rules are in
[grammar](grammar.md) and [types](types.md).

Cleanup has one explicit exception: cleanup and finally are accepted aliases
of after. Formatting emits after for all three, including after error. The
former defer and on leave forms are excluded. Import aliases also preserve a
meaningful distinction: an aliased import exposes only qualified member access.
