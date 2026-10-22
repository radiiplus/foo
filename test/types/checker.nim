import std/[sequtils, strutils, tables]
import ../../src/ast/node as ast
import ../../src/diag/[engine, span]
import ../../src/types/checker
import ../../src/types/exhaust
import ../../src/types/type as types
import ../../src/diag/code

let position = Span(start: 0, `end`: 1, line: 1, col: 1)
proc name(value: string): ast.Name = ast.Name(tag: "name", span: position, text: value)
proc integer(): ast.Primitive = ast.Primitive(tag: "primitive", span: position, name: "integer")
proc natural(): ast.Primitive = ast.Primitive(tag: "primitive", span: position, name: "unsigned", width: "64")

let call = ast.Call(tag: "call", span: position, callee: name("add"),
  args: @[ast.Expression(ast.Integer(tag: "integer", span: position, value: "2"))])
let add = ast.Function(tag: "function", span: position, name: name("add"),
  params: @[ast.Parameter(tag: "parameter", span: position, name: name("value"), `type`: integer())],
  returns: integer(), body: ast.Block(tag: "block", span: position, stmts: @[
    ast.Statement(ast.Give(tag: "give", span: position,
      value: ast.Binary(tag: "binary", span: position, op: "plus",
        left: name("value"), right: ast.Integer(tag: "integer", span: position, value: "1"))))
  ]))
let program = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("main"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(add),
      ast.Statement(ast.Constant(tag: "constant", span: position,
        name: name("answer"), `type`: integer(), value: call))
    ]))
])
let diagnostics = engine()
let checking = checker(diagnostics)
checking.check(program)
doAssert not diagnostics.failed
doAssert checking.types.hasKey(cast[pointer](add))
doAssert checking.types[cast[pointer](add)].kind == "function"
doAssert checking.types.hasKey(cast[pointer](call))
doAssert checking.types[cast[pointer](call)].name == "integer"

let bad = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("bad"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.Constant(tag: "constant", span: position,
        name: name("wrong"), `type`: integer(),
        value: ast.Text(tag: "text", span: position, value: "no")))
    ]))
])
let faults = engine()
checker(faults).check(bad)
doAssert faults.failed
doAssert faults.messages[0].text.contains("type mismatch")

let counter = name("counter")
let hardware = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("machine"), body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Function(tag: "function", span: position, name: name("start"), body: ast.Block(tag: "block", stmts: @[
      ast.Statement(ast.Mutable(tag: "mutable", span: position, name: counter, `type`: natural(),
        value: ast.Integer(tag: "integer", span: position, value: "0"))),
      ast.Statement(ast.Machine(tag: "machine", span: position, operation: "atomic", target: counter,
        value: ast.Integer(tag: "integer", span: position, value: "1")))
    ])))
  ]))
])
let machine = engine()
checker(machine).check(hardware)
doAssert not machine.failed

let alignment = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("alignment"), body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Function(tag: "function", span: position, name: name("start"), body: ast.Block(tag: "block", stmts: @[
      ast.Statement(ast.Mutable(tag: "mutable", span: position, name: name("buffer"),
        `type`: ast.Sequence(tag: "sequence", span: position, elem: ast.Primitive(tag: "primitive", name: "byte")),
        value: ast.Uninitialized(tag: "uninitialized", span: position))),
      ast.Statement(ast.Machine(tag: "machine", span: position, operation: "align", target: name("buffer"),
        value: ast.Integer(tag: "integer", span: position, value: "3")))
    ])))
  ]))
])
let issues = engine()
checker(issues).check(alignment)
doAssert issues.messages.anyIt("positive constant power of two" in it.text)

let representation = ast.Named(tag: "named", span: position, name: name("T"))
let identity = ast.Function(tag: "function", span: position, name: name("identity"),
  generics: @[ast.Generic(tag: "type-param", span: position, name: name("T"))],
  params: @[ast.Parameter(tag: "parameter", span: position, name: name("value"), `type`: representation)],
  returns: representation, body: ast.Block(tag: "block", span: position, stmts: @[
    ast.Statement(ast.Give(tag: "give", span: position, value: name("value")))
  ]))
let invocation = ast.Call(tag: "call", span: position, callee: name("identity"),
  args: @[ast.Expression(ast.Integer(tag: "integer", span: position, value: "7"))])
let polymorphic = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("generic"), body: ast.Block(tag: "block", stmts: @[
    ast.Statement(identity),
    ast.Statement(ast.Constant(tag: "constant", span: position, name: name("seven"), value: invocation))
  ]))
])
let polymorphism = engine()
let generic = checker(polymorphism)
generic.check(polymorphic)
doAssert not polymorphism.failed
doAssert generic.types[cast[pointer](invocation)].name == "integer"

let splat = ast.Call(tag: "call", span: position, callee: name("splat"),
  args: @[ast.Expression(ast.Decimal(tag: "decimal", span: position, value: "2.0"))])
let reduce = ast.Call(tag: "call", span: position, callee: name("reduce"), args: @[
  ast.Expression(name("lanes")), ast.Expression(ast.Text(tag: "text", span: position, value: "add"))])
let member = ast.Vector(tag: "vector", span: position, length: "4",
  elem: ast.Primitive(tag: "primitive", span: position, name: "decimal", width: "64"))
let simd = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("vectors"), body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Constant(tag: "constant", span: position, name: name("lanes"),
      `type`: member, value: splat)),
    ast.Statement(ast.Constant(tag: "constant", span: position, name: name("sum"), value: reduce))
  ]))
])
let vector = engine()
checker(vector).check(simd)
doAssert not vector.failed

