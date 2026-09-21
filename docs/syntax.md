# Chapter 11 — Every syntax form

Each entry below names one FOO form, shows it in use, and explains the result.

## Files

**File:** every `.iv` file is one unit; write `start() { give nothing. }`. **Comment:** `-- explain this line` is ignored. **Use:** `use "math.iv".` imports public names. **As:** `use testing as check.` gives an import a local name.

## Declarations

**Constant:** `constant answer is 44.` creates a name that cannot change. **Mutable:** `mutable count of type integer is 0.` creates a name that can change. **Set:** `set count to count plus 1.` changes a mutable name. **Public:** `public constant version is "1".` allows other files to import it. **Function:** `function add(a of type integer, b of type integer) of type integer { give a plus b. }` names reusable work. **Start:** `start() { display "ready". give nothing. }` begins a program.

## Values and types

**Integer:** `constant n of type integer is 4.` stores a whole number. **Unsigned:** `constant n of type unsigned 64 is 4.` stores a non-negative number with a chosen size. **Decimal:** `constant n of type decimal is 1.5.` stores a fraction. **Boolean:** `constant yes of type boolean is true.` stores true or false. **Text:** `constant word of type text is "FOO".` stores text. **Character:** `constant letter of type character is 'F'.` stores one character. **Byte:** `constant mark of type byte is 33.` stores one small number. **Nothing:** `function stop() of type nothing { give nothing. }` returns no value.

**Optional:** `mutable name of type optional text is nothing.` may contain text or no text. **Fallible:** `function load() of type fallible text { give file read "a.txt". }` may contain text or an error. **Pointer:** `mutable address of type pointer to byte is nothing.` stores a memory location. **Sequence:** `constant values of type sequence of integer is sequence create().` stores ordered values. **Function type:** `constant op of type function taking (integer) giving integer is double.` stores a function.

**Record:** `record User { name of type text. }` groups named fields. **Choice:** `choice Reply { ok of type integer. failed of type text. }` lists possible cases. **Union:** `#[repr(C)] union Word { number of type integer. }` shares a C-compatible memory location. **Opaque:** `opaque Handle.` lets code pass a value without seeing inside it. **Vector:** `constant lanes of type vector 4 of integer is splat 0.` stores four values together.

## Operators

**Arithmetic:** `total plus fee`, `total minus fee`, `price times count`, `total divided by count`, and `total remainder count` calculate numbers. **Comparison:** `age is 18`, `age is not 18`, `age greater than 18`, `age less than 18`, `age at least 18`, and `age at most 18` compare values. **Logic:** `ready and open`, `ready or forced`, and `not locked` combine boolean values. **Index:** `values at 0` reads an item. **Field:** `user.name` reads a record field.

## Flow

**When:** `when ready { display "go". }` chooses a block. **Otherwise:** `otherwise { display "wait". }` handles the other choice. **While:** `while count less than 10 { set count to count plus 1. }` repeats while true. **For each:** `for each item in values { display item. }` visits every item. **Repeat:** `repeat index until index reaches 10 { display index. }` counts toward a limit. **Break:** `break.` leaves a loop. **Continue:** `continue.` skips to its next pass. **Give:** `give result.` returns a value; `give nothing.` returns no value.

## Errors and special flow

**Try:** `constant text is try file read "a.txt".` returns early if reading fails. **Catch:** `file read "a.txt" catch error { display error. give "". }` handles that failure here. **After:** `after { file close handle. }` cleans up at block exit. `cleanup` and `finally` are accepted names for `after`. **Unsafe:** `unsafe { set raw at 0 to 1. }` marks work the compiler cannot fully check. **Uninitialized:** `mutable result of type integer is uninitialized.` reserves space until it is assigned. **Unreachable:** `unreachable.` marks a path that cannot happen.

## Types, tests, and building

**Generic type:** `function first[T](items of type sequence of T) of type T { give items at 0. }` works for many types. **Where:** `where T is Ord` says what that type must support. **Test:** `test "addition" { expect add(2, 2) is 4. }` creates a runnable check. **Eval:** `constant port is eval { 8000 plus 1 }.` calculates during building. **Reflect:** `reflect[integer 64]().size` asks about a type. **Embed:** `embed "assets/logo.txt" of type text` includes a file.

## Boundaries and attributes

**Derive:** `#[derive(Eq, Hash)] record Key { value of type integer. }` requests common generated behavior. **C layout:** `#[repr(C)] record Header { size of type integer. }` matches C field layout. **Packed:** `#[packed] record Bits { flags of type byte. }` removes padding. **Native:** `native c { #include <stdio.h> }` places code at a low-level boundary. **Extern:** `extern "C" function puts(value of type pointer to byte) of type integer.` declares an outside function. **Export:** `export function entry() of type nothing { give nothing. }` makes a symbol available outside the program.

## Choices and machine work

**Match:** `match reply { case ok(value) { display value. } case failed(message) { display message. } }` handles every choice. **Atomic:** `atomic add counter by 1.` changes a shared number safely. **Bits:** `bits set flags at position 4.` and `bits clear flags at position 7.` change individual bits. **Align:** `memory align buffer to 64.` requests a memory boundary. **Register:** `register rax is value.` writes a processor register. **System call:** `call system 1 with value.` asks the operating system directly. These last forms require the project's machine or hardware permission.
