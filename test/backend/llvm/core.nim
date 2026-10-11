## Retained three-backend, two-mode differential runner. Unsupported != skipped.
import std/[os, osproc, strutils, json, sequtils, tables]
import ../../../src/build/[compiler, options]
import ../../../src/diag/engine
import ../../../src/toolchain/manager
import ../../../src/backend/c/driver as cDriver
import ../../../src/backend/zig/driver as zigDriver
import ../../../src/backend/llvm/driver as llvmDriver
import ../../../src/ir/print
import ../../../src/ir/lower as rawLower
import ../../../src/ir/monomorph

let root = absolutePath(getEnv("FOO_LLVM_ROOT", ".artifacts/llvm-core"))
createDir(root)
writeFile(root / "project.json", "{\"name\":\"llvm-core\",\"requires\":\"system\"}")
let zig = detect().path
doAssert zig.len > 0, "Managed Zig is required; this runner never installs tools"
let fixtures = parseFile("test/backend/llvm/fixtures/cases.json")
doAssert defined(windows) and sizeof(pointer) == 8, "LLVM core execution gate requires Windows x64"
var observations = newJArray()
var failures: seq[string]
for fixture in fixtures:
  let name = fixture["name"].getStr()
  if getEnv("FOO_LLVM_CASE").len > 0 and name notin getEnv("FOO_LLVM_CASE").split(','): continue
  let level = if fixture.hasKey("level"): fixture["level"].getStr() else: "system"
  writeFile(root / "project.json", $(%*{"name":"llvm-core","requires":level}))
  let file = root / (name & ".iv")
  writeFile(file, readFile("test/backend/llvm/fixtures" / (name & ".iv")))
  for mode in ["dev", "release"]:
    var baseline = ""
    for backend in ["c", "zig", "llvm"]:
      echo name, "/", mode, "/", backend, ": building"
      let outDir = root / name / mode / backend
      createDir(outDir)
      var success = false
      var artifact, error: string
      let frontend = newCompiler(root,backend,mode=mode)
      try:
        let module = frontend.ir(file)
        writeFile(outDir / "input.json", encode(module))
        let options = Native(name:name,compile:true,level:level,compiler:(if backend == "zig": "" else: "clang"))
        case backend
        of "c":
          let built = cDriver.build(module,mode,outDir,options,file)
          success = built.success; artifact = built.artifact; error = built.error
        of "zig":
          let built = zigDriver.build(module,mode,outDir,zig,file,options)
          success = built.success; artifact = built.artifact; error = built.error
        else:
          let built = llvmDriver.build(module,mode,outDir,options,file)
          success = built.success; artifact = built.artifact; error = built.error
      except Diagnostics as diagnostic:
        error = diagnostic.diagnostics.messages.mapIt(it.file & ":" & $it.span.line & ":" & $it.span.col & ": " & it.text).join("\n")
      except CatchableError as problem:
        error = problem.msg
        if frontend.typings.hasKey(file):
          writeFile(outDir / "unverified.json",encode(monomorphize(rawLower.lower(frontend.program(file),frontend.typings[file]))))
      var row = %*{"fixture":name,"mode":mode,"backend":backend,"compiled":success,"error":error}
      if fixture.hasKey("unsupported") and fixture["unsupported"].hasKey(backend):
        let expected = fixture["unsupported"][backend]
        row["reason"] = expected["reason"]
        if success or not error.contains(expected["contains"].getStr()): failures.add(name & "/" & mode & "/" & backend & ": unsupported expectation mismatch: " & error)
      elif not success: failures.add(name & "/" & mode & "/" & backend & ": " & error)
      else:
        let executed = execCmdEx(quoteShell(artifact))
        row["exit"] = %executed.exitCode; row["bytes"] = %executed.output.toHex()
        let actual = $executed.exitCode & ":" & executed.output.toHex()
        if fixture.hasKey("error"):
          let expected = fixture["error"][backend]
          row["errorKind"] = fixture["error"]["kind"]
          if executed.exitCode != expected["exit"].getInt() or not executed.output.toLowerAscii().contains(expected["contains"].getStr().toLowerAscii()):
            failures.add(name & "/" & mode & "/" & backend & ": expected checked error " & $expected & ", observed " & actual)
          observations.add(row)
          writeFile(root / "results.json",pretty(observations))
          echo name, "/", mode, "/", backend, ": checked error, exit ", executed.exitCode
          continue
        let expected = $fixture["exit"].getInt() & ":" & fixture["output"].getStr().toHex()
        if actual != expected: failures.add(name & "/" & mode & "/" & backend & ": expected " & expected & ", observed " & actual)
        if baseline.len == 0: baseline = actual
        elif actual != baseline: failures.add(name & "/" & mode & "/" & backend & ": differential mismatch")
      observations.add(row)
      writeFile(root / "results.json",pretty(observations))
      echo name, "/", mode, "/", backend, ": ", (if success: "compiled" else: error)
doAssert failures.len == 0, failures.join("\n")
doAssert observations.len > 0, "No differential fixtures matched the selection"
echo "Differential gate passed: ", observations.len, " observations"
