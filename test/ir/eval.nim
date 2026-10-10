import std/[sets, tables]
import ../../src/ast/node as ast
import ../../src/diag/span
import ../../src/diag/engine
import ../../src/lex/lexer
import ../../src/parse/parser
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

let word = ast.Primitive(tag: "primitive", span: position, name: "integer", width: "32")
let size = evaluate(ast.Field(tag: "field", span: position,
  `object`: ast.Reflect(tag: "reflect", span: position, `type`: word),
  field: name("size")), bindings)
doAssert ast.Integer(size).value == "4"
let alignment = evaluate(ast.Field(tag: "field", span: position,
  `object`: ast.Reflect(tag: "reflect", span: position, `type`: word),
  field: name("alignment")), bindings)
doAssert ast.Integer(alignment).value == "4"
let header = ast.Alias(tag: "alias", span: position, name: name("Header"),
  body: ast.Record(tag: "record", span: position, layout: "c", fields: @[
    ast.Member(tag: "member", span: position, name: name("tag"),
      `type`: ast.Primitive(tag: "primitive", span: position, name: "byte")),
    ast.Member(tag: "member", span: position, name: name("count"),
      `type`: word)]))
var types = initTable[string, ast.Alias]()
types["Header"] = header
let reflected = ast.Reflect(tag: "reflect", span: position,
  `type`: ast.Named(tag: "named", span: position, name: name("Header")))
let count = evaluate(ast.Field(tag: "field", span: position,
  `object`: reflected, field: name("count")), bindings,
  initHashSet[string](), types)
doAssert ast.Integer(count).value == "2"
let offset = evaluate(ast.Call(tag: "call", span: position,
  callee: ast.Field(tag: "field", span: position,
    `object`: reflected, field: name("offset")),
  args: @[ast.Expression(ast.Text(tag: "text", span: position,
    value: "count"))]), bindings, initHashSet[string](), types)
doAssert ast.Integer(offset).value == "4"
let fieldName = evaluate(ast.Call(tag: "call", span: position,
  callee: ast.Field(tag: "field", span: position,
    `object`: reflected, field: name("fieldname")),
  args: @[ast.Expression(integer("1"))]), bindings,
  initHashSet[string](), types)
doAssert ast.Text(fieldName).value == "count"
let fieldType = evaluate(ast.Call(tag: "call", span: position,
  callee: ast.Field(tag: "field", span: position,
    `object`: reflected, field: name("fieldtype")),
  args: @[ast.Expression(integer("1"))]), bindings,
  initHashSet[string](), types)
doAssert ast.Text(fieldType).value == "integer 32"
doAssertRaises(ValueError):
  discard evaluate(ast.Call(tag: "call", span: position,
    callee: ast.Field(tag: "field", span: position,
      `object`: reflected, field: name("offset")),
    args: @[ast.Expression(ast.Text(tag: "text", span: position,
      value: "missing"))]), bindings, initHashSet[string](), types)
ast.Record(header.body).layout = ""
doAssertRaises(ValueError):
  discard evaluate(ast.Field(tag: "field", span: position,
    `object`: reflected, field: name("size")), bindings,
    initHashSet[string](), types)
let verified = ast.Verify(tag: "verify", span: position,
  condition: ast.Binary(tag: "binary", span: position, op: "is",
    left: size, right: integer("4")))
let checks = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("checks"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.EvalBlock(tag: "eval", span: position,
        body: ast.Block(tag: "block", span: position,
          stmts: @[ast.Statement(verified)])))
    ]))
])
expand(checks)
doAssert checks.units[0].body.stmts.len == 0
let failure = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("failure"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.EvalBlock(tag: "eval", span: position,
        body: ast.Block(tag: "block", span: position,
          stmts: @[ast.Statement(ast.Verify(tag: "verify", span: position,
            condition: ast.`False`(tag: "false", span: position)))])))
    ]))
])
doAssertRaises(ValueError): expand(failure)

const targetSource = """
define PointerHeader as c record {
  tag of type byte.
  address of type pointer to byte.
}.
eval {
  constant width is reflect[pointer to byte].size.
  constant recordSize is reflect[PointerHeader].size.
  constant offset is reflect[PointerHeader].offset("address").
}
"""
proc targetLayout(target: string): seq[string] =
  let diagnostics = newEngine()
  diagnostics.setSource(targetSource, "target.iv")
  let program = newParser(newLexer(targetSource, diagnostics).lex(),
    diagnostics).parse()
  doAssert not diagnostics.failed
  expand(program, target)
  for statement in program.units[0].body.stmts:
    if statement.tag == "constant":
      result.add(ast.Integer(ast.Constant(statement).value).value)

doAssert targetLayout("wasm32-wasi") == @["4", "8", "4"]
doAssert targetLayout("x86_64-windows-msvc") == @["8", "16", "8"]

echo "IR eval parity: ok"
