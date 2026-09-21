import std/strutils
import ../../src/ast/node as ast
import ../../src/diag/[code, engine, span]
import ../../src/pkg/lint

let position = Span(start: 0, `end`: 1, line: 1, col: 1)
proc name(value: string): ast.Name = ast.Name(tag: "name", span: position, text: value)
let native = ast.Native(tag: "native", span: position, substrate: "c", code: "int hidden;")
let exposed = ast.Function(tag: "function", span: position, public: true,
  name: name("exposed"), body: ast.Block(tag: "block", span: position,
    stmts: @[ast.Statement(ast.EvalBlock(tag: "eval", span: position,
      body: ast.Block(tag: "block", span: position, stmts: @[ast.Statement(native)])))]))
let machine = ast.Machine(tag: "machine", span: position, operation: "atomic",
  target: name("value"), value: ast.Integer(tag: "integer", span: position, value: "1"))
let program = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("main"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(exposed), ast.Statement(machine)
    ]))
])
let diagnostics = newEngine()
lint(program, diagnostics)
doAssert diagnostics.failed
doAssert diagnostics.messages[0].code == Code.NativePublic

let capabilityDiagnostics = newEngine()
capabilities(program, capabilityDiagnostics)
doAssert capabilityDiagnostics.messages.len == 1
doAssert capabilityDiagnostics.messages[0].text.contains("machine")
let allowed = newEngine()
capabilities(program, allowed, "machine")
doAssert not allowed.failed

echo "package lint parity: ok"
