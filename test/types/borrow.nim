import std/[sequtils, strutils]
import ../../src/diag/engine
import ../../src/ast/print as printing
import ../../src/lex/lexer
import ../../src/ast/parser
import ../../src/types/checker

proc checked(source: string): Engine =
  result = engine()
  result.source(source, "borrow.iv")
  let program = parser(lexer(source, result).lex(), result).parse()
  if not result.failed: checker(result).check(program)

let valid = checked("""
function choose(left pointer to byte, right pointer to byte) giving pointer to byte borrowing left {
  give left.
}
""")
doAssert not valid.failed

let invalid = checked("""
function choose(left pointer to byte, right pointer to byte) giving pointer to byte borrowing left {
  give right.
}
""")
doAssert invalid.failed
doAssert invalid.messages[0].text.contains("declared relationship")

let unknown = checked("""
function choose(left pointer to byte) giving pointer to byte borrowing missing {
  give left.
}
""")
doAssert unknown.failed
doAssert unknown.messages[0].text.contains("unknown parameter")

let legacy = checked("""
#[borrows(left)]
function choose(left pointer to byte) giving pointer to byte {
  give left.
}
""")
doAssert legacy.failed
doAssert legacy.messages[0].text.contains("borrowing parameter")

let diagnostics = engine()
let input = "function borrow(value pointer to byte) giving pointer to byte borrowing value { give value. }"
diagnostics.source(input, "syntax.iv")
let tree = parser(lexer(input, diagnostics).lex(),
  diagnostics).parse()
doAssert printing.print(tree).contains("borrowing value")
doAssert not printing.print(tree).contains("#[borrows")

let declarations = """
define allocator as opaque.
define mapping as opaque.
use "memory" function bytes(owner pointer to allocator, buffer pointer to byte, size unsigned) giving failable sequence of constant byte.
use "memory" function release(owner pointer to allocator, buffer pointer to byte) giving failable nothing.
use "memory" function expand(owner pointer to allocator, buffer pointer to byte, size unsigned) giving failable pointer to byte.
use "memory" function allocate(owner pointer to allocator, size unsigned) giving failable pointer to byte.
use "memory" function aligned(buffer pointer to byte, alignment unsigned) giving boolean.
use "memory" function close(owner pointer to allocator) giving failable nothing.
use "fs" function borrow(source pointer to mapping) giving failable sequence of byte.
use "fs" function unmap(source pointer to mapping) giving failable nothing.
"""
let released = checked(declarations & """
function invalid(owner pointer to allocator, buffer pointer to byte) giving failable byte {
  constant view is bytes(owner, buffer, 1) try.
  release(owner, buffer) try.
  give view at 0.
}
""")
doAssert released.failed
doAssert released.messages[0].text.contains("after its owner")

let resized = checked(declarations & """
function invalid(owner pointer to allocator, buffer pointer to byte) giving failable byte {
  constant view is bytes(owner, buffer, 1) try.
  constant grown is expand(owner, buffer, 2) try.
  give view at 0.
}
""")
doAssert resized.failed
doAssert resized.messages[0].text.contains("after its owner")

let unmapped = checked(declarations & """
function invalid(source pointer to mapping) giving failable byte {
  constant view is borrow(source) try.
  unmap(source) try.
  give view at 0.
}
""")
doAssert unmapped.failed
doAssert unmapped.messages[0].text.contains("after its owner")

let only = checked(declarations & """
use "fs" function mapped(source pointer to mapping) giving failable sequence of constant byte.
function view(source pointer to mapping) giving failable sequence of constant byte borrowing source {
  give mapped(source) try.
}
function invalid(source pointer to mapping) giving failable byte {
  constant bytes is view(source) try.
  unmap(source) try.
  give bytes at 0.
}
""")
doAssert only.failed
doAssert only.messages.anyIt(it.text.contains("after its owner"))

let gpu = checked("""
define buffer as opaque.
use "gpu" function mapped(source pointer to buffer) giving failable sequence of constant byte.
use "gpu" function dispose(source pointer to buffer) giving failable nothing.
function view(source pointer to buffer) giving failable sequence of constant byte borrowing source {
  give mapped(source) try.
}
function invalid(source pointer to buffer) giving failable byte {
  constant bytes is view(source) try.
  dispose(source) try.
  give bytes at 0.
}
""")
doAssert gpu.failed
doAssert gpu.messages.anyIt(it.text.contains("after its owner"))

let owner = checked(declarations & """
function invalid(owner pointer to allocator, buffer pointer to byte) giving failable byte {
  constant view is bytes(owner, buffer, 1) try.
  close(owner) try.
  give view at 0.
}
""")
doAssert owner.failed
doAssert owner.messages[0].text.contains("after its owner")

