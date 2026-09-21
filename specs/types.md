# Types

Reflection produces an immutable description with name and kind as text, and
size and alignment as unsigned 64-bit values. Names use FOO type vocabulary.
Sizes and alignments describe the selected target, not the compiler host.

Version: 1.

Types express values, representation requirements, effects and lifetimes.
Equal storage sizes do not make two types interchangeable. Type aliases name an
existing type; records, choices and opaque declarations establish nominal types
identified by package, file and declaration.

## Values and the type lattice

| Type | Values and contract |
| --- | --- |
| `nothing` | Unit, with exactly one value, also written `nothing` |
| `boolean` | `true` or `false`; never implicitly numeric |
| `integer` | Signed 64-bit integers |
| `integer N` | Signed N-bit integers |
| `unsigned` | Unsigned 64-bit integers |
| `unsigned N` | Unsigned N-bit integers |
| `decimal` | Binary64 floating-point values |
| `decimal 32` | Binary32 floating-point values |
| `byte` | An opaque eight-bit storage unit; arithmetic requires conversion |
| `character` | One Unicode scalar, excluding surrogate values |
| `text` | Immutable validated UTF-8 text with a byte length |
| `sequence of T` | A bounded contiguous view of T elements with a lifetime |
| `pointer to T` | A non-null, aligned address of a T with provenance and a lifetime |
| `optional T` | An absent value or a present T |
| `fallible T` | A successful T or an Error with its trace |
| `function taking (A, B) giving C` | A callable signature |
| `Error` | An open error identity; see [errors](errors.md) |
| `Allocator` | A managed allocation capability; see [memory](memory.md) |

Integer widths are 1 through 128. Width 64 uses the bare numeric name in
canonical source; `integer 64`, `unsigned 64` and `decimal 64` are not separate
accepted spellings. Byte remains distinct from `unsigned 8`, and character
remains distinct from `unsigned 32`.

The semantic lattice has an uninhabited bottom type, never, for expressions that
cannot return, such as unreachable or propagation of an unconditional failure.
Never is not a source type spelling. Unit is not bottom.
There is no universal implicit top type, implicit boxing or truthiness.

Permitted implicit conversions are:

1. An integer literal to a numeric type that represents it exactly.
2. A numeric value to a wider type only if every source value is representable.
3. T to `optional T`, as present, and T to `fallible T`, as success.
4. A unit literal to `optional T`, as absent; this rule has priority over
   present-value conversion when T itself is nothing.
5. A value of bottom type to any required type, and region weakening from a
   longer valid lifetime to a shorter one.

Numeric-to-Boolean, text-to-byte-sequence, pointer-to-integer, narrowing and
lossy integer-to-floating conversions are never implicit.
Explicit conversions are ordinary library calls and are fallible when their
input can be invalid. There is no source cast operator.

An unconstrained integer literal defaults to integer and an unconstrained
decimal literal defaults to decimal. An integer literal outside that default
range needs an expected representable type; it is not silently truncated.
Decimal literals round to the nearest representable value, ties to even, in
their expected floating type. They do not implicitly become integers.
Arithmetic first applies an expected type to literals, then requires matching
operand types or a unique least common type under the lossless numeric
conversions above. Ambiguous or unrepresentable combinations require an explicit
library conversion. Boolean operators accept only Boolean values.

Lifting does not reorder wrappers: `optional fallible T` and
`fallible optional T` differ. There is no implicit unwrap.
A present unit requires explicit construction through the option library;
`nothing` in an expected optional type always denotes absence.
Error values are ordinary values; only `fail(error)` constructs a failure.

Signed arithmetic overflow, division by zero, invalid indexing and invalid
conversions through unchecked operations panic. Unsigned arithmetic is checked
too; wrapping operations require explicit library calls. Integer division
truncates toward zero. Remainder satisfies
`a is (a divided by b) times b plus (a remainder b)` when representable.
Floating-point arithmetic follows the selected precision, including NaNs and
signed zero; algebraic rewrites must preserve those observable semantics.

## Records, choices and views

```iv
type Person is record {
  name of type text.
  age of type unsigned 32.
} derives Equatable, Hash.

type Message is choice {
  Data(text).
  Closed.
}.

type Handle is opaque.
type Visitor is function taking (pointer to Handle, integer 32) giving nothing.
```

Record constructors supply one value per field in declaration order.
Choice variants carry zero or one payload; a record groups multiple payload
fields. A choice value is always tagged. Plain records have no foreign layout
guarantee. An opaque value has no accessible size or fields and is used only
through a pointer or a library-owned handle.

Sequences are views, not allocators. Their element count is part of the value,
not the type. Indexing uses a nonnegative integer and checks the count.
A sequence cannot outlive its storage. A text value is not an arbitrary binary
buffer. Text indexing is deliberately absent; Unicode iteration is a library
operation. Mutating a sequence requires a mutable, unaliased write permission.

Pointer identity includes the allocation it came from. Raw address arithmetic,
alignment changes and provenance removal require unsafe or native access.
Ordinary code cannot fabricate a pointer from a number. Nullability is expressed
only by `optional pointer to T`.

## Functions and constraints

```iv
function choose[T, U](left of type T, right of type U)
  of type T where T is Equatable, U is Hash {
  give left.
}

type Box[T] is record { value of type T. } where T is Equatable.
```

Generic parameters are introduced only in square brackets. Constraints appear
only in where clauses and combine by conjunction. Every constrained name must
be a parameter of that declaration. Duplicate clauses and unknown capabilities
are errors. Specializations are identified by the declaration and ordered
concrete type arguments; inference must find a unique substitution.

The v1 constraint vocabulary is Equatable, Hash, Ord and Allocator. Equatable supplies equality,
Hash supplies equality-consistent hashing, and Ord supplies a total ordering.
Allocator supplies allocation and lifetime control. A capability can be satisfied
only by its specified operations and laws, not by a matching name. User-defined
capability declarations are outside this grammar. Derivation supports Equatable and
Hash for records/choices whose components meet the corresponding requirements.

Function types use only `function taking (...) giving T`. Parameter names are
not part of a function type; argument order and result type are. Parameter types
are invariant; calls do not guess adapters or discard errors.
Calling-convention metadata is retained as specified in [ABI](abi.md), without
introducing a second function-type spelling.

## Representation-sensitive types

`packed record` and `vector[n, T]` require hardware capability.
Packed fields are unsigned/signed integers, booleans, bytes or nested packed
records, laid out in declaration order. No field may contain a pointer.
Packing is a bit-layout contract, not a promise of compatibility with a foreign
compiler's bitfield rules.
The first field occupies the least significant available bits of the first byte;
subsequent bits advance toward higher bit positions and then higher byte
addresses. Integer fields use their declared width, Boolean uses one bit, byte
uses eight, and nested packed records contribute their field bits without
intermediate padding. Signed fields use two's complement. Total size is rounded
up to bytes, alignment is one, and unused final bits are zero in canonical
serialization. An ordinary pointer cannot address a field lacking its required
byte alignment. An empty packed record has size one and no value bits.

Vectors have a positive constant lane count. Arithmetic requires matching
numeric lane types and is lane-wise; comparisons produce Boolean lanes.
Splat, shuffle, select and reduction are library-facing operations with checked
signatures. Vector register layout is not a foreign ABI contract. Hardware
operations require a compatible target in addition to the capability level.
