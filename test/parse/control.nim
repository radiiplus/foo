import std/[os, sequtils]
import ../../src/ast/node as ast
import ../../src/diag/engine
import ../../src/lex/lexer
import ../../src/ast/parser

let fixture = currentSourcePath().parentDir / "fixtures" / "basic.iv"
let source = readFile(fixture)
let diagnostics = engine()
diagnostics.source(source, fixture)
let program = parser(lexer(source, diagnostics).lex(), diagnostics).parse()
doAssert not diagnostics.failed, if diagnostics.messages.len > 0: diagnostics.messages[0].text else: "parse failed"
let statements = program.units[0].body.stmts
doAssert statements.anyIt(it.tag == "alias" and ast.Alias(it).body.tag == "record")
doAssert statements.anyIt(it.tag == "alias" and ast.Alias(it).body.tag == "choice")
let imported = statements.filterIt(it.tag == "use")[0]
doAssert ast.Use(imported).name.text == "file"
doAssert ast.Use(imported).path.len == 0
let start = statements.filterIt(it.tag == "function" and ast.Function(it).name.text == "start")[0]
let tags = ast.Function(start).body.stmts.mapIt(it.tag)
for expected in ["when", "while", "for", "match", "defer", "unsafe", "give"]:
  doAssert expected in tags, "missing " & expected

let input = """start {
  match value {
    case model.item(found) { give found. }
    case anything { give 0. }
  }
}
"""
let issues = engine()
issues.source(input, "qualified.iv")
let tree = parser(lexer(input,
  issues).lex(), issues).parse()
doAssert not issues.failed,
  if issues.messages.len > 0:
    issues.messages[0].text else: "qualified pattern parse failed"
let match = ast.Match(ast.Function(
  tree.units[0].body.stmts[0]).body.stmts[0])
let qualified = ast.Arm(match.cases[0].pattern)
doAssert qualified.name.text == "model.item"
doAssert qualified.binding.text == "found"
doAssert qualified.span.file == "qualified.iv"
doAssert match.cases[0].body.span.file == "qualified.iv"
echo "parser control-flow parity: ok"
