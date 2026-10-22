import std/[os, strutils, tables]
import ../../src/ast/node as ast
import ../../src/diag/[engine, span]
import ../../src/sema/[form, resolver]
import ../../src/config/project as configuration
import std/json

let position = Span(start: 0, `end`: 1, line: 1, col: 1)
proc name(value: string): ast.Name = ast.Name(tag: "name", span: position, text: value)

let parameter = name("input")
let use = name("answer")
let function = ast.Function(tag: "function", span: position, public: true,
  name: name("compute"),
  params: @[ast.Parameter(tag: "parameter", span: position,
    name: name("input"), `type`: ast.Primitive(tag: "primitive", name: "integer"))],
  body: ast.Block(tag: "block", span: position, stmts: @[
    ast.Statement(ast.Give(tag: "give", span: position,
      value: ast.Binary(tag: "binary", span: position, op: "plus",
        left: parameter, right: use)))
  ]))
let constant = ast.Constant(tag: "constant", span: position, public: true,
  name: name("answer"), value: ast.Integer(tag: "integer", span: position, value: "42"))
let program = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("main"),
    body: ast.Block(tag: "block", span: position,
      stmts: @[ast.Statement(constant), ast.Statement(function)]))
])

let diagnostics = engine()
let resolution = resolver(diagnostics, getCurrentDir()).resolve(program, "main")
doAssert not diagnostics.failed
doAssert resolution.units.len == 1
doAssert resolution.order.len == 1
doAssert resolution.resolutions.hasKey(cast[pointer](parameter))
doAssert resolution.resolutions[cast[pointer](parameter)].form == Form.Parameter
doAssert resolution.resolutions.hasKey(cast[pointer](use))
doAssert resolution.resolutions[cast[pointer](use)].qualified.endsWith("::answer")

let duplicate = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("duplicate"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.Constant(tag: "constant", span: position, name: name("same"), value: ast.Integer(tag: "integer", value: "1"))),
      ast.Statement(ast.Mutable(tag: "mutable", span: position, name: name("same"), value: ast.Integer(tag: "integer", value: "2")))
    ]))
])
let faults = engine()
discard resolver(faults, getCurrentDir()).resolve(duplicate, "duplicate")
doAssert faults.failed
doAssert faults.messages[0].text == "duplicate symbol 'same'"

let component = ast.Field(tag: "field", span: position,
  `object`: name("lib"), field: name("answer"))
let importing = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("main"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.Use(tag: "use", span: position, name: name("lib"))),
      ast.Statement(ast.Give(tag: "give", span: position, value: component))
    ]))
])
proc read(path: string): Reading =
  if path.endsWith("lib.iv"): (true, "library") else: (false, "")
proc decode(path, source: string; diagnostics: Engine): ast.Program =
  ast.Program(tag: "program", span: position, units: @[
    ast.Unit(tag: "unit", span: position, name: name("lib"), file: path,
      body: ast.Block(tag: "block", span: position, stmts: @[
        ast.Statement(ast.Constant(tag: "constant", span: position,
          public: true, name: name("answer"),
          value: ast.Integer(tag: "integer", value: "42")))
      ]))
  ])
let imports = engine()
let imported = resolver(imports, getCurrentDir(),
  read = read, parse = decode).resolve(importing, "main")
doAssert not imports.failed
doAssert imported.units.len == 2
doAssert imported.resolutions.hasKey(cast[pointer](component))
doAssert imported.resolutions[cast[pointer](component)].qualified.endsWith("::answer")

let attribute = ast.Field(tag: "field", span: position,
  `object`: name("package"), field: name("answer"))
let dependency = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("main"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.Use(tag: "use", span: position, name: name("lib"), alias: name("package"))),
      ast.Statement(ast.Give(tag: "give", span: position, value: attribute))
    ]))
])
proc package(path: string): Reading =
  let normalized = path.replace('\\', '/')
  if normalized.endsWith("/.foo/packages/lib/source/main.iv"):
    (true, "library")
  else:
    (false, "")
let packageRoot = getTempDir() / "foo-sema-package-test"
if dirExists(packageRoot): removeDir(packageRoot)
createDir(packageRoot / ".foo" / "packages" / "lib" / "source")
configuration.writeProject(packageRoot / ".foo" / "packages" / "lib",
  %*{"name": "lib", "version": "0.1.0", "source": "source"})
let packaging = engine()
let resolved = resolver(packaging, packageRoot,
  read = package, parse = decode).resolve(dependency, "main")
doAssert not packaging.failed
doAssert resolved.units.len == 2
doAssert resolved.resolutions.hasKey(cast[pointer](attribute))
doAssert resolved.resolutions[cast[pointer](attribute)].qualified.endsWith("::answer")
removeDir(packageRoot)

let member = ast.Field(tag: "field", span: position,
  `object`: name("facade"), field: name("answer"))
let reexporting = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("main"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.Use(tag: "use", span: position, name: name("facade"))),
      ast.Statement(ast.Give(tag: "give", span: position, value: member))
    ]))
])
proc forward(path: string): Reading =
  if path.endsWith("facade.iv") or path.endsWith("lib.iv"): (true, "module")
  else: (false, "")
proc parse(path, source: string; diagnostics: Engine): ast.Program =
  if path.endsWith("facade.iv"):
    ast.Program(tag: "program", span: position, units: @[
      ast.Unit(tag: "unit", span: position, name: name("facade"), file: path,
        body: ast.Block(tag: "block", span: position, stmts: @[
          ast.Statement(ast.Use(tag: "use", span: position, public: true,
            name: name("lib")))
        ]))
    ])
  else:
    decode(path, source, diagnostics)
let reexport = engine()
let forwarded = resolver(reexport, getCurrentDir(),
  read = forward, parse = parse).resolve(reexporting, "main")
doAssert not reexport.failed
doAssert forwarded.units.len == 3
doAssert forwarded.resolutions.hasKey(cast[pointer](member))
doAssert forwarded.resolutions[cast[pointer](member)].qualified.endsWith("::answer")

let label = name("model.item")
let choice = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("main"),
    body: ast.Block(tag: "block", span: position, stmts: @[
      ast.Statement(ast.Use(tag: "use", span: position, name: name("choice"),
        alias: name("model"))),
      ast.Statement(ast.Match(tag: "match", span: position,
        scrutinee: name("result"), cases: @[
          ast.Case(tag: "case", span: position,
            pattern: ast.Arm(tag: "variant-pattern", span: position,
              name: label, binding: name("found")),
            body: ast.Block(tag: "block", span: position, stmts: @[]))
        ]))
    ]))
])
proc select(path: string): Reading =
  if path.endsWith("choice.iv"): (true, "choice") else: (false, "")
proc choose(path, source: string; diagnostics: Engine): ast.Program =
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
let issues = engine()
let selection = resolver(issues, getCurrentDir(),
  read = select, parse = choose).resolve(choice, "main")
doAssert selection.resolutions.hasKey(cast[pointer](label))
doAssert selection.resolutions[cast[pointer](label)].qualified.endsWith("::item")

echo "semantic resolver parity: ok"
