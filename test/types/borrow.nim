import std/[sequtils, strutils]
import ../../src/diag/engine
import ../../src/ast/print as astPrint
import ../../src/lex/lexer
import ../../src/parse/parser
import ../../src/types/checker

proc checked(source: string): Engine =
  result = newEngine()
  result.setSource(source, "borrow.iv")
  let program = newParser(newLexer(source, result).lex(), result).parse()
  if not result.failed: newChecker(result).check(program)

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

let syntaxDiagnostics = newEngine()
let syntaxSource = "function borrow(value pointer to byte) giving pointer to byte borrowing value { give value. }"
syntaxDiagnostics.setSource(syntaxSource, "syntax.iv")
let syntaxTree = newParser(newLexer(syntaxSource, syntaxDiagnostics).lex(),
  syntaxDiagnostics).parse()
doAssert astPrint.print(syntaxTree).contains("borrowing value")
doAssert not astPrint.print(syntaxTree).contains("#[borrows")

let lifetimeDeclarations = """
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
let released = checked(lifetimeDeclarations & """
function invalid(owner pointer to allocator, buffer pointer to byte) giving failable byte {
  constant view is bytes(owner, buffer, 1) try.
  release(owner, buffer) try.
  give view at 0.
}
""")
doAssert released.failed
doAssert released.messages[0].text.contains("after its owner")

let resized = checked(lifetimeDeclarations & """
function invalid(owner pointer to allocator, buffer pointer to byte) giving failable byte {
  constant view is bytes(owner, buffer, 1) try.
  constant grown is expand(owner, buffer, 2) try.
  give view at 0.
}
""")
doAssert resized.failed
doAssert resized.messages[0].text.contains("after its owner")

let unmapped = checked(lifetimeDeclarations & """
function invalid(source pointer to mapping) giving failable byte {
  constant view is borrow(source) try.
  unmap(source) try.
  give view at 0.
}
""")
doAssert unmapped.failed
doAssert unmapped.messages[0].text.contains("after its owner")

let readOnlyUnmapped = checked(lifetimeDeclarations & """
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
doAssert readOnlyUnmapped.failed
doAssert readOnlyUnmapped.messages.anyIt(it.text.contains("after its owner"))

let disposedGpu = checked("""
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
doAssert disposedGpu.failed
doAssert disposedGpu.messages.anyIt(it.text.contains("after its owner"))

let closedOwner = checked(lifetimeDeclarations & """
function invalid(owner pointer to allocator, buffer pointer to byte) giving failable byte {
  constant view is bytes(owner, buffer, 1) try.
  close(owner) try.
  give view at 0.
}
""")
doAssert closedOwner.failed
doAssert closedOwner.messages[0].text.contains("after its owner")

let releasedAlias = checked(lifetimeDeclarations & """
function invalid(owner pointer to allocator, buffer pointer to byte) giving failable byte {
  constant view is bytes(owner, buffer, 1) try.
  constant alias is buffer.
  release(owner, alias) try.
  give view at 0.
}
""")
doAssert releasedAlias.failed
doAssert releasedAlias.messages[0].text.contains("after its owner")

let closedAllocation = checked(lifetimeDeclarations & """
function invalid(owner pointer to allocator) giving failable boolean {
  constant buffer is allocate(owner, 1) try.
  close(owner) try.
  give aligned(buffer, 1).
}
""")
doAssert closedAllocation.failed
doAssert closedAllocation.messages[0].text.contains("after its owner")

let cleanupReturn = checked(lifetimeDeclarations & """
function invalid(owner pointer to allocator, buffer pointer to byte)
    giving failable sequence of constant byte borrowing buffer {
  after { release(owner, buffer) fallback nothing. }
  give bytes(owner, buffer, 1) try.
}
""")
doAssert cleanupReturn.failed
doAssert cleanupReturn.messages.anyIt(it.text.contains("cleanup")),
  cleanupReturn.messages[0].text

let errorOnlyCleanup = checked("""
use "sequence" function release[T](items sequence of T) giving failable nothing.
function valid(items sequence of byte) giving failable sequence of byte borrowing items {
  after error { release[byte](items) fallback nothing. }
  give items.
}
""")
doAssert not errorOnlyCleanup.failed,
  if errorOnlyCleanup.messages.len > 0: errorOnlyCleanup.messages[0].text else: "unexpected failure"

let separateBranch = checked(lifetimeDeclarations & """
function invalid(owner pointer to allocator, buffer pointer to byte, enabled boolean)
    giving failable sequence of constant byte borrowing owner, buffer {
  when enabled { give bytes(owner, buffer, 1) try. }
  release(owner, buffer) try.
  give fail(Error.Closed).
}
""")
doAssert separateBranch.failed
doAssert separateBranch.messages.anyIt(it.text.contains("without declaring"))

let declaredRelease = checked("""
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
doAssert declaredRelease.failed
doAssert declaredRelease.messages.anyIt(it.text.contains("after its owner"))

let hiddenRelease = checked("""
use "sequence" function release[T](items sequence of T) giving failable nothing.
function consume(items sequence of byte) giving failable nothing {
  release[byte](items) try.
  give nothing.
}
""")
doAssert hiddenRelease.failed
doAssert hiddenRelease.messages.anyIt(it.text.contains("without declaring"))

let unknownRelease = checked("""
function consume(items sequence of byte) giving nothing releasing missing {
  give nothing.
}
""")
doAssert unknownRelease.failed
doAssert unknownRelease.messages.anyIt(it.text.contains("unknown parameter"))

let releasedAfterUse = checked(lifetimeDeclarations & """
function valid(owner pointer to allocator, buffer pointer to byte) giving failable byte releasing buffer {
  constant view is bytes(owner, buffer, 1) try.
  constant first is view at 0.
  release(owner, buffer) try.
  give first.
}
""")
doAssert not releasedAfterUse.failed,
  if releasedAfterUse.messages.len > 0: releasedAfterUse.messages[0].text else: "unexpected failure"

let closedAuthenticator = checked("""
define authenticator as opaque.
use "crypto" function discard(state pointer to authenticator) giving nothing.
function invalid(state pointer to authenticator) giving pointer to authenticator {
  discard(state).
  give state.
}
""")
doAssert closedAuthenticator.failed
doAssert closedAuthenticator.messages.anyIt(it.text.contains("after its owner"))

let closedSecureKey = checked("""
define key as opaque.
use "crypto" function forget(secret pointer to key) giving nothing.
function invalid(secret pointer to key) giving pointer to key {
  forget(secret).
  give secret.
}
""")
doAssert closedSecureKey.failed
doAssert closedSecureKey.messages.anyIt(it.text.contains("after its owner"))

let closedBlakeHasher = checked("""
define hasher as opaque.
use "crypto" function retire(state pointer to hasher) giving nothing.
function invalid(state pointer to hasher) giving pointer to hasher {
  retire(state).
  give state.
}
""")
doAssert closedBlakeHasher.failed
doAssert closedBlakeHasher.messages.anyIt(it.text.contains("after its owner"))

let closedLibrarySymbol = checked("""
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
doAssert closedLibrarySymbol.failed
doAssert closedLibrarySymbol.messages.anyIt(it.text.contains("after its owner"))

echo "type borrow parity: ok"
