import std/tables
import ../../src/ast/node as ast
import ../../src/diag/span
import ../../src/ir/eval

let position = Span(start: 0, `end`: 1, line: 1, col: 1)
proc name(value: string): ast.Name = ast.Name(tag: "name", span: position, text: value)
proc integer(value: string): ast.Integer = ast.Integer(tag: "integer", span: position, value: value)

var bindings = initTable[string, ast.Expression]()
bindings["base"] = integer("40")
let sum = evaluate(ast.Binary(tag: "binary", span: position, op: "plus",
  left: name("base"), right: integer("2")), bindings)
doAssert sum.tag == "integer"
doAssert ast.Integer(sum).value == "42"
let comparison = evaluate(ast.Binary(tag: "binary", span: position, op: "is at least",
  left: sum, right: integer("42")), bindings)
doAssert comparison.tag == "true"

let computed = ast.Constant(tag: "constant", span: position, name: name("answer"),
  value: ast.Binary(tag: "binary", span: position, op: "plus",
    left: integer("20"), right: integer("22")))
let program = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("main"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.EvalBlock(tag: "eval", span: position,
        body: ast.Block(tag: "block", span: position,
          stmts: @[ast.Statement(computed)]))),
      ast.Statement(ast.Give(tag: "give", span: position))
    ]))
])
expand(program)
doAssert program.units[0].body.stmts.len == 2
doAssert program.units[0].body.stmts[0].tag == "constant"
doAssert computed.evaluated
doAssert ast.Integer(computed.value).value == "42"

echo "IR eval parity: ok"
