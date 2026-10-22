import std/[json, os, osproc]
import ../../../../src/backend/qbe/driver
import ../../../../src/build/options
import ../../../../src/ir/[kind, node]

let integer = `Type`(kind: Shape.Int, width: 32)
let returned = Value(kind: Flavor.Reg, name: "returned", `type`: integer)
let program = Module(funcs: @[Function(name: "main", ret: integer,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Call, `func`: "foreign_value", dest: returned)],
    term: Instruction(kind: Opcode.Return, value: returned))])],
  externs: @[Extern(name: "foreign_value", symbol: "qbe_foreign_value",
    abi: "c", ret: integer)])
let directory = absolutePath(".artifacts/qbe-native-inputs")
createDir(directory)
let source = directory / "foreign.c"
let header = directory / "foreign.h"
let nested = directory / "nested.h"
writeFile(nested, "#define FOREIGN_BASE 42\n")
writeFile(header, "#include \"nested.h\"\n#define FOREIGN_VALUE FOREIGN_BASE\n")
writeFile(source, "#include \"foreign.h\"\nint qbe_foreign_value(void) { return FOREIGN_VALUE; }\n")
let target = when defined(windows): "windows-x64" else: "linux-x64"
let settings = Native(name: "native-inputs", kind: "exe", target: target,
  sources: @[source])

let first = build(program, "dev", directory, settings)
doAssert first.success, first.error
doAssert execCmdEx(quoteShell(first.artifact)).exitCode == 42
doAssert parseFile(first.artifact & ".qbe.json")["nativeInputsSha256"].getStr().len == 64
let repeated = build(program, "dev", directory, settings)
doAssert repeated.success and repeated.cached, repeated.error

writeFile(source, "#include \"foreign.h\"\nint qbe_foreign_value(void) { return FOREIGN_VALUE + 1; }\n")
let changed = build(program, "dev", directory, settings)
doAssert changed.success and not changed.cached, changed.error
doAssert execCmdEx(quoteShell(changed.artifact)).exitCode == 43

writeFile(header, "#include \"nested.h\"\n#define FOREIGN_VALUE (FOREIGN_BASE + 1)\n")
let headerChanged = build(program, "dev", directory, settings)
doAssert headerChanged.success and not headerChanged.cached, headerChanged.error
doAssert execCmdEx(quoteShell(headerChanged.artifact)).exitCode == 44

writeFile(nested, "#define FOREIGN_BASE 43\n")
let nestedChanged = build(program, "dev", directory, settings)
doAssert nestedChanged.success and not nestedChanged.cached, nestedChanged.error
doAssert execCmdEx(quoteShell(nestedChanged.artifact)).exitCode == 45
let headerRepeated = build(program, "dev", directory, settings)
doAssert headerRepeated.success and headerRepeated.cached, headerRepeated.error

let cc = parseFile(first.artifact & ".qbe.json")["cc"]["path"].getStr()
let objectFile = directory / (when defined(windows): "foreign.obj" else: "foreign.o")
let compiled = execCmdEx(quoteShell(cc) & " -c " & quoteShell(source) &
  " -o " & quoteShell(objectFile))
doAssert compiled.exitCode == 0, compiled.output
let objectSettings = Native(name: "native-object", kind: "exe", target: target,
  objects: @[objectFile])
let objectBuild = build(program, "dev", directory / "object", objectSettings)
doAssert objectBuild.success, objectBuild.error
doAssert execCmdEx(quoteShell(objectBuild.artifact)).exitCode == 45

when not defined(windows):
  let archive = directory / "libforeign.a"
  let archived = execCmdEx("ar rcs " & quoteShell(archive) & " " &
    quoteShell(objectFile))
  doAssert archived.exitCode == 0, archived.output
  let librarySettings = Native(name: "native-library", kind: "exe",
    target: target, libs: @[archive])
  let libraryBuild = build(program, "dev", directory / "library",
    librarySettings)
  doAssert libraryBuild.success, libraryBuild.error
  doAssert execCmdEx(quoteShell(libraryBuild.artifact)).exitCode == 45

echo "QBE native input link and cache probe: ok"
