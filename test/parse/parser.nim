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

let legacy = "start() {\n  constant buffer is try allocate(owner, 4).\n}"
let issues = newEngine()
issues.setSource(legacy, "legacy.iv")
discard newParser(newLexer(legacy, issues).lex(), issues).parse()
doAssert not issues.failed

let natural = """
function connect() giving failable integer { give 1. }
function load() giving failable integer {
  constant socket is connect() try.
  when socket greater than or equal to 10 { give socket. }
  when socket less than or equal to 0 { give 0. }
  display "connected" try.
  give socket.
}
"""
let notices = newEngine()
notices.setSource(natural, "natural.iv")
let tree = newParser(newLexer(natural, notices).lex(), notices).parse()
doAssert not notices.failed
let body = Function(tree.units[0].body.stmts[1]).body
doAssert Constant(body.stmts[0]).value.tag == "unary"
doAssert Unary(Constant(body.stmts[0]).value).op == "try"
doAssert Binary(`When`(body.stmts[1]).cond).op == "is at least"
doAssert Binary(`When`(body.stmts[2]).cond).op == "is at most"
doAssert Action(body.stmts[3]).value.tag == "unary"

let sample = """
function connect host text port integer default 443 giving integer {
  give port.
}
function total values are sequence of integer giving integer {
  dynamic result is 0.
  for each value in values { increase result by value. }
  give result.
}
function positive value integer when value greater than 0 giving integer {
  give value.
}
constant users are 2.
constant next is function giving integer { give 1. }.
connect(host "example.com", port 8080).
"""
let reports = newEngine()
reports.setSource(sample, "expressive.iv")
let parsed = newParser(newLexer(sample, reports).lex(), reports).parse()
doAssert not reports.failed
let unit = parsed.units[0].body
doAssert Function(unit.stmts[0]).params[1].default != nil
doAssert Function(unit.stmts[1]).params[0].variadic
doAssert Function(unit.stmts[2]).guard != nil
doAssert Constant(unit.stmts[3]).plural
doAssert Constant(unit.stmts[4]).value.tag == "closure"
let action = Action(unit.stmts[5])
doAssert action.value.tag == "call"
doAssert Call(action.value).names == @["host", "port"]

let optionalSource = "constant missing of type optional integer is null."
let optionalDiagnostics = newEngine()
optionalDiagnostics.setSource(optionalSource, "optional.iv")
let optionalTree = newParser(newLexer(optionalSource,
  optionalDiagnostics).lex(), optionalDiagnostics).parse()
doAssert not optionalDiagnostics.failed
doAssert Constant(optionalTree.units[0].body.stmts[0]).value.tag == "null"

let destructureSource = "constant User(name, age) is user."
let destructureDiagnostics = newEngine()
destructureDiagnostics.setSource(destructureSource, "destructure.iv")
let destructureTree = newParser(newLexer(destructureSource,
  destructureDiagnostics).lex(), destructureDiagnostics).parse()
doAssert not destructureDiagnostics.failed
let destructure = Destructure(destructureTree.units[0].body.stmts[0])
doAssert destructure.fields.len == 2
doAssert destructure.fields[0].text == "name"
doAssert destructure.bindings[1].text == "age"

let branchesSource = """
when score greater than 80 { display "high". }
otherwise when score greater than 50 { display "middle". }
otherwise { display "low". }
"""
let branchesDiagnostics = newEngine()
branchesDiagnostics.setSource(branchesSource, "branches.iv")
let branchesTree = newParser(newLexer(branchesSource,
  branchesDiagnostics).lex(), branchesDiagnostics).parse()
doAssert not branchesDiagnostics.failed
let firstBranch = `When`(branchesTree.units[0].body.stmts[0])
doAssert firstBranch.`else`.tag == "when"
doAssert `When`(firstBranch.`else`).`else`.tag == "block"

let remainderSource = "constant remainderValue is 5 remainder 2."
let remainderDiagnostics = newEngine()
remainderDiagnostics.setSource(remainderSource, "remainder.iv")
let remainderTree = newParser(newLexer(remainderSource,
  remainderDiagnostics).lex(), remainderDiagnostics).parse()
doAssert not remainderDiagnostics.failed
let remainderValue = Constant(remainderTree.units[0].body.stmts[0]).value
doAssert remainderValue.tag == "binary"
doAssert Binary(remainderValue).op == "remainder"
echo "parser foundation parity: ok"
