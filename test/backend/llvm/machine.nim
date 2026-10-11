import std/[os, osproc, strutils]
import ../../../src/backend/llvm/driver
import ../../../src/build/options
import ../../../src/ir/[node, kind]

when defined(windows):
  let root = absolutePath(".artifacts/llvm-machine")
  let unit = node.Type(kind: TypeKind.Void)
  let integer = node.Type(kind: TypeKind.Int, width: 32)
  let number = Value(kind: ValueKind.Const, name: "42", bits: "42", type: integer)
  let simple = Module(funcs: @[Function(name: "main", ret: integer,
    blocks: @[node.Block(label: "entry", term: Instruction(kind: InstrKind.Return, value: number))])])
  let nativeOptions = Native(name: "machine", compile: true, runtime: "none", level: "hardware")
  let built = build(simple, "dev", root / "bare", nativeOptions)
  doAssert built.success, built.error
  doAssert execCmdEx(quoteShell(built.artifact)).exitCode == 42
  let bare = readFile(root / "bare/main.ll")
  doAssert not bare.contains("call void @foo_llvm_init")
  doAssert not bare.contains("call void @foo_llvm_finish")
  let imports = execCmdEx("llvm-readobj --coff-imports " & quoteShell(built.artifact))
  doAssert imports.exitCode == 0 and not imports.output.contains("Import {"), imports.output
  simple.funcs[0].attributes = @["target_feature(\"sse2\")"]
  let featured = build(simple, "release", root / "feature", nativeOptions)
  doAssert featured.success, featured.error
  doAssert readFile(root / "feature/main.ll").contains("\"target-features\"=\"+sse2\"")
  doAssert execCmdEx(quoteShell(featured.artifact)).exitCode == 42
  simple.funcs[0].attributes = @["target_feature(\"avx2\")"]
  let rejected = build(simple, "dev", root / "rejected", nativeOptions)
  doAssert not rejected.success and rejected.error.contains("not enabled"), rejected.error
  let startup = Module(native: @[NativeContract(id: "bootAssembly", stage: "@asm",
    code: "\"movl $42, %eax\\nretq\"", abi: "c", effects: @["unknown"])], funcs: @[
      Function(name: "boot", ret: unit, attributes: @["start", "naked"], blocks: @[
        node.Block(label: "entry", instrs: @[Instruction(kind: InstrKind.Native, symbol: "bootAssembly")],
          term: Instruction(kind: InstrKind.Return))]),
      Function(name: "irq", ret: unit, attributes: @["interrupt"], blocks: @[
        node.Block(label: "entry", term: Instruction(kind: InstrKind.Return))])])
  let started = build(startup, "dev", root / "startup", nativeOptions)
  doAssert started.success, started.error
  doAssert execCmdEx(quoteShell(started.artifact)).exitCode == 42
  let ir = readFile(root / "startup/main.ll")
  doAssert ir.contains("@_start = alias") and ir.contains("naked noinline")
  doAssert ir.contains("call void asm sideeffect") and ir.contains("x86_intrcc")
  let body = ir[ir.find("define void @\"foo.boot\"")..<ir.find("\n}", ir.find("define void @\"foo.boot\""))]
  doAssert not body.contains("alloca") and not body.contains("@foo_llvm") and not body.contains("foo_escape")
  let assembly = execCmdEx("llvm-objdump -d " & quoteShell(root / "startup/main.obj"))
  doAssert assembly.exitCode == 0 and assembly.output.contains("iretq"), assembly.output
  startup.native[0].stage = "@c"
  startup.native[0].code = "(void)0;"
  let invalidBody = build(startup, "dev", root / "helper-rejected", nativeOptions)
  doAssert not invalidBody.success and invalidBody.error.contains("never helper calls"), invalidBody.error
  echo "LLVM runtime-free PE has no imports; setup-free startup runs; interrupt object uses iretq"

