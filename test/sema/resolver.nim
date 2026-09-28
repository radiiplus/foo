import std/[os, strutils, tables]
import ../../src/ast/node as ast
import ../../src/diag/[engine, span]
import ../../src/sema/[form, resolver]

let position = Span(start: 0, `end`: 1, line: 1, col: 1)
proc name(value: string): ast.Name = ast.Name(tag: "name", span: position, text: value)

let parameterUse = name("input")
let globalUse = name("answer")
let function = ast.Function(tag: "function", span: position, public: true,
  name: name("compute"),
  params: @[ast.Parameter(tag: "parameter", span: position,
    name: name("input"), `type`: ast.Primitive(tag: "primitive", name: "integer"))],
  body: ast.Block(tag: "block", span: position, stmts: @[
    ast.Statement(ast.Give(tag: "give", span: position,
      value: ast.Binary(tag: "binary", span: position, op: "plus",
        left: parameterUse, right: globalUse)))
  ]))
let constant = ast.Constant(tag: "constant", span: position, public: true,
  name: name("answer"), value: ast.Integer(tag: "integer", span: position, value: "42"))
let program = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("main"),
    body: ast.Block(tag: "block", span: position,
      stmts: @[ast.Statement(constant), ast.Statement(function)]))
])

let diagnostics = newEngine()
let resolution = newResolver(diagnostics, getCurrentDir()).resolve(program, "main")
doAssert not diagnostics.failed
doAssert resolution.units.len == 1
doAssert resolution.order.len == 1
doAssert resolution.resolutions.hasKey(cast[pointer](parameterUse))
doAssert resolution.resolutions[cast[pointer](parameterUse)].form == Form.Parameter
doAssert resolution.resolutions.hasKey(cast[pointer](globalUse))
doAssert resolution.resolutions[cast[pointer](globalUse)].qualified.endsWith("::answer")

let duplicate = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("duplicate"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.Constant(tag: "constant", span: position, name: name("same"), value: ast.Integer(tag: "integer", value: "1"))),
      ast.Statement(ast.Mutable(tag: "mutable", span: position, name: name("same"), value: ast.Integer(tag: "integer", value: "2")))
    ]))
])
let duplicateDiagnostics = newEngine()
discard newResolver(duplicateDiagnostics, getCurrentDir()).resolve(duplicate, "duplicate")
doAssert duplicateDiagnostics.failed
doAssert duplicateDiagnostics.messages[0].text == "duplicate symbol 'same'"

let importedField = ast.Field(tag: "field", span: position,
  `object`: name("lib"), field: name("answer"))
let importing = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("main"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.Use(tag: "use", span: position, name: name("lib"))),
      ast.Statement(ast.Give(tag: "give", span: position, value: importedField))
    ]))
])
proc readModule(path: string): ReadResult =
  if path.endsWith("lib.iv"): (true, "library") else: (false, "")
proc parseModule(path, source: string; diagnostics: Engine): ast.Program =
  ast.Program(tag: "program", span: position, units: @[
    ast.Unit(tag: "unit", span: position, name: name("lib"), file: path,
      body: ast.Block(tag: "block", span: position, stmts: @[
        ast.Statement(ast.Constant(tag: "constant", span: position,
          public: true, name: name("answer"),
          value: ast.Integer(tag: "integer", value: "42")))
      ]))
  ])
let importDiagnostics = newEngine()
let importedResolution = newResolver(importDiagnostics, getCurrentDir(),
  read = readModule, parse = parseModule).resolve(importing, "main")
doAssert not importDiagnostics.failed
doAssert importedResolution.units.len == 2
doAssert importedResolution.resolutions.hasKey(cast[pointer](importedField))
doAssert importedResolution.resolutions[cast[pointer](importedField)].qualified.endsWith("::answer")

let packageField = ast.Field(tag: "field", span: position,
  `object`: name("package"), field: name("answer"))
