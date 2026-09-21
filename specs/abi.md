# ABI

Version: 1. FOO ABI identifier: `foo:1`. Foreign ABI identifier: `c:1`.

An ABI specifies symbol identity, data representation, argument passing and
control transfer. Target selection is part of the contract. Binaries for
different target descriptors are not interchangeable.

## FOO calls

FOO calls use an explicit context, result destination and ordered arguments.
The context identifies the caller's allocation region and trace storage.
This context is a call convention detail; ordinary function declarations do
not contain context parameters.

The physical signature uses the target C procedure-call convention. It returns
an unsigned eight-bit status: zero for success, one for failure. An infallible
function always returns zero. Arguments, in order, are:

1. A non-null pointer to the call context.
2. A pointer to result storage, omitted only for an infallible unit result.
3. Explicit arguments in declaration order.

Scalars with exact target C representations pass by value. All other arguments
pass by a pointer to read-only storage; explicit mutable access passes a pointer
with its declared permissions. Aggregate results always use caller-provided
storage. Fallible result storage is a tag, success storage or Error identity,
and a trace reference. No callee-owned scope storage may escape through it.

Layout follows the selected target's scalar size/alignment rules. Records place
fields in declaration order with alignment padding; their total size is rounded
to the largest field alignment. Sequences and text contain a data pointer and
a target-sized unsigned length. Empty views need no dereferenceable data pointer.
Pointers occupy one target address. A non-C-width integer occupies the next
larger 8/16/32/64/128-bit storage unit with canonical sign or zero extension.
Boolean and byte occupy one byte with alignment one; Boolean values encode as
zero or one. Character occupies an unsigned 32-bit unit. Unit has no payload;
an empty record occupies one byte with alignment one. Where the target lacks a
128-bit C scalar, 128-bit integer storage is 16 little-endian bytes aligned as
an unsigned 64-bit scalar and is passed indirectly.

An optional stores an eight-bit tag, padding, then its value. A choice stores an
unsigned 32-bit tag and an aligned union of payload storage. An implicit choice
tag is its zero-based declaration order; explicit tags must fit unsigned 32.
A fallible stores an eight-bit tag and an aligned success/error payload plus
trace reference. Tag zero means absent/success as appropriate; tag one means
present/failure. Choice tags have no such two-state interpretation.

Error identity is immutable UTF-8 bytes plus length. A trace reference points
into caller-owned trace storage. A call context is two pointers, allocation
region then trace storage. A FOO callable is one entry pointer; there are no
implicit capturing closures. Padding bytes carry no language value and cannot
participate in equality or hashing.
An Allocator value is an operation-table pointer followed by an owner-context
pointer. Its lifetime and permissions remain part of the FOO type contract;
copying these pointers never transfers ownership or extends that lifetime.

Panic never returns a failure status. It terminates execution rather than
unwinding through foreign frames. A conforming executable initializes the root
context before invoking start and keeps it alive through cleanup.

## Symbol identity

A FOO symbol begins with `_F1_`, followed by four length-delimited fields:

1. Package identity: registry name, exact version and content digest; the root
   project uses its name and exact version.
2. Package-relative file path, with `/` separators and the `.iv` suffix.
3. Declaration name.
4. Canonical signature and ordered generic arguments.

Each field is encoded as its UTF-8 byte length in decimal, an underscore, and
twice that many lowercase hexadecimal digits. Empty fields encode as `0_`.
Lengths have no leading zero except zero itself. The four fields are concatenated
without another separator. This encoding is reversible and has no hash
collision assumption. Absolute checkout paths never occur in symbols.

The signature is compact JSON with this fixed field order:
`{"parameters":[...],"result":...,"arguments":[...]}`.
Type descriptions use the canonical descriptors in [IR](ir.md), recursively
expanded for structural types. Nominal types use package/file/declaration
identity instead of recursive expansion. Generic arguments remain in parameter
order. Object keys inside type descriptions follow the order defined there;
strings use JSON escapes without insignificant whitespace.
Signature regions use symbolic parameter positions in first-occurrence order,
starting at zero, or the distinguished static region. Function-local region
IDs cannot occur in an externally callable signature. Package identity is
compact JSON with fixed keys name, version and digest; digest is null for the
root project and the locked content digest for every dependency, including a
local dependency. This encoding also distinguishes local packages with equal
names and versions but different contents.

Private and public FOO declarations use the same identity scheme. Visibility
controls import access, not identity. Separate declarations cannot claim the
same external symbol with incompatible signatures.

## C boundaries

```iv
extern "C" function receive(data of type pointer to byte, size of type unsigned)
  of type integer 32.

extern "C" function answer(value of type integer 32) of type integer 32 {
  give value plus 1.
}
```

A declaration ending with a period imports the exact C symbol. A body defines
that C symbol. C symbols are not FOO-mangled. `public` independently controls
whether another FOO file can name the declaration.

The foreign declaration also accepts `giving T` for its result. Formatting uses
the existing `of type T` spelling. `#[repr(C)]` marks a record or union with the
target C layout; `c record` and `c union` remain supported.

`use c "header.h".` translates the requested header's declarations and required
types. Constant macros become FOO constants; function-like macros are recorded
as wrapper hints. C integer widths come from the selected C frontend's target.
Unsupported varargs, arrays and layouts produce binding diagnostics instead of
silently substituting a different ABI. Generated bindings are cached and are
invalidated by changes to the preprocessed header, frontend or binding options.

C signatures use the target's C ABI directly, without the FOO context/status
parameters. Integers and decimals must map exactly to the target's corresponding
C types; byte maps to unsigned char. Boolean maps to the target C Boolean type.
Pointers retain pointee alignment requirements. Opaque types cross only by pointer.
Text, sequences, Error, optional/fallible values, packed records and vectors do
not cross by value. A named record crosses by value only when a verified foreign
layout contract is supplied by a native interface; ordinary records alone do
not establish that contract.

Function types within extern C signatures denote C callbacks; elsewhere they
denote FOO callables. Both use `function taking (...) giving T`, but their ABI
metadata is distinct. A C callback argument must originate from a matching
extern C declaration. No implicit calling-convention cast is permitted.
C callbacks are single entry pointers and cannot capture a scope.

An exported C-callable body establishes a root context before calling ordinary
FOO functions. It cannot propagate a FOO error through the C ABI: it must translate
failure into its declared foreign result. Retained pointers require an explicit
lifetime contract. Varargs, foreign exceptions and unverified layouts are rejected
at this boundary. This interface requires system capability.
