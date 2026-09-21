# IR

Version: 1. Format identifier: `foo.ir`.

FOO IR carries typed values, control flow, lifetimes and effects independently
of source spelling. The representation stages are **FOO IR → C substrate →
ASM substrate**, marked `@foo`, `@c` and `@asm`. These markers belong to
interchange and native contracts, not ordinary FOO APIs. A stage marker alone
does not constitute a verified lowering.

## Canonical envelope

The UTF-8 JSON envelope contains these required fields:

```json
{
  "format": "foo.ir",
  "version": 1,
  "stage": "@foo",
  "unit": { "package": "example", "path": "main.iv" },
  "requires": "base",
  "target": null,
  "types": [],
  "declarations": [],
  "constants": [],
  "regions": [],
  "traces": [],
  "foreign": [],
  "native": [],
  "residue": [],
  "functions": []
}
```

An optional `storage` table declares file-level mutable values. Each entry has
`name`, a typed constant `value` reference and optional `public`. Its address
is a symbol with pointer type. Initializers must be defined and fit their
declared type. Omitting this table denotes no static storage and preserves the
canonical representation of existing v1 documents.

All fields are required. Capabilities are base, system, machine or hardware.
Only @foo may have a null target; a substrate needs a resolved
[target descriptor](targets.md). Unit paths are relative and cannot traverse
above the package. Host addresses, timestamps and absolute host paths are not
semantic identities.

Canonical output sorts object keys lexicographically, with no insignificant
whitespace. Declaration tables sort by identifier or name. Parameters, fields,
variants, instructions and blocks retain their defined order. The first block
is entry. Unknown fields, operations and versions, duplicate JSON keys and
non-finite JSON numbers are errors.

A compatible reader accepts every valid v1 document. Changing a frozen wire
shape or operation meaning requires a new format version. Source lowering and
optimization must preserve the contract when changing the instruction graph.
`foo ir [file.iv]` writes a canonical document.

Native function contracts retain the existing native-table shape. The open ABI
tag `foo.native:1` identifies a versioned JSON string in `code`, containing
`format: "foo.native"`, `version: 1`, ordered `parameters` names and verbatim
`source`. Its contract ID matches the foreign signature's symbol. Parameter
names must be distinct and match that signature's arity. The optimizer treats
the entire payload as opaque and preserves its unknown effects. Machine
contracts use `machine:OPERATION` ABI tags and explicit typed operands;
atomic operations retain synchronization edges and ordering metadata.

## Types, declarations and constants

A type entry is `{ "id": ID, "definition": DESCRIPTOR }`. TYPE below is a
reference to another type ID. Recursive references are allowed through pointers;
an object cannot contain itself by value.

| Kind | Descriptor fields |
| --- | --- |
| integer | signed Boolean; bits from 1 through 128 |
| decimal | bits, either 32 or 64 |
| bool, unit, error | kind only |
| pointer | element; optional constant and volatile permissions |
| sequence | element; optional constant permission |
| optional, fallible | element |
| array, vector | element; positive width |
| function | parameters array; result; optional ABI |
| record, packed, union | name; ordered fields; optional parameters, width, fieldAttrs and layout |
| choice | name; ordered variants; optional parameters |
| opaque | name; no constructible fields |
| memory, region, trace | token kind only |

A field is `{ "name": NAME, "type": TYPE }`. A variant has the same shape;
its type is null when there is no payload. Field names and variant names are
unique within their declaration. Foreign records carry `layout: "c"`.
Attributes retain their order. Optional type attributes are name, abi,
attributes, volatile and constant where meaningful.

The declarations table maps names to types using `{ "name": NAME, "type": TYPE }`.
Byte and character storage lower to unsigned integers with their validated
source invariants; text lowers to a constant byte sequence. Ownership belongs
to region and operation contracts. Losing a source distinction does not permit
introducing an otherwise forbidden source conversion.

Constants have id, type, encoding and value. Value is always a JSON string:

| Encoding | Meaning |
| --- | --- |
| integer | Canonical decimal integer, with no underscores or leading zeroes |
| bits | Fixed-width lowercase IEEE floating-point bit pattern, including negative zero and NaN payloads |
| text | UTF-8 text represented as a JSON string |
| bytes | Padded RFC 4648 base64 |
| literal | Typed Boolean, unit, named Error, absent optional or explicitly uninitialized storage |

A value reference is exactly one of `{ "constant": ID }`,
`{ "register": ID, "type": TYPE }` or `{ "symbol": NAME, "type": TYPE }`.
Constants are data, never executable source fragments.

## Functions, blocks and SSA

A function has name, params, ret and blocks. Optional fields are public, abi,
attributes, typeParams, derives and line. Public preserves externally visible
symbol identity. Generic typeParams are ordered names; type checking verifies
their source constraints before specialization. Foreign declarations have
name, params, ret and abi, with an optional external symbol.

A block has id, parameters, instructions and terminator. Instructions use
`{ "op": OPERATION, "attributes": OBJECT }`. Results are typed dest references;
operands are typed val, val2, ptr, target, callee, cond, value, expr or args
references as appropriate. Function calls carry func or callee, ABI and an
ordered argument list. Specializations additionally carry typeArgs.

Each register is defined once. Definitions dominate uses. Mutable values use
slots, loads and stores. A phi carries an ordered blocks array of
`{ "label": PREDECESSOR, "value": VALUE }` entries covering every predecessor
exactly once. Block arguments must match the destination parameters on every
edge.