let packageImport = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("main"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.Use(tag: "use", span: position, name: name("lib"), alias: name("package"))),
      ast.Statement(ast.Give(tag: "give", span: position, value: packageField))
    ]))
])
proc readPackage(path: string): ReadResult =
  let normalized = path.replace('\\', '/')
  if normalized.endsWith("/.foo/packages/lib/project.json"):
    (true, "{\"source\":\"source\"}")
  elif normalized.endsWith("/.foo/packages/lib/source/main.iv"):
    (true, "library")
  else:
    (false, "")
let packageDiagnostics = newEngine()
let packageResolution = newResolver(packageDiagnostics, getCurrentDir(),
  read = readPackage, parse = parseModule).resolve(packageImport, "main")
doAssert not packageDiagnostics.failed
doAssert packageResolution.units.len == 2
doAssert packageResolution.resolutions.hasKey(cast[pointer](packageField))
doAssert packageResolution.resolutions[cast[pointer](packageField)].qualified.endsWith("::answer")

let exportedField = ast.Field(tag: "field", span: position,
  `object`: name("facade"), field: name("answer"))
let reexporting = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("main"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.Use(tag: "use", span: position, name: name("facade"))),
      ast.Statement(ast.Give(tag: "give", span: position, value: exportedField))
    ]))
])
proc readReexport(path: string): ReadResult =
  if path.endsWith("facade.iv") or path.endsWith("lib.iv"): (true, "module")
  else: (false, "")
proc parseReexport(path, source: string; diagnostics: Engine): ast.Program =
  if path.endsWith("facade.iv"):
    ast.Program(tag: "program", span: position, units: @[
      ast.Unit(tag: "unit", span: position, name: name("facade"), file: path,
        body: ast.Block(tag: "block", span: position, stmts: @[
          ast.Statement(ast.Use(tag: "use", span: position, public: true,
            name: name("lib")))
        ]))
    ])
  else:
    parseModule(path, source, diagnostics)
let reexportDiagnostics = newEngine()
let reexportResolution = newResolver(reexportDiagnostics, getCurrentDir(),
  read = readReexport, parse = parseReexport).resolve(reexporting, "main")
doAssert not reexportDiagnostics.failed
doAssert reexportResolution.units.len == 3
doAssert reexportResolution.resolutions.hasKey(cast[pointer](exportedField))
doAssert reexportResolution.resolutions[cast[pointer](exportedField)].qualified.endsWith("::answer")

let choicePatternName = name("model.item")
let choiceProgram = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("main"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.Use(tag: "use", span: position, name: name("choice"),
        alias: name("model"))),
      ast.Statement(ast.Match(tag: "match", span: position,
        scrutinee: name("result"), cases: @[
          ast.Case(tag: "case", span: position,
            pattern: ast.VariantPattern(tag: "variant-pattern", span: position,
              name: choicePatternName, binding: name("found")),
            body: ast.Block(tag: "block", span: position, stmts: @[]))
        ]))
    ]))
])
proc readChoice(path: string): ReadResult =
  if path.endsWith("choice.iv"): (true, "choice") else: (false, "")
proc parseChoice(path, source: string; diagnostics: Engine): ast.Program =
  let variant = ast.Variant(tag: "variant", span: position, name: name("item"),
    payload: ast.Primitive(tag: "primitive", span: position,
      name: "integer", width: "64"))
  ast.Program(tag: "program", span: position, units: @[
    ast.Unit(tag: "unit", span: position, name: name("choice"), file: path,
      body: ast.Block(tag: "block", span: position, stmts: @[
        ast.Statement(ast.Alias(tag: "alias", span: position, public: true,
          name: name("Result"), body: ast.Choice(tag: "choice",
            span: position, variants: @[variant])))
      ]))
  ])
let choiceDiagnostics = newEngine()
let choiceResolution = newResolver(choiceDiagnostics, getCurrentDir(),
  read = readChoice, parse = parseChoice).resolve(choiceProgram, "main")
doAssert choiceResolution.resolutions.hasKey(cast[pointer](choicePatternName))
doAssert choiceResolution.resolutions[cast[pointer](choicePatternName)].qualified.endsWith("::item")

echo "semantic resolver parity: ok"
