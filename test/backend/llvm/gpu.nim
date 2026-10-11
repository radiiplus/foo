## Re-execute the produced artifact even if the public test runner uses its cache.
import std/[os, osproc, json, strutils]

when defined(windows) or defined(linux):
  let compiler = absolutePath(getEnv("FOO_TEST_COMPILER", (if defined(windows): ".artifacts/native/foo.exe" else: ".artifacts/linuxfoo")))
  doAssert fileExists(compiler), "Build the compiler with node tools/native.mjs first"
  let requireAdapter = getEnv("FOO_REQUIRE_GPU") == "1"
  if requireAdapter:
    let adapter = execCmdEx(quoteShell(compiler) & " test test/backend/llvm/fixtures/gpuavailable.iv --backend llvm --json --no-batching")
    doAssert adapter.exitCode == 0, adapter.output
  let fixture = "test/backend/llvm/fixtures/runtimegpu.iv"
  var produced: seq[string]
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
      produced.add(absolutePath(artifact))
      executed = true
    doAssert executed, "LLVM GPU artifact was not found"
  # The real Vulkan loader, with no usable ICD, exercises unavailable-device
  # behavior. No service provider is replaced with a stub for this test.
  let missingDriver = absolutePath(".artifacts/llvm-missing-vulkan-driver.json")
  doAssert not fileExists(missingDriver)
  let driverVariables = ["VK_DRIVER_FILES", "VK_ICD_FILENAMES"]
  var previous: seq[tuple[present: bool, value: string]]
  for name in driverVariables:
    previous.add((existsEnv(name), getEnv(name)))
    putEnv(name, missingDriver)
  try:
    let unavailable = execCmdEx(quoteShell(compiler) & " test test/backend/llvm/fixtures/gpuunavailable.iv --backend llvm --json --no-batching")
    doAssert unavailable.exitCode == 0, unavailable.output
    for artifact in produced:
      let unavailableRun = execCmdEx(quoteShell(artifact))
      doAssert unavailableRun.exitCode == 0, unavailableRun.output
  finally:
    for index, name in driverVariables:
      if previous[index].present: putEnv(name, previous[index].value)
      else: delEnv(name)
  echo "LLVM SPIR-V/Vulkan O0/O2 artifacts execute; unavailable-adapter failures pass; required available adapter: ", requireAdapter
