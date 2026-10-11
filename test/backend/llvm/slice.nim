import std/[os, osproc, strutils, json, tables]
import ../../../src/build/compiler
import ../../../src/build/project as projects
import ../../../src/build/options
import ../../../src/backend/llvm/driver
import ../../../src/ir/[node, kind]
import ../../../src/ir/print

when defined(windows):
  let root = absolutePath(".artifacts/llvm-slice-" & getEnv("FOOTESTID", "local"))
  createDir(root)
  writeFile(root / "project.json", "{\"name\":\"llvm-slice\",\"requires\":\"system\"}")
  let file = root / "main.iv"
  writeFile(file, readFile("test/backend/llvm/program/main.iv"))
  let frontend = newCompiler(root, "llvm")
  let module = frontend.ir(file)
  writeFile(root / "lowered.json", encode(module))
  let nativeOptions = Native(name: "slice", compile: true)
  let built = build(module, "dev", root, nativeOptions, file)
  doAssert built.success, built.error
  let ir = readFile(root / "main.ll")
  doAssert ir.contains("; FOO LLVM backend")
  doAssert ir.contains("define i32 @main()")
  doAssert ir.contains("@llvm.sadd.with.overflow.i32"), ir
  doAssert fileExists(root / "verified.ll")
  doAssert fileExists(root / "main.obj")
  doAssert not fileExists(root / "main.c")
  doAssert not fileExists(root / "main.zig")
  doAssert execCmdEx(quoteShell(built.artifact)).exitCode == 42
  let metadata = parseJson(readFile(root / "llvm.json"))
  doAssert metadata["backend"].getStr() == "llvm"
  doAssert metadata["optimization"].getStr() == "O0"
  doAssert readFile(root / "verified.ll").contains(metadata["layout"].getStr())
  doAssert identity("release", nativeOptions) != identity("dev", nativeOptions)
  let optimized = build(module, "release", root / "release", nativeOptions, file)
  doAssert optimized.success, optimized.error
  doAssert execCmdEx(quoteShell(optimized.artifact)).exitCode == 42
  var reused = false
  let project = projects.newProject(root, projects.ProjectOptions(backend: "llvm", target: "windows-x64",
    progress: proc(phase, name, detail: string; cached: bool) =
      if phase == "reuse" and cached: reused = true))
  let products = project.build(file)
  doAssert products.len == 1
  doAssert readFile(root / ".artifacts/build/main.ll").contains("FOO LLVM backend")
  discard project.build(file) # Exercise the LLVM project cache lookup.
  doAssert reused
  # A malformed SSA/type combination must be rejected by LLVM itself.
  writeFile(root / "invalid.ll", "define i32 @main() {\nentry:\n  br i1 true, label %a, label %b\na:\n  %value = add i32 1, 2\n  br label %b\nb:\n  ret i32 %value\n}\n")
  let rejected = execCmdEx("clang -x ir -S -emit-llvm -Xclang -llvm-verify-each " &
    quoteShell(root / "invalid.ll") & " -o " & quoteShell(root / "invalid-verified.ll"))
  doAssert rejected.exitCode != 0
  doAssert rejected.output.contains("does not dominate"), rejected.output
  module.funcs[0].blocks[0].instrs.add(Instruction(kind: InstrKind.Div,
    span: SourceSpan(file: file, start: 12)))
  let unsupported = build(module, "dev", root / "unsupported", nativeOptions, file)
  doAssert not unsupported.success
  doAssert unsupported.error.contains("unsupported instruction Div")
  doAssert unsupported.error.contains(":12")
  echo "LLVM slice verifies, links and returns 42 (O0 and O2)"
else:
  echo "LLVM Batch 1 execution gate is Windows x64 only"


