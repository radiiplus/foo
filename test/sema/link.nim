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

let item = ast.Variant(tag: "variant", name: ast.Name(tag: "name", text: "item"),
  payload: ast.Primitive(tag: "primitive", name: "integer", width: "64"))
let choices = ast.Unit(
  tag: "unit", span: Span(), name: ast.Name(tag: "name", text: "choices"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Alias(tag: "alias", public: true,
      name: ast.Name(tag: "name", text: "Result"),
      body: ast.Choice(tag: "choice", variants: @[item])))
  ]))
let patternName = ast.Name(tag: "name", text: "choices.item")
let pattern = ast.VariantPattern(tag: "variant-pattern", name: patternName,
  binding: ast.Name(tag: "name", text: "found"))
let matching = ast.Unit(
  tag: "unit", span: Span(), name: ast.Name(tag: "name", text: "matching"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Match(tag: "match", scrutinee: ast.Name(tag: "name", text: "result"),
      cases: @[ast.Case(tag: "case", pattern: pattern,
        body: ast.Block(tag: "block", stmts: @[]))]))
  ]))
var choiceUnits = initTable[string, semaModule.Unit]()
choiceUnits["choices"] = semaModule.Unit(name: "choices", node: choices, scope: newScope())
var choiceResolutions = initTable[pointer, Symbol]()
choiceResolutions[cast[pointer](patternName)] = Symbol(node: item)
let choiceResolution = semaModule.Resolution(units: choiceUnits,
  resolutions: choiceResolutions, order: @["choices"])
let choiceLinked = link(Program(tag: "program", units: @[matching]), choiceResolution)
let linkedAlias = ast.Alias(choiceLinked.units[0].body.stmts[0])
let linkedItem = ast.Choice(linkedAlias.body).variants[0].name.text
let linkedMatch = ast.Match(choiceLinked.units[0].body.stmts[1])
doAssert linkedItem == "import_0_item"
doAssert ast.VariantPattern(linkedMatch.cases[0].pattern).name.text == linkedItem
echo "semantic link parity: ok"