let alias = checked(declarations & """
function invalid(owner pointer to allocator, buffer pointer to byte) giving failable byte {
  constant view is bytes(owner, buffer, 1) try.
  constant alias is buffer.
  release(owner, alias) try.
  give view at 0.
}
""")
doAssert alias.failed
doAssert alias.messages[0].text.contains("after its owner")

let allocation = checked(declarations & """
function invalid(owner pointer to allocator) giving failable boolean {
  constant buffer is allocate(owner, 1) try.
  close(owner) try.
  give aligned(buffer, 1).
}
""")
doAssert allocation.failed
doAssert allocation.messages[0].text.contains("after its owner")

let returned = checked(declarations & """
function invalid(owner pointer to allocator, buffer pointer to byte)
    giving failable sequence of constant byte borrowing buffer {
  after { release(owner, buffer) fallback nothing. }
  give bytes(owner, buffer, 1) try.
}
""")
doAssert returned.failed
doAssert returned.messages.anyIt(it.text.contains("cleanup")),
  returned.messages[0].text

let cleanup = checked("""
use "sequence" function release[T](items sequence of T) giving failable nothing.
function valid(items sequence of byte) giving failable sequence of byte borrowing items {
  after error { release[byte](items) fallback nothing. }
  give items.
}
""")
doAssert not cleanup.failed,
  if cleanup.messages.len > 0: cleanup.messages[0].text else: "unexpected failure"

let branch = checked(declarations & """
function invalid(owner pointer to allocator, buffer pointer to byte, enabled boolean)
    giving failable sequence of constant byte borrowing owner, buffer {
  when enabled { give bytes(owner, buffer, 1) try. }
  release(owner, buffer) try.
  give fail(Error.Closed).
}
""")
doAssert branch.failed
doAssert branch.messages.anyIt(it.text.contains("without declaring"))

let release = checked("""
use "sequence" function release[T](items sequence of T) giving failable nothing.
function consume(items sequence of byte) giving failable nothing releasing items {
  release[byte](items) try.
  give nothing.
}
function invalid(items sequence of byte) giving failable byte {
  constant alias is items.
  consume(items) try.
  give alias at 0.
}
""")
doAssert release.failed
doAssert release.messages.anyIt(it.text.contains("after its owner"))

let optimized = checked("""
use "sequence" function release[T](items sequence of T) giving failable nothing.
function consume(items sequence of byte) giving failable nothing {
  release[byte](items) try.
  give nothing.
}
""")
doAssert optimized.failed
doAssert optimized.messages.anyIt(it.text.contains("without declaring"))

let disposal = checked("""
function consume(items sequence of byte) giving nothing releasing missing {
  give nothing.
}
""")
doAssert disposal.failed
doAssert disposal.messages.anyIt(it.text.contains("unknown parameter"))

let use = checked(declarations & """
function valid(owner pointer to allocator, buffer pointer to byte) giving failable byte releasing buffer {
  constant view is bytes(owner, buffer, 1) try.
  constant first is view at 0.
  release(owner, buffer) try.
  give first.
}
""")
doAssert not use.failed,
  if use.messages.len > 0: use.messages[0].text else: "unexpected failure"

let authenticator = checked("""
define authenticator as opaque.
use "crypto" function discard(state pointer to authenticator) giving nothing.
function invalid(state pointer to authenticator) giving pointer to authenticator {
  discard(state).
  give state.
}
""")
doAssert authenticator.failed
doAssert authenticator.messages.anyIt(it.text.contains("after its owner"))

let key = checked("""
define key as opaque.
use "crypto" function forget(secret pointer to key) giving nothing.
function invalid(secret pointer to key) giving pointer to key {
  forget(secret).
  give secret.
}
""")
doAssert key.failed
doAssert key.messages.anyIt(it.text.contains("after its owner"))

let hasher = checked("""
define hasher as opaque.
use "crypto" function retire(state pointer to hasher) giving nothing.
function invalid(state pointer to hasher) giving pointer to hasher {
  retire(state).
  give state.
}
""")
doAssert hasher.failed
doAssert hasher.messages.anyIt(it.text.contains("after its owner"))

let symbol = checked("""
define library as opaque.
define unary as opaque.
use "dylib" function lookup(owner pointer to library, name text) giving failable pointer to unary.
use "dylib" function close(owner pointer to library) giving failable nothing.
use "dylib" function call(symbol pointer to unary, value unsigned) giving failable unsigned.
function invalid(owner pointer to library) giving failable unsigned {
  constant symbol is lookup(owner, "test") try.
  close(owner) try.
  give call(symbol, 1) try.
}
""")
doAssert symbol.failed
doAssert symbol.messages.anyIt(it.text.contains("after its owner"))

echo "type borrow parity: ok"
