# Grammar

Version: 1. Source extension: `.iv`. Text encoding: UTF-8.

A file is one compilation unit. Its namespace is its package identity and
package-relative path. Declarations appear directly in the file; there are no
module declarations or namespace blocks. `public` exposes a declaration.
Imports bind namespaces as specified in [packages](packages.md).

## Lexical rules

Identifiers use ASCII letters or `_` initially, followed by ASCII letters,
digits or `_`. They are case-sensitive. A quoted alphabetic terminal below is
a reserved word; capitalized type and capability names are identifiers.
The cleanup words after, cleanup and finally have identical meaning. After is
the canonical spelling emitted by the formatter; the other two are explicit
accepted aliases. Defer and on leave are not cleanup syntax.
Whitespace and comments separate tokens but do not end statements.

`--` starts a line comment. `--- ... ---` is a non-nesting block comment.
`--!` and `---! ... ---` mark documentation comments. The longest comment
opener wins. An unclosed block comment is an error.

Integers are decimal digit sequences. An underscore may occur only between
digits. A decimal literal consists of an integer part, a dot, and a fractional
digit sequence, optionally separated by underscores. There are no leading signs,
base prefixes or exponents. Subtraction expresses negative values.

Text uses double quotes; characters use single quotes. Neither crosses a
physical line. Supported escapes are `\n`, `\r`, `\t`, `\0`, `\\`, and the
matching escaped quote. A character decodes to exactly one Unicode scalar.
`newline` is a text value containing U+000A; formatted text uses it for line
breaks.

A decimal literal consumes its fractional dot before punctuation is considered.
Otherwise a dot immediately followed by an identifier with no intervening
whitespace is a MEMBER token. Every other dot is a STOP token. Thus
`account.name` selects a member and `give account. next().` has two statements.
A dot followed by a reserved word is not a member selector.

The names `text` and `sequence` are contextual library identifiers outside type positions. Sentence calls are contextual as well: their linking words do not introduce additional reserved identifiers. Parenthesized arguments and bracketed type arguments retain their existing meaning.

| Sentence | Call arguments, in order |
| --- | --- |
| copy source into destination | transfer(source, destination) |
| compare left with right | compare(left, right) |
| clear buffer; display content; trim content; sort items | the named function with one argument |
| length of content; current time | length(content); current() |
| read line from stream | line(stream) |
| read line | line(input()) |
| read file path; open file path | read(path); open(path, "read") |
| write file path with content | write(path, content) |
| create directory path | directory(path) |
| read from stream with size; receive from connection with size | read(stream, size); receive(connection, size) |
| write content to stream; send content to connection | write(stream, content); send(connection, content) |
| connect to host with port; listen on host with port | connect(host, port); listen(host, port) |
| accept connection listener | accept(listener) |
| run command content | run(content) |
| get argument index; get environment variable name | argument(index); environment(name) |
| spawn task function; wait for task | spawn(function); wait(task) |
| lock mutex value; signal condition value | lock(value); signal(value) |
| sleep for duration; measure duration function | sleep(duration); measure(function) |
| concatenate left with right; join left with right; split content with separator | the named function with both arguments |
| append value to items; remove at index from items | append(items, value); remove(items, index) |
| find value in items | find(items, value) |
| filter items with predicate; map items with transform | the named function with both arguments |
| log message content; log error content | log.message(content); log.error(content) |

The formatter prints the corresponding call form. A sentence argument includes arithmetic and comparisons; use parentheses to delimit an argument before applying an operator to the call result. `catch` binds to the complete sentence call. Commas, closing brackets, braces, statement stops and physical newlines delimit sentence calls. Linking words shown in the table are required. A qualifier is preserved when a sentence changes the operation name, such as `io.read line` selecting `io.line`.

After `native`, the next opening brace begins a NATIVE token. It includes a
balanced brace-delimited payload. Braces inside single/double quoted strings,
`//` line comments and non-nesting `/* ... */` comments do not affect balance;
backslash escapes the next character inside a quote. Unclosed quotes, comments
or braces are errors. This framing is independent of payload semantics.

## EBNF

Quoted text denotes a terminal; braces mean repetition, brackets mean an
optional production, and `|` separates alternatives. IDENT, INT, DECIMAL, TEXT,
CHAR, MEMBER, STOP, NATIVE and EOF are the lexical tokens defined above.

