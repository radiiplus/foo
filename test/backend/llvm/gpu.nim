## Re-execute the produced artifact even if the public test runner uses its cache.
import std/[os, osproc, json, strutils]

when defined(windows) or defined(linux):
  let compiler = absolutePath(getEnv("FOO_TEST_COMPILER", (if defined(windows): ".artifacts/native/foo.exe" else: ".artifacts/linuxfoo")))
  doAssert fileExists(compiler), "Build the compiler with node tools/native.mjs first"
  let fixture = "test/backend/llvm/fixtures/runtimegpu.iv"
  for mode in ["dev", "release"]:
    let response = execCmdEx(quoteShell(compiler) & " test " & quoteShell(fixture) &
      " --backend llvm --mode " & mode & " --json --no-batching")
    doAssert response.exitCode == 0, response.output
    var executed = false
    let artifacts = ".artifacts/test/llvm/" & mode
    for directory in walkDirs(artifacts / "runtimegpu_*"):
      let artifact = directory / (if defined(windows): "test.exe" else: "test")
      if not fileExists(artifact): continue
      let metadata = parseFile(directory / "llvm.json")
      doAssert metadata["backend"].getStr() == "llvm"
      doAssert metadata["runtimeAbi"].getStr() == "foo.runtime.pointer.v1"
      let ir = readFile(directory / "main.ll")
      doAssert ir.contains("define i32 @main(i32 %argc, ptr %argv)")
      doAssert ir.contains("\\03\\02\\23\\07"), "Direct SPIR-V binary must be embedded"
      doAssert fileExists(directory / "verified.ll")
      doAssert readFile(directory / "verify.diagnostics").contains("exitCode=0")
      doAssert not readFile(directory / "runtime.c").contains("clBuildProgram")
      let run = execCmdEx(quoteShell(absolutePath(artifact)))
      doAssert run.exitCode == 0, run.output
      executed = true
    doAssert executed, "LLVM GPU artifact was not found"
  echo "LLVM host artifacts verify and execute checked SPIR-V/Vulkan service tests at O0/O2"
