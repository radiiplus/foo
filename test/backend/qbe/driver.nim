import std/[json, os, osproc, strutils]
import ../../../src/backend/qbe/driver
import ../../../src/build/options
import ../../../src/ir/[kind, node]

let integer = `Type`(kind: Shape.Int, width: 32)
let pointer = `Type`(kind: Shape.Ptr, elem: integer)
let owned = Value(kind: Flavor.Reg, name: "owned", `type`: pointer)
let loaded = Value(kind: Flavor.Reg, name: "loaded", `type`: integer)
let program = Module(funcs: @[Function(name: "main", abi: "", ret: integer,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Alloc, region: "scope", dest: owned),
    Instruction(kind: Opcode.Load, `ptr`: owned, dest: loaded)],
    term: Instruction(kind: Opcode.Return, value: loaded))])])
let target = when defined(windows): "windows-x64" else: "linux-x64"
let settings = Native(name: "app", kind: "exe", target: target)

if getEnv("FOO_QBE").len > 0 and
    (when defined(windows): getEnv("FOO_QBE_TCC").len > 0 else: true):
  let compiledObject = build(program, "dev", ".artifacts/qbe-driver-object-test",
    Native(name: "app", kind: "object", target: target))
  doAssert compiledObject.success, compiledObject.error
  doAssert fileExists(compiledObject.artifact)
  let objectMetadata = parseFile(compiledObject.artifact & ".qbe.json")
  doAssert objectMetadata["linker"]["path"].getStr() == ""
  let first = build(program, "dev", ".artifacts/qbe-driver-test", settings)
  doAssert first.success, first.error
  let run = execCmdEx(quoteShell(first.artifact))
  doAssert run.exitCode == 0, run.output
  let metadata = parseFile(first.artifact & ".qbe.json")
  doAssert metadata["backend"].getStr() == "qbe"
  doAssert metadata["policy"].getStr() == "qbe-freestanding-memory-v10"
  doAssert metadata["abiSha256"].getStr().len == 64
  when defined(windows):
    doAssert metadata["compilerSupportSha256"].getStr().len == 64
  doAssert metadata["linker"]["sha256"].getStr().len == 64
  doAssert metadata["layoutSha256"].getStr().len == 64
  doAssert metadata["runtimeSha256"].getStr().len == 64
  let second = build(program, "dev", ".artifacts/qbe-driver-test", settings)
  doAssert second.success and second.cached
  let release = build(program, "release", ".artifacts/qbe-driver-release-test", settings)
  doAssert release.success, release.error
  let releaseRun = execCmdEx(quoteShell(release.artifact))
  doAssert releaseRun.exitCode == 0, releaseRun.output
  let releaseMetadata = parseFile(release.artifact & ".qbe.json")
  doAssert releaseMetadata["mode"].getStr() == "release"
  doAssert releaseMetadata["runtimeOptimization"].getStr() == "O0"
  doAssert releaseMetadata["checkedInlinePolicy"].getStr() ==
    "private-guarded-constructor-v1"

  let archiver = findExe("ar")
  let selectedArchiver = if archiver.len > 0: archiver else: findExe("llvm-ar")
  doAssert selectedArchiver.len > 0, "Static archive test requires ar or llvm-ar"
  let previousArchiver = getEnv("FOO_QBE_AR")
  putEnv("FOO_QBE_AR", selectedArchiver)
  let exported = Function(name: "runtime_probe", abi: "c", public: true,
    ret: integer, blocks: @[Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Alloc, region: "scope", dest: owned),
      Instruction(kind: Opcode.Load, `ptr`: owned, dest: loaded)],
      term: Instruction(kind: Opcode.Return, value: loaded))])
  let archive = build(Module(funcs: @[exported]), "dev",
    ".artifacts/qbe-driver-archive-test",
    Native(name: "runtime-probe", kind: "static", target: target))
  if previousArchiver.len > 0: putEnv("FOO_QBE_AR", previousArchiver)
  else: delEnv("FOO_QBE_AR")
  doAssert archive.success, archive.error
  let members = execCmdEx(quoteShell(selectedArchiver) & " t " &
    quoteShell(archive.artifact))
  doAssert members.exitCode == 0, members.output
  doAssert "module.o" in members.output
  doAssert (if target == "windows-x64": "qbe-runtime.obj" else:
    "qbe-runtime.o") in members.output
  when not defined(windows):
    doAssert "qbe-syscall.o" in members.output
  when defined(windows):
    let consumer = absolutePath(".artifacts/qbe-driver-archive-test/consumer.c")
    let executable = absolutePath(".artifacts/qbe-driver-archive-test/consumer.exe")
    writeFile(consumer,
      "extern int runtime_probe(void);\nint main(void) { return runtime_probe(); }\n")
    let cc = parseFile(archive.artifact & ".qbe.json")["cc"]["path"].getStr()
    let packagedImports = parentDir(cc) / "lib" / "foo-winapi.def"
    let imports = if fileExists(packagedImports): packagedImports
      else: absolutePath("tools/tcc/foo-winapi.def")
    let linked = execCmdEx(quoteShell(cc) & " " & quoteShell(consumer) &
      " " & quoteShell(archive.artifact) & " " & quoteShell(imports) &
      " -o " & quoteShell(executable))
    doAssert linked.exitCode == 0, linked.output
    doAssert execCmdEx(quoteShell(executable)).exitCode == 0

echo "QBE driver probe: ok"