```ebnf
File         = { Top }, EOF ;
Top          = Import | Entry | Test | Eval | Native | [ "public" ], Definition ;
Definition   = Function | Constant | Mutable | Alias | Foreign | NativeFunction ;
Import       = "use", ( IDENT | TEXT ), [ "as", IDENT ], STOP | "use", "c", TEXT, STOP ;
Entry        = "start", "(", ")", Block ;
Test         = "test", TEXT, Block ;
Eval         = "eval", "{", { Constant | Alias }, "}" ;

Function     = "function", IDENT, [ Parameters ], "(", [ Formals ], ")",
               [ Result ], [ Bounds ], Block ;
Parameters   = "[", IDENT, { ",", IDENT }, "]" ;
Formals      = Formal, { ",", Formal } ;
Formal       = IDENT, "of", "type", Type ;
Result       = "of", "type", Type ;
Bounds       = "where", Bound, { ",", Bound } ;
Bound        = IDENT, "is", Name ;
Foreign      = "extern", TEXT, "function", IDENT, "(", [ Formals ], ")",
               ( Result | "giving", Type ), ( STOP | Block ) ;
Native       = "native", [ "c" | "asm" ], NATIVE ;
NativeFunction = "native", [ "c" | "asm" ], "function", IDENT,
                 "(", [ Formals ], ")", [ Result ], NATIVE ;
Constant     = "constant", IDENT, [ Result ], "is", Expr, STOP ;
Mutable      = "mutable", IDENT, [ Result ], "is", Expr, STOP ;
Alias        = "type", IDENT, [ Parameters ], "is", DefinitionType,
               [ Derives ], [ Bounds ], STOP ;
Derives      = "derives", Name, { ",", Name } ;
DefinitionType = Record | Packed | Choice | "opaque" | Type ;
Record       = "record", "{", { Member }, "}" ;
Packed       = "packed", Record ;
Member       = IDENT, "of", "type", Type, STOP ;
Choice       = "choice", "{", { Variant }, "}" ;
Variant      = IDENT, [ "(", Type, ")" | "is", INT ], STOP ;

Type         = Primitive | Name, [ ArgumentsType ]
             | "pointer", "to", Type
             | "sequence", "of", Type
             | "fallible", Type | "optional", Type
             | "function", "taking", "(", [ Types ], ")", "giving", Type
             | "vector", "[", INT, ",", Type, "]" ;
Primitive    = "integer", [ INT ] | "unsigned", [ INT ]
             | "decimal", [ INT ] | "text" | "boolean"
             | "byte" | "character" | "nothing" ;
Name         = IDENT, { MEMBER, IDENT } ;
ArgumentsType = "[", Types, "]" ;
Types        = Type, { ",", Type } ;

Block        = "{", { Statement }, "}" ;
Statement    = Constant | Mutable | Alias | Set | Give | When | While | For
             | Match | "break", STOP | "continue", STOP | After | Eval
             | "unsafe", Block | Native | Machine | Expr, STOP ;
Machine      = "atomic", "add", IDENT, "by", Expr, STOP
             | "bits", ( "set" | "clear" ), IDENT, "at", "position", Expr, STOP
             | "memory", "align", IDENT, "to", INT, STOP
             | "register", IDENT, "is", Expr, STOP ;
System       = "call", "system", "call", Expr, [ "with", Values ] ;
Set          = "set", Place, "to", Expr, STOP ;
Place        = IDENT, { MEMBER, IDENT | "at", Atom } ;
Give         = "give", Expr, STOP ;
When         = "when", Expr, Block,
               [ "otherwise", ( Block | When ) ] ;
While        = "while", Expr, Block ;
For          = "for", "each", IDENT, "in", Expr, Block ;
Match        = "match", Expr, "{", { Arm }, "}" ;
Arm          = "case", Pattern, [ "when", Expr ], Block ;
Pattern      = Name, [ "(", IDENT, ")" ]
             | INT | "true" | "false" | "nothing" | "anything" ;
After        = ( "after" | "cleanup" | "finally" ), [ "error" ], Block ;

Expr         = Or, [ "catch", Expr ] ;
Or           = And, { "or", And } ;
And          = Negation, { "and", Negation } ;
Negation     = { "not" }, Relation ;
Relation     = Sum, [ Comparison, Sum ] ;
Comparison   = "is", [ "not" ] | "less", "than" | "greater", "than" ;
Sum          = Product, { ( "plus" | "minus" ), Product } ;
Product      = Prefix, { ( "times" | "divided", "by" | "remainder" ), Prefix } ;
Prefix       = "try", Prefix | "allocate", Atom, [ "using", Atom ] | Postfix ;
Postfix      = Atom, { Call | MEMBER, IDENT, [ ArgumentsType ] | "at", Atom } ;
Call         = "(", [ Values ], ")" ;
Values       = Expr, { ",", Expr } ;
Atom         = IDENT, [ ArgumentsType ] | Literal | "(", Expr, ")"
             | "newline" | "uninitialized" | "unreachable" | System
             | "reflect", "[", Type, "]", "(", ")"
             | "embed", "(", TEXT, ")" ;
Literal      = INT | DECIMAL | TEXT | CHAR | "true" | "false" | "nothing" ;
```

A file contains at most one `start()`; libraries contain none. An executable
selects the unique start among discovered source files unless project entry or
a product entry chooses its file explicitly. Its result is `fallible nothing`.
Test bodies have the same result type. Reaching the end of a unit-returning
body succeeds with nothing; a non-unit body must return on every reachable path.
`give nothing.` returns unit. A function with no declared result infers a
single compatible result; recursive functions require explicit results.
Function declarations occur at file level, not inside functions.

