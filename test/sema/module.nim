import std/tables
import std/json
import ../../src/sema/module as semaModule
import ../../src/sema/scope
import ../../src/sema/symbol
import ../../src/ast/node as ast

let startFunction = ast.Function(tag: "function", public: true, name: ast.Name(tag: "name", text: "start"), body: ast.Block(tag: "block"))
let astUnit = ast.Unit(tag: "unit", name: ast.Name(tag: "name", text: "main"), body: ast.Block(tag: "block", stmts: @[ast.Statement(startFunction)]))
var imports = initTable[string, string]()
imports["io"] = "std.io"
var units = initTable[string, semaModule.Unit]()
units["main"] = semaModule.Unit(name: "main", package: "app", path: "main.iv", imports: imports, scope: newScope(), node: astUnit)
let output = graph(Resolution(units: units, resolutions: initTable[pointer, Symbol](), order: @["main"]))
doAssert output["format"].getStr == "foo.graph"
doAssert output["units"][0]["entry"].getBool
doAssert output["units"][0]["symbols"][0]["visibility"].getStr == "public"
echo "semantic module parity: ok"
