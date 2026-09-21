import std/strutils
import ../../src/lex/lexer
import ../../src/parse/parser
import ../../src/diag/engine

let source = "constant answer is 42.\nstart() {\n  give answer.\n}"
let diagnostics = newEngine()
diagnostics.setSource(source, "main.iv")
let tokens = newLexer(source, diagnostics).lex()
let program = newParser(tokens, diagnostics).parse()
doAssert program.units[0].body.stmts.len == 2
doAssert program.units[0].body.stmts[0].tag == "constant"
doAssert program.units[0].body.stmts[1].tag == "function"
doAssert not diagnostics.failed

let legacySource = "start() {\n  constant buffer is try allocate(owner, 4).\n}"
let legacyDiagnostics = newEngine()
legacyDiagnostics.setSource(legacySource, "legacy.iv")
discard newParser(newLexer(legacySource, legacyDiagnostics).lex(),
  legacyDiagnostics).parse()
doAssert not legacyDiagnostics.failed
echo "parser foundation parity: ok"
