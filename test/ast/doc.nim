import ../../src/ast/node
import ../../src/ast/doc

let publicConstant = Constant(
  tag: "constant", public: true, name: Name(tag: "name", text: "answer"),
  `type`: Primitive(tag: "primitive", name: "integer", width: "64"),
  value: Integer(tag: "integer", value: "42"))
let privateConstant = Constant(
  tag: "constant", public: false, name: Name(tag: "name", text: "hidden"),
  value: Integer(tag: "integer", value: "0"))
let publicFunction = Function(
  tag: "function", public: true, name: Name(tag: "name", text: "identity"),
  params: @[Parameter(tag: "parameter", name: Name(tag: "name", text: "value"),
    `type`: Primitive(tag: "primitive", name: "integer", width: "64"))],
  returnType: Primitive(tag: "primitive", name: "integer", width: "64"),
  body: Block(tag: "block", stmts: @[]))
let program = Program(tag: "program", units: @[
  Unit(tag: "unit", name: Name(tag: "name", text: "main"),
    body: Block(tag: "block", stmts: @[Statement(publicConstant),
      Statement(privateConstant), Statement(publicFunction)]))
])

doAssert doc(program) == "public constant answer of type integer.\n" &
  "public function identity(value integer) giving integer.\n"
echo "ast doc parity: ok"
