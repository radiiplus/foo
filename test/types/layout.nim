import std/strutils
import ../../src/diag/engine
import ../../src/lex/lexer
import ../../src/parse/parser
import ../../src/types/checker

proc checked(source: string): Engine =
  result = newEngine()
  result.setSource(source, "layout.iv")
  let program = newParser(newLexer(source, result).lex(), result).parse()
  if not result.failed: newChecker(result).check(program)

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

let oldSpelling = checked("#[align(64)] define Header as c record { value of type byte. }.")
doAssert oldSpelling.failed
doAssert oldSpelling.messages[0].text.contains("aligned to N")

echo "type layout parity: ok"
