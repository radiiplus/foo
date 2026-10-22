import ../../src/sema/link
import ../../src/sema/module as modules
import ../../src/sema/scope
import ../../src/sema/symbol
import ../../src/ast/node as ast
import std/tables
import std/json
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
var units = initTable[string, modules.Unit]()
units["lib"] = modules.Unit(name: "lib", node: imported, scope: scope())
let field = ast.Field(ast.Give(entry.body.stmts[1]).value)
var resolutions = initTable[pointer, Symbol]()
resolutions[cast[pointer](field)] = Symbol(node: imported.body.stmts[0])
let resolution = modules.Resolution(units: units, resolutions: resolutions, order: @["lib"])
let linked = link(Program(tag: "program", units: @[entry]), resolution)
doAssert linked.units[0].body.stmts.len == 2
doAssert linked.units[0].body.stmts[0].tag == "constant"
doAssert ast.Constant(linked.units[0].body.stmts[0]).name.text == "import_0_value"
doAssert ast.Give(linked.units[0].body.stmts[1]).value.tag == "name"
doAssert ast.Name(ast.Give(linked.units[0].body.stmts[1]).value).text == "import_0_value"

let item = ast.Variant(tag: "variant", name: ast.Name(tag: "name", text: "item"),
  payload: ast.Primitive(tag: "primitive", name: "integer", width: "64"))
let choices = ast.Unit(
  tag: "unit", span: Span(), name: ast.Name(tag: "name", text: "choices"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Alias(tag: "alias", public: true,
      name: ast.Name(tag: "name", text: "Result"),
      body: ast.Choice(tag: "choice", variants: @[item])))
  ]))
let label = ast.Name(tag: "name", text: "choices.item")
let pattern = ast.Arm(tag: "variant-pattern", name: label,
  binding: ast.Name(tag: "name", text: "found"))
let matching = ast.Unit(
  tag: "unit", span: Span(), name: ast.Name(tag: "name", text: "matching"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Match(tag: "match", scrutinee: ast.Name(tag: "name", text: "result"),
      cases: @[ast.Case(tag: "case", pattern: pattern,
        body: ast.Block(tag: "block", stmts: @[]))]))
  ]))
var alternatives = initTable[string, modules.Unit]()
alternatives["choices"] = modules.Unit(name: "choices", node: choices, scope: scope())
var selections = initTable[pointer, Symbol]()
selections[cast[pointer](label)] = Symbol(node: item)
let selection = modules.Resolution(units: alternatives,
  resolutions: selections, order: @["choices"])
let choice = link(Program(tag: "program", units: @[matching]), selection)
let alias = ast.Alias(choice.units[0].body.stmts[0])
let assembled = ast.Choice(alias.body).variants[0].name.text
let match = ast.Match(choice.units[0].body.stmts[1])
doAssert assembled == "import_0_item"
doAssert ast.Arm(match.cases[0].pattern).name.text == assembled
echo "semantic link parity: ok"

block moduleGraph:
  let function = ast.Function(tag: "function", public: true,
    name: ast.Name(tag: "name", text: "start"), body: ast.Block(tag: "block"))
  let unit = ast.Unit(tag: "unit", name: ast.Name(tag: "name", text: "main"),
    body: ast.Block(tag: "block", stmts: @[ast.Statement(function)]))
  var imports = initTable[string, string]()
  imports["io"] = "lib.io"
  var units = initTable[string, modules.Unit]()
  units["main"] = modules.Unit(name: "main", package: "app", path: "main.iv",
    imports: imports, scope: scope(), node: unit)
  let output = graph(Resolution(units: units,
    resolutions: initTable[pointer, Symbol](), order: @["main"]))
  doAssert output["format"].getStr == "foo.graph"
  doAssert output["units"][0]["entry"].getBool
  doAssert output["units"][0]["symbols"][0]["visibility"].getStr == "public"
echo "semantic module parity: ok"
