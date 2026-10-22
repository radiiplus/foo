import std/strutils
import ../../src/diag/engine
import ../../src/lex/lexer
import ../../src/ast/parser
import ../../src/types/checker

proc checked(source: string): Engine =
  result = engine()
  result.source(source, "layout.iv")
  let program = parser(lexer(source, result).lex(), result).parse()
  if not result.failed: checker(result).check(program)

let valid = checked("""
define Header as c record { value of type unsigned 32. } aligned to 64.
""")
doAssert not valid.failed

for declaration in [
    "define Header as c record { value of type byte. } aligned to 3.",
    "define Header as record { value of type byte. } aligned to 64.",
    "define Header as c record { value of type byte. } aligned to 64 aligned to 32.",
    "define Header as c record { } aligned to 64."]:
  let invalid = checked(declaration)
  doAssert invalid.failed
  doAssert invalid.messages[0].text.contains("aligned to requires")

let spelling = checked("#[align(64)] define Header as c record { value of type byte. }.")
doAssert spelling.failed
doAssert spelling.messages[0].text.contains("aligned to N")

echo "type layout parity: ok"
