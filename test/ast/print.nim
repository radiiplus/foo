import ../../src/ast/node
import ../../src/ast/print

let unsigned64 = Primitive(tag: "primitive", name: "unsigned", width: "64")
let answer = Function(
  tag: "function",
  public: true,
  name: Name(tag: "name", text: "answer"),
  returnType: unsigned64,
  body: Block(tag: "block", stmts: @[
    Statement(Give(tag: "give", value: Integer(tag: "integer", value: "42")))
  ]))

doAssert print(answer) == "public function answer() giving unsigned 64 {\n  give 42.\n}"
doAssert print(Text(tag: "text", value: "left\nright")) == "(\"left\" plus newline plus \"right\")"
echo "ast print parity: ok"