The ABI string in Foreign is exactly `"C"`. A period declares an import;
a body defines a C-callable function. Foreign declarations have no generics.
`public` is valid on definitions, not imports, tests, eval blocks or start.

An expression statement must call an operation, perform allocation, propagate
an error, or be `unreachable`. Discarding an unhandled fallible result is an
error. `set` requires a mutable place; the final `to` separates its destination
from its value. Reading an uninitialized place is forbidden.

## Binding and evaluation

Postfix operations associate left to right. An `at` operand is one Atom:
`rows at i at j` means `(rows at i) at j`; write
`rows at (i plus 1)` for a computed index and
`rows at (indices.current)` for a member-valued index.
Square brackets exclusively carry type arguments or vector parameters.

Precedence, tightest first: postfix; try/allocation; multiplication, division
and remainder; addition/subtraction; comparison; not; and; or; catch.
Arithmetic and Boolean chains associate left; catch associates right.
Comparisons do not chain: `a less than b less than c` is invalid.
`a is not b` is inequality, while `a is (not b)` compares against a negation.
`not a is b` means `not (a is b)`. Declaration `is` is consumed before its
initializer expression, so `constant ready is not busy.` is unambiguous.

Operands and arguments evaluate left to right. `and` and `or` short-circuit;
catch evaluates its fallback only on failure. `try read() catch fallback`
first propagates read's error; use `read() catch fallback` for local recovery.
Try applied to an infallible value and catch applied to a non-fallible value are
type errors, not alternate interpretations.

Calls always use parentheses, including zero-argument calls. A name followed by
type arguments denotes a specialization: `sort[integer](items)`.
Type names used as calls construct records positionally in field order; choice
payload constructors use qualified variant names.

All branches have braces. An otherwise belongs to the immediately preceding
when at the same nesting depth. Loop bindings are immutable element values.
Match arms are checked in source order; guards do not establish exhaustiveness.
A payload-free choice may assign unique integer tags; a payload choice may not.
Either every payload-free variant supplies a tag or none does. Empty choices
are invalid. A Name pattern resolves a variant or constant; it never introduces
a catch-all binding. Only a payload identifier introduces a binding, scoped to
its guard and arm. `anything` is the catch-all. A match must cover every value;
integer matches therefore need an unguarded catch-all. A payload-free variant
pattern uses its name alone, without empty parentheses.

| Expression | Required grouping |
| --- | --- |
| `a plus b times c` | `a plus (b times c)` |
| `a minus b minus c` | `(a minus b) minus c` |
| `not a is b` | `not (a is b)` |
| `a is not b` | One inequality comparison |
| `a or b and c` | `a or (b and c)` |
| `rows at i at j` | `(rows at i) at j` |
| `rows at i.name` | `(rows at i).name` |
| `a catch b catch c` | `a catch (b catch c)` |
| `try read()` | `try (read())` |
| `allocate (size()) using owner` | One allocation with an explicit owner |

## Declaration scope

File declarations are visible throughout their file; duplicate names in one
scope are errors. Function parameters are visible throughout the function body.
Local constants and mutable bindings become visible after their initializer;
local type and eval declarations are visible throughout their enclosing block.
An inner block may shadow an outer binding. The same rules apply to imported
namespace names, which cannot be redeclared in their file scope.

File-level value initializers must be compile-time evaluable. Mutable file
values receive that initial value separately in each process; they do not
introduce an order-dependent startup script. A local constant means an immutable
binding, not necessarily compile-time evaluation. A mutable binding permits
assignment but does not by itself grant write access through a borrowed view.

`when`, `while` and guards require Boolean conditions. `for each` visits a
sequence's elements in increasing index order. A break or continue targets the
innermost loop and cannot occur outside a loop. An unsafe or native block does
not create a separate control-flow escape route.

`eval` declarations are evaluated before execution and bind in the containing
scope. Reflect returns an immutable type description; embed returns immutable
resource bytes. Neither creates a type at runtime. Unresolved compile-time
values, recursive constant cycles and compile-time external side effects are
errors.

## Canonical examples

```iv
-- Calculates a total.
public function add(left of type integer, right of type integer)
  of type integer {
  give left plus right.
}

function sort[T](items of type sequence of T)
  of type nothing where T is Ord {
  give nothing.
}

start() {
  mutable count is 0.
  while count less than 4 {
    set count to count plus 1.
  }
  constant total is add(20, 24).
  give nothing.
}
```

Packed records and vector types require hardware capability. Native and unsafe
operations require the level of their effects, at least system. Capability
checks do not alter parsing. Removed spellings are listed in
[consolidation](consolidation.md); they are not alternative v1 syntax.

`#[repr(C)] type Name is record { ... }.` and the corresponding union declaration
select C layout. Attribute parentheses belong to the declaration, not its body.
`extern "C" function name(...) giving Type.` declares a C symbol. Native function
headers use the ordinary function signature followed by an opaque native body;
the `function` keyword distinguishes them from an unnamed native block.
