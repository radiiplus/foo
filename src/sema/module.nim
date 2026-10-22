import std/tables
import std/algorithm
import std/json
import ../ast/node as ast
import ./scope
import ./symbol

type
  Unit* = object
    name*: string
    package*: string
    path*: string
    file*: string
    imports*: Table[string, string]
    scope*: Scope
    node*: ast.Unit
  Resolution* = object
    units*: Table[string, Unit]
    resolutions*: Table[pointer, Symbol]
    order*: seq[string]

proc graph*(resolution: Resolution): JsonNode =
  var units = newJArray()
  var names: seq[string]
  for name in resolution.units.keys: names.add(name)
  names.sort()
  for name in names:
    let unit = resolution.units[name]
    var imports = newJArray()
    for imported in unit.imports.values: imports.add(%imported)
    var symbols = newJArray()
    var entry = false
    for statement in unit.node.body.stmts:
      if statement.tag == "function":
        let function = Function(statement)
        if function.name.text == "start": entry = true
        symbols.add(%* {"name": unit.name & "::" & function.name.text, "visibility": (if function.public: "public" else: "private")})
      elif statement.tag in ["extern-function", "constant", "mutable", "alias"]:
        var label = ""
        var public = false
        if statement.tag == "extern-function": label = External(statement).name.text; public = External(statement).public
        elif statement.tag == "constant": label = Constant(statement).name.text; public = Constant(statement).public
        elif statement.tag == "mutable": label = Mutable(statement).name.text; public = Mutable(statement).public
        else: label = Alias(statement).name.text; public = Alias(statement).public
        symbols.add(%* {"name": unit.name & "::" & label, "visibility": (if public: "public" else: "private")})
    units.add(%* {"namespace": unit.name, "package": unit.package, "path": unit.path, "entry": entry, "imports": imports, "symbols": symbols})
  %* {"format": "foo.graph", "version": 1, "units": units, "order": resolution.order}
