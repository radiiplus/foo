import std/[sequtils, strutils, tables]
import ../../src/ast/node as ast
import ../../src/diag/[engine, span]
import ../../src/types/checker

let position = Span(start: 0, `end`: 1, line: 1, col: 1)
proc name(value: string): ast.Name = ast.Name(tag: "name", span: position, text: value)
proc integerType(): ast.Primitive = ast.Primitive(tag: "primitive", span: position, name: "integer")
proc unsignedType(): ast.Primitive = ast.Primitive(tag: "primitive", span: position, name: "unsigned", width: "64")

let call = ast.Call(tag: "call", span: position, callee: name("add"),
  args: @[ast.Expression(ast.Integer(tag: "integer", span: position, value: "2"))])
let add = ast.Function(tag: "function", span: position, name: name("add"),
  params: @[ast.Parameter(tag: "parameter", span: position, name: name("value"), `type`: integerType())],
  returnType: integerType(), body: ast.Block(tag: "block", span: position, stmts: @[
    ast.Statement(ast.Give(tag: "give", span: position,
      value: ast.Binary(tag: "binary", span: position, op: "plus",
        left: name("value"), right: ast.Integer(tag: "integer", span: position, value: "1"))))
  ]))
let program = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("main"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(add),
      ast.Statement(ast.Constant(tag: "constant", span: position,
        name: name("answer"), `type`: integerType(), value: call))
    ]))
])
let diagnostics = newEngine()
let typeChecker = newChecker(diagnostics)
typeChecker.check(program)
doAssert not diagnostics.failed
doAssert typeChecker.types.hasKey(cast[pointer](add))
doAssert typeChecker.types[cast[pointer](add)].kind == "function"
doAssert typeChecker.types.hasKey(cast[pointer](call))
doAssert typeChecker.types[cast[pointer](call)].name == "integer"

let bad = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("bad"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.Constant(tag: "constant", span: position,
        name: name("wrong"), `type`: integerType(),
        value: ast.Text(tag: "text", span: position, value: "no")))
    ]))
])
let badDiagnostics = newEngine()
newChecker(badDiagnostics).check(bad)
doAssert badDiagnostics.failed
doAssert badDiagnostics.messages[0].text.contains("type mismatch")

let counter = name("counter")
let machineProgram = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("machine"), body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Function(tag: "function", span: position, name: name("start"), body: ast.Block(tag: "block", stmts: @[
      ast.Statement(ast.Mutable(tag: "mutable", span: position, name: counter, `type`: unsignedType(),
        value: ast.Integer(tag: "integer", span: position, value: "0"))),
      ast.Statement(ast.Machine(tag: "machine", span: position, operation: "atomic", target: counter,
        value: ast.Integer(tag: "integer", span: position, value: "1")))
    ])))
  ]))
])
let machineDiagnostics = newEngine()
newChecker(machineDiagnostics).check(machineProgram)
doAssert not machineDiagnostics.failed

let invalidAlignment = ast.Program(tag: "program", span: position, units: @[
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
let alignmentDiagnostics = newEngine()
newChecker(alignmentDiagnostics).check(invalidAlignment)
doAssert alignmentDiagnostics.messages.anyIt("positive constant power of two" in it.text)

let genericType = ast.Named(tag: "named", span: position, name: name("T"))
let identity = ast.Function(tag: "function", span: position, name: name("identity"),
  typeParams: @[ast.TypeParam(tag: "type-param", span: position, name: name("T"))],
  params: @[ast.Parameter(tag: "parameter", span: position, name: name("value"), `type`: genericType)],
  returnType: genericType, body: ast.Block(tag: "block", span: position, stmts: @[
    ast.Statement(ast.Give(tag: "give", span: position, value: name("value")))
  ]))
let identityCall = ast.Call(tag: "call", span: position, callee: name("identity"),
  args: @[ast.Expression(ast.Integer(tag: "integer", span: position, value: "7"))])
let genericProgram = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("generic"), body: ast.Block(tag: "block", stmts: @[
    ast.Statement(identity),
    ast.Statement(ast.Constant(tag: "constant", span: position, name: name("seven"), value: identityCall))
  ]))
])
let genericDiagnostics = newEngine()
let genericChecker = newChecker(genericDiagnostics)
genericChecker.check(genericProgram)
doAssert not genericDiagnostics.failed
doAssert genericChecker.types[cast[pointer](identityCall)].name == "integer"

let splatCall = ast.Call(tag: "call", span: position, callee: name("splat"),
  args: @[ast.Expression(ast.Decimal(tag: "decimal", span: position, value: "2.0"))])
let reduceCall = ast.Call(tag: "call", span: position, callee: name("reduce"), args: @[
  ast.Expression(name("lanes")), ast.Expression(ast.Text(tag: "text", span: position, value: "add"))])
let vectorType = ast.Vector(tag: "vector", span: position, length: "4",
  elem: ast.Primitive(tag: "primitive", span: position, name: "decimal", width: "64"))
let vectorProgram = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("vectors"), body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Constant(tag: "constant", span: position, name: name("lanes"),
      `type`: vectorType, value: splatCall)),
    ast.Statement(ast.Constant(tag: "constant", span: position, name: name("sum"), value: reduceCall))
  ]))
])
let vectorDiagnostics = newEngine()
newChecker(vectorDiagnostics).check(vectorProgram)
doAssert not vectorDiagnostics.failed

let cleanupProgram = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("cleanup"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.Function(tag: "function", span: position,
        name: name("badCleanup"), returnType: integerType(),
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
let cleanupDiagnostics = newEngine()
newChecker(cleanupDiagnostics).check(cleanupProgram)
doAssert cleanupDiagnostics.messages.anyIt("cleanup block cannot return" in it.text)

let externProgram = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("extern"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.ExternFunction(tag: "extern-function", span: position,
        name: name("bad"), symbol: "bad", abi: "c",
        params: @[ast.Parameter(tag: "parameter", span: position,
          name: name("value"), `type`: ast.Primitive(tag: "primitive",
            span: position, name: "text"))],
        returnType: ast.Primitive(tag: "primitive", span: position,
          name: "nothing")))
    ]))
])
let externDiagnostics = newEngine()
newChecker(externDiagnostics).check(externProgram)
doAssert externDiagnostics.messages.anyIt("not safe to pass by value" in it.text)

echo "type checker parity: ok"
