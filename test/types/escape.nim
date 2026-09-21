import std/[strutils, tables]
import ../../src/ast/node as ast
import ../../src/diag/[engine, span]
import ../../src/types/[env, escape]

let position = Span(start: 0, `end`: 1, line: 1, col: 1)
proc name(value: string): ast.Name = ast.Name(tag: "name", span: position, text: value)
proc allocation(owner: ast.Expression = nil): ast.Allocation =
  ast.Allocation(tag: "allocation", span: position,
    size: ast.Integer(tag: "integer", span: position, value: "8"), owner: owner)

let escaping = ast.Block(tag: "block", span: position, stmts: @[
  ast.Statement(ast.Mutable(tag: "mutable", span: position, name: name("outer"),
    value: ast.Nothing(tag: "nothing", span: position))),
  ast.Statement(ast.`When`(tag: "when", span: position,
    cond: ast.`True`(tag: "true", span: position),
    `then`: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.Constant(tag: "constant", span: position, name: name("inner"),
        value: allocation())),
      ast.Statement(ast.Assignment(tag: "assignment", span: position,
        target: name("outer"), value: name("inner")))
    ])))
])
let diagnostics = newEngine()
checkEscape(escaping, newEnvironment(), diagnostics)
doAssert diagnostics.failed
doAssert diagnostics.messages[0].text.contains("shorter-lived value")

let owner = name("arena")
let safe = ast.Block(tag: "block", span: position, stmts: @[
  ast.Statement(ast.Constant(tag: "constant", span: position, name: name("arena"),
    value: allocation())),
  ast.Statement(ast.Mutable(tag: "mutable", span: position, name: name("outer"),
    value: ast.Nothing(tag: "nothing", span: position))),
  ast.Statement(ast.`When`(tag: "when", span: position,
    cond: ast.`True`(tag: "true", span: position),
    `then`: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.Assignment(tag: "assignment", span: position,
        target: name("outer"), value: allocation(owner)))
    ])))
])
let safeDiagnostics = newEngine()
checkEscape(safe, newEnvironment(), safeDiagnostics)
doAssert not safeDiagnostics.failed

echo "type escape parity: ok"
