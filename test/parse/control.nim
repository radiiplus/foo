import std/[os, sequtils]
import ../../src/ast/node as ast
import ../../src/diag/engine
import ../../src/lex/lexer
import ../../src/parse/parser

let fixture = currentSourcePath().parentDir / "fixtures" / "basic.iv"
let source = readFile(fixture)
let diagnostics = newEngine()
diagnostics.setSource(source, fixture)
let program = newParser(newLexer(source, diagnostics).lex(), diagnostics).parse()
doAssert not diagnostics.failed, if diagnostics.messages.len > 0: diagnostics.messages[0].text else: "parse failed"
let statements = program.units[0].body.stmts
doAssert statements.anyIt(it.tag == "alias" and ast.Alias(it).body.tag == "record")
doAssert statements.anyIt(it.tag == "alias" and ast.Alias(it).body.tag == "choice")
let imported = statements.filterIt(it.tag == "use")[0]
doAssert ast.Use(imported).name.text == "filesystem"
doAssert ast.Use(imported).path.len == 0
let start = statements.filterIt(it.tag == "function" and ast.Function(it).name.text == "start")[0]
let tags = ast.Function(start).body.stmts.mapIt(it.tag)
for expected in ["when", "repeat", "for", "match", "defer", "unsafe", "give"]:
  doAssert expected in tags, "missing " & expected
echo "parser control-flow parity: ok"
