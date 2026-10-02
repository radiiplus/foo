import std/[json, os]
import ../ir/node

proc generate*(module: Module; outDir: string) =
  var functions = newJArray()
  for fn in module.funcs:
    if not fn.public and fn.abi.len == 0 and "start" notin fn.attributes: continue
    var parameters = newJArray()
    for parameter in fn.params:
      parameters.add(%*{"name": parameter.name, "type": $parameter.type.kind})
    functions.add(%*{"name": fn.name, "public": fn.public, "abi": fn.abi,
      "attributes": fn.attributes, "parameters": parameters,
      "result": $fn.ret.kind, "line": fn.line})
  var types = newJArray()
  for declaration in module.types:
    types.add(%*{"name": declaration.name, "kind": $declaration.type.kind})
  let directory = outDir / "docs"
  createDir(directory)
  writeFile(directory / "api.json", pretty(%*{"format": "foo.docs",
    "version": 1, "module": module.name, "functions": functions,
    "types": types}) & "\n")