A jump has label and args. A branch has Boolean cond, trueLabel, falseLabel,
trueArgs and falseArgs. A return has an optional value matching the function
result. A panic has a reason and no normal successor. Every block has exactly
one terminator; terminators cannot occur in its instruction list.

## Operations and effects

| Operations | Contract |
| --- | --- |
| add, subtract, multiply, divide, remainder | Typed arithmetic; checked integer operations name a panic successor |
| compare, not | Comparison relation in op, or Boolean negation |
| convert | Lossless numeric widening, readonly view or optional/fallible injection |
| construct, extract | Ordered record/choice construction, named error construction and validated field, tag or result projection |
| index, length | Bounded element projection and element count; address projection is explicit |
| slot, load, store | Typed mutable storage and memory effects |
| region | op is open or close; region identifies the arena |
| allocate | Integer size, region, optional allocator target and fallible byte-sequence result |
| call | Direct or indirect typed invocation with an ABI and effect contract |
| result.value | Error propagation, a trace slot and optional success result |
| result.catch | Conditional success/fallback selection with a validated fallback block |
| trace.append | Error context or propagation-site recording |
| cleanup.register | LIFO cleanup with an always/error condition and validated body |
| vector.splat, vector.shuffle, vector.select, vector.reduce | Fixed lane types, masks and reduction operator |
| embed, reflect, eval | Resource, type or compile-time residue |
| native | A declared opaque contract and substrate hint |
| atomic, thread | Synchronization operations requiring verified target-specific contracts |
| native.zig | Backend-pinned compatibility payload; never portable FOO semantics |
| phi | SSA merge |
| jump, branch, return, panic | Terminators |

A potentially panicking instruction has a panic successor. Its exceptional
edge must not be erased by a transformation. Panic does not promise cleanup.

An effectful instruction has an effects array and
`memory: { "input": TOKEN, "output": TOKEN }`. A terminator consumes the last
token using `memory: { "input": TOKEN }`. Edges forward that token to the
destination block's memory parameter. The conservative memory domain orders
reads, writes, allocation, cleanup, external calls, traces and synchronization.
Unknown native effects cannot be speculated or coalesced.

Source spans, when present, contain file and zero-based UTF-8 byte start/end
offsets, with an exclusive end. Function line metadata is diagnostic context,
not semantic identity.

## Regions and cleanup

Regions have id and kind (scope, managed or static), with optional parent and
owner. Parent links are acyclic. Managed ownership names an allocator value;
it is not silently converted into scope ownership.

A scope allocation requires its region to be open. Ordinary exits run cleanup
in reverse registration order before closing the affected regions. Break and
continue close only scopes being exited. Return closes all local scopes.
Incoming region states must agree at control-flow joins. A returned view must
refer to an argument, managed owner or static storage that outlives the call.

Cleanup may lower directly onto exit paths. Its body cannot return from the
enclosing function, escape a loop, propagate errors or register another cleanup.
An error exit runs both ordinary and error-only cleanup. Catch fallback
evaluation and Boolean and/or remain conditional; they cannot be eagerly
evaluated as ordinary operands.

Trace entries have id and function. Propagation references a trace slot owned
by its function. A trace reference cannot be invented or silently dropped.

## Native contracts and residue

A native entry has id, stage, code, abi and effects. This is an opaque
extern-like residue, not permission to execute arbitrary text. A native
instruction references its entry through symbol. An unresolved payload carries
unknown effects and cannot participate in semantic deduplication.

Before native output, a binding selects the payload dialect, target and
capability. The initial C binding accepts declaration payloads at file scope
and statement payloads in functions. Assembly bindings accept raw assembler
text, emitted as global or volatile inline assembly as appropriate. Native
blocks have no implicit typed FOO captures or results. External interfaces must
use explicit ABI declarations. Inline assembly declares modified registers
through its binding and always has memory and condition-code clobbers. Its
author must preserve the target ABI and must not jump into FOO control flow.
All native blocks retain unknown effects.

Residue entries have id, operation (eval, reflect or embed), state
(pending or resolved) and payload. Pending work must be resolved against its
generic/target/resource dependencies before the corresponding native operation
can execute. Compile-time FOO is not implicitly reinterpreted as C or assembly.

## Semantic equivalence

Semantic keys normalize register names and typed constants. They preserve
nominal identities, field order, permissions, exact floating bits, ABI,
lifetimes and observable effects. Hash equality is followed by complete
normalized-IR equality; a hash collision is not evidence of equivalence.

Deduplication must preserve exported and address-taken function identity.
Checked panic sites, external calls, memory reads/writes, allocation,
synchronization, cleanup and unknown native effects require explicit
equivalence proofs. Arithmetic reassociation and source-text similarity are
not proofs. A pass preserves its input graph and produces a separately
validated result; cached compiler state remains immutable.

Release compilation enables semantic optimization; development compilation
can enable it explicitly. Common subexpressions are reused within effect-free
sections of a basic block. An unknown call, memory operation or synchronization
boundary ends that section. Dead instruction elimination removes only unused,
total, pure values. Small pure callees can be inlined under a weighted IR cost
and per-caller expansion budget; division and aggregate construction cost more
than simple scalar operations. Trapping operations are not moved or merged.

Atomic operations carry an explicit ordering in `field`: relaxed, acquire,
release, acq_rel or seq_cst. Supported operations are load, store, add, swap
and fence. Atomic storage is an integer type with the atomic attribute.
Load and store orderings are restricted to those operations' valid subsets;
every atomic operation participates in the SSA memory chain. Library atomics
also retain synchronization effects when represented as calls.
