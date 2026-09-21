import ../../src/ast/node

let name = Name(tag: "name", text: "answer")
let value = Integer(tag: "integer", value: "42")
let declaration = Constant(tag: "constant", public: true, name: name, value: value)
let body = Block(tag: "block", stmts: @[Statement(declaration)])
let unit = Unit(tag: "unit", name: Name(tag: "name", text: "main"), body: body)
let program = Program(tag: "program", units: @[unit])

doAssert program.units[0].body.stmts.len == 1
doAssert Constant(program.units[0].body.stmts[0]).name.text == "answer"
echo "ast node parity: ok"
