import ../../src/ast/node
import ../../src/ast/doc

let publicConstant = Constant(
  tag: "constant", public: true, name: Name(tag: "name", text: "answer"),
  `type`: Primitive(tag: "primitive", name: "integer", width: "64"),
  value: Integer(tag: "integer", value: "42"))
let privateConstant = Constant(
  tag: "constant", public: false, name: Name(tag: "name", text: "hidden"),
  value: Integer(tag: "integer", value: "0"))
let program = Program(tag: "program", units: @[
  Unit(tag: "unit", name: Name(tag: "name", text: "main"),
    body: Block(tag: "block", stmts: @[Statement(publicConstant), Statement(privateConstant)]))
])

doAssert doc(program) == "public constant answer of type integer 64.\n"
echo "ast doc parity: ok"