let teardown = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("cleanup"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.Function(tag: "function", span: position,
        name: name("invalid"), returns: integer(),
        body: ast.Block(tag: "block", span: position, stmts: @[
          ast.Statement(ast.`Defer`(tag: "defer", span: position,
            body: ast.Block(tag: "block", span: position, stmts: @[
              ast.Statement(ast.Give(tag: "give", span: position,
                value: ast.Integer(tag: "integer", span: position, value: "1")))
            ]))),
          ast.Statement(ast.Give(tag: "give", span: position,
            value: ast.Integer(tag: "integer", span: position, value: "2")))
        ])))
    ]))
])
let cleanup = engine()
checker(cleanup).check(teardown)
doAssert cleanup.messages.anyIt("cleanup block cannot return" in it.text)

let foreign = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("extern"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.External(tag: "extern-function", span: position,
        name: name("bad"), symbol: "bad", abi: "c",
        params: @[ast.Parameter(tag: "parameter", span: position,
          name: name("value"), `type`: ast.Primitive(tag: "primitive",
            span: position, name: "text"))],
        returns: ast.Primitive(tag: "primitive", span: position,
          name: "nothing")))
    ]))
])
let extern = engine()
checker(extern).check(foreign)
doAssert extern.messages.anyIt("not safe to pass by value" in it.text)

let signed = ast.Optional(tag: "optional", span: position,
  elem: integer())
let nullable = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("optional"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.Constant(tag: "constant", span: position,
        name: name("missing"), `type`: signed,
        value: ast.Null(tag: "null", span: position)))
    ]))
])
let null = engine()
checker(null).check(nullable)
doAssert not null.failed

let untyped = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("invalid"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.Constant(tag: "constant", span: position,
        name: name("missing"), value: ast.Null(tag: "null", span: position)))
    ]))
])
let ambiguity = engine()
checker(ambiguity).check(untyped)
doAssert ambiguity.messages.anyIt(
  "null needs an expected optional type" in it.text)

let shape = ast.Alias(tag: "alias", span: position, name: name("Person"),
  body: ast.Record(tag: "record", span: position, fields: @[
    ast.Member(tag: "member", span: position, name: name("name"),
      `type`: ast.Primitive(tag: "primitive", span: position, name: "text")),
    ast.Member(tag: "member", span: position, name: name("age"),
      `type`: integer())
  ]))
let execution = ast.Call(tag: "call", span: position,
  callee: name("Person"), names: @["age", "name"], args: @[
    ast.Expression(ast.Integer(tag: "integer", span: position, value: "42")),
    ast.Expression(ast.Text(tag: "text", span: position, value: "Ada"))
  ])
let structured = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("records"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(shape),
      ast.Statement(ast.Constant(tag: "constant", span: position,
        name: name("person"), value: execution))
    ]))
])
let record = engine()
checker(record).check(structured)
doAssert not record.failed
doAssert ast.Text(execution.args[0]).value == "Ada"
doAssert ast.Integer(execution.args[1]).value == "42"

proc container(): ast.Instantiation = ast.Instantiation(tag: "generic-inst",
  span: position, name: name("Box"), args: @[ast.`Type`(natural())])
let some = ast.Call(tag: "call", span: position, callee: name("some"),
  types: @[ast.`Type`(natural())], args: @[
    ast.Expression(ast.Integer(tag: "integer", span: position, value: "42"))])
let application = ast.Call(tag: "call", span: position, callee: name("none"),
  types: @[ast.`Type`(natural())], args: @[])
let operand = name("none")
let box = ast.Alias(tag: "alias", span: position, name: name("Box"),
  generics: @[ast.Generic(tag: "type-param", span: position,
    name: name("T"))], body: ast.Choice(tag: "choice", span: position,
    variants: @[
      ast.Variant(tag: "variant", span: position, name: name("some"),
        payload: ast.Named(tag: "named", span: position, name: name("T"))),
      ast.Variant(tag: "variant", span: position, name: name("none"))
    ]))
let choosing = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("choices"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(box),
      ast.Statement(ast.Constant(tag: "constant", span: position,
        name: name("present"), `type`: container(), value: some)),
      ast.Statement(ast.Constant(tag: "constant", span: position,
        name: name("absent"), `type`: container(), value: application)),
      ast.Statement(ast.Constant(tag: "constant", span: position,
        name: name("contextual"), `type`: container(), value: operand))
    ]))
])
let alternatives = engine()
let choice = checker(alternatives)
choice.check(choosing)
doAssert not alternatives.failed,
  if alternatives.messages.len > 0:
    alternatives.messages[0].text else: "generic choice check failed"
doAssert choice.types[cast[pointer](some)].name == "Box[unsigned]"
doAssert choice.types[cast[pointer](application)].name == "Box[unsigned]"
doAssert choice.types[cast[pointer](operand)].name == "Box[unsigned]"

echo "type checker parity: ok"

block exhaustiveness:
  let diagnostics = engine()
  let boolean = types.Type(kind: "primitive", name: "boolean")
  let positive = ast.Case(tag: "case", pattern: ast.True(tag: "true"))
  exhaust(boolean, @[positive], Span(line: 1, col: 1), diagnostics)
  doAssert diagnostics.failed
  doAssert diagnostics.messages[0].code == Code.NonExhaustive
echo "exhaustiveness parity: ok"
