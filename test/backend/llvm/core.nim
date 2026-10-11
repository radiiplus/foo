## Retained differential core-language fixtures. No unsupported case is silent.
import std/[os, osproc, strutils, json, tables, sequtils]
import ../../../src/build/compiler
import ../../../src/diag/engine
import ../../../src/build/options
import ../../../src/backend/llvm/driver as llvmDriver
import ../../../src/backend/c/driver as cDriver
import ../../../src/backend/zig/driver as zigDriver
import ../../../src/toolchain/manager

when defined(windows):
  let root = absolutePath(".artifacts/llvm-core")
  createDir(root)
  writeFile(root / "project.json", "{\"name\":\"llvm-core\",\"requires\":\"system\"}")
  let zig = detect().path
  doAssert zig.len > 0, "Differential acceptance requires managed Zig 0.16.0"
  let fixtureRoot = absolutePath("test/backend/llvm/fixtures")
  let manifest = parseFile(fixtureRoot / "cases.json")
  var report = newJArray()
  var failed = 0
  let selected = getEnv("FOO_LLVM_CASE")
  for fixture in manifest:
    let name = fixture["name"].getStr()
    if selected.len > 0 and selected != name: continue
    let file = fixtureRoot / (name & ".iv")
    for mode in ["dev", "release"]:
      var observed = initTable[string, tuple[output: string, status: int]]()
      for backend in ["c", "zig", "llvm"]:
        let output = root / name / mode / backend
        createDir(output)
        var record = %*{"fixture": name, "mode": mode, "backend": backend}
        try:
          let module = newCompiler(root, backend, mode = mode).ir(file)
          let native = Native(name: name, compile: true, level: "system")
          var success: bool
          var artifact, error: string
          case backend
          of "c":
            var options = native; options.compiler = "clang"
            let built = cDriver.build(module, mode, output, options, file)
            success = built.success; artifact = built.artifact; error = built.error
          of "zig":
            let built = zigDriver.build(module, mode, output, zig, file, native)
            success = built.success; artifact = built.artifact; error = built.error
          else:
            let built = llvmDriver.build(module, mode, output, native, file)
            success = built.success; artifact = built.artifact; error = built.error
          if not success: raise newException(ValueError, error)
          let result = execCmdEx(quoteShell(artifact))
          observed[backend] = (result.output, result.exitCode)
          record["outputHex"] = %result.output.toHex()
          record["status"] = %result.exitCode
          let expectedStatus = fixture.getOrDefault("status").getInt()
          if result.exitCode != expectedStatus: raise newException(ValueError, "expected exit " & $expectedStatus & ", got " & $result.exitCode & ": " & result.output)
          if fixture.hasKey("output") and result.output != fixture["output"].getStr():
            raise newException(ValueError, "output bytes differ from explicit expectation: " & result.output.toHex())
          if fixture.hasKey("error") and not result.output.contains(fixture["error"].getStr()):
            raise newException(ValueError, "expected error identity missing: " & result.output)
          record["passed"] = %true
          echo "PASS " & name & "/" & mode & "/" & backend
        except Diagnostics as error:
          let detail = error.diagnostics.messages.mapIt(it.text).join("\n")
          record["passed"] = %false; record["reason"] = %detail
          inc failed
          echo "FAIL " & name & "/" & mode & "/" & backend & ": " & detail
        except CatchableError as error:
          record["passed"] = %false; record["reason"] = %error.msg
          inc failed
          echo "FAIL " & name & "/" & mode & "/" & backend & ": " & error.msg
        report.add(record)
      if observed.len == 3 and not fixture.hasKey("error"):
        doAssert observed["c"] == observed["zig"], "C/Zig differential mismatch: " & name & "/" & mode
        doAssert observed["llvm"] == observed["c"], "LLVM differential mismatch: " & name & "/" & mode
  writeFile(root / "results.json", pretty(%*{"format": "foo.llvm.core", "cases": report, "failures": failed}) & "\n")
  doAssert failed == 0, $failed & " core fixtures failed; see " & root / "results.json"
else:
  doAssert false, "LLVM core execution is currently qualified only on Windows x64; no silent platform skip"
