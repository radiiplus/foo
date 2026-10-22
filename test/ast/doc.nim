import ../../src/ast/node
import ../../src/ast/doc

let fixed = Constant(
  tag: "constant", public: true, name: Name(tag: "name", text: "answer"),
  `type`: Primitive(tag: "primitive", name: "integer", width: "64"),
  value: Integer(tag: "integer", value: "42"))
let constant = Constant(
  tag: "constant", public: false, name: Name(tag: "name", text: "hidden"),
  value: Integer(tag: "integer", value: "0"))
let function = Function(
  tag: "function", public: true, name: Name(tag: "name", text: "identity"),
  params: @[Parameter(tag: "parameter", name: Name(tag: "name", text: "value"),
    `type`: Primitive(tag: "primitive", name: "integer", width: "64"))],
  returns: Primitive(tag: "primitive", name: "integer", width: "64"),
  body: Block(tag: "block", stmts: @[]))
let program = Program(tag: "program", units: @[
  Unit(tag: "unit", name: Name(tag: "name", text: "main"),
    body: Block(tag: "block", stmts: @[Statement(fixed),
      Statement(constant), Statement(function)]))
])

doAssert doc(program) == "public constant answer of type integer.\n" &
  "public function identity(value integer) giving integer.\n"
echo "ast doc parity: ok"
