import ../../src/sema/link
import ../../src/sema/module as semaModule
import ../../src/sema/scope
import ../../src/sema/symbol
import ../../src/ast/node as ast
import std/tables
import ../../src/diag/span

let imported = ast.Unit(
  tag: "unit", span: Span(), name: ast.Name(tag: "name", text: "lib"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Constant(tag: "constant", public: true,
      name: ast.Name(tag: "name", text: "value"), value: ast.Integer(tag: "integer", value: "1")))
  ]))
let entry = ast.Unit(
  tag: "unit", span: Span(), name: ast.Name(tag: "name", text: "main"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Use(tag: "use", name: ast.Name(tag: "name", text: "lib"))),
    ast.Statement(ast.Give(tag: "give", value: ast.Field(tag: "field",
      `object`: ast.Name(tag: "name", text: "lib"), field: ast.Name(tag: "name", text: "value"))))
  ]))
var units = initTable[string, semaModule.Unit]()
units["lib"] = semaModule.Unit(name: "lib", node: imported, scope: newScope())
let field = ast.Field(ast.Give(entry.body.stmts[1]).value)
var resolutions = initTable[pointer, Symbol]()
resolutions[cast[pointer](field)] = Symbol(node: imported.body.stmts[0])
let resolution = semaModule.Resolution(units: units, resolutions: resolutions, order: @["lib"])
let linked = link(Program(tag: "program", units: @[entry]), resolution)
doAssert linked.units[0].body.stmts.len == 2
doAssert linked.units[0].body.stmts[0].tag == "constant"
doAssert ast.Constant(linked.units[0].body.stmts[0]).name.text == "import_0_value"
doAssert ast.Give(linked.units[0].body.stmts[1]).value.tag == "name"
doAssert ast.Name(ast.Give(linked.units[0].body.stmts[1]).value).text == "import_0_value"
echo "semantic link parity: ok"
