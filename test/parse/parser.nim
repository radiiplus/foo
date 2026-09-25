import std/strutils
import ../../src/lex/lexer
import ../../src/parse/parser
import ../../src/diag/engine
import ../../src/ast/node

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

let naturalSource = """
function connect() giving fallible integer { give 1. }
function load() giving fallible integer {
  constant socket is connect() try.
  when socket greater than or equal to 10 { give socket. }
  when socket less than or equal to 0 { give 0. }
  display "connected" try.
  give socket.
}
"""
let naturalDiagnostics = newEngine()
naturalDiagnostics.setSource(naturalSource, "natural.iv")
let naturalProgram = newParser(newLexer(naturalSource, naturalDiagnostics).lex(),
  naturalDiagnostics).parse()
doAssert not naturalDiagnostics.failed
let loadBody = Function(naturalProgram.units[0].body.stmts[1]).body
doAssert Constant(loadBody.stmts[0]).value.tag == "unary"
doAssert Unary(Constant(loadBody.stmts[0]).value).op == "try"
doAssert Binary(`When`(loadBody.stmts[1]).cond).op == "is at least"
doAssert Binary(`When`(loadBody.stmts[2]).cond).op == "is at most"
doAssert Action(loadBody.stmts[3]).value.tag == "unary"
echo "parser foundation parity: ok"
