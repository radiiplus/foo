## Retained three-backend, two-mode differential runner. Unsupported != skipped.
import std/[os, osproc, strutils, json, sequtils, tables, sha1]
import ../../../src/build/[compiler, options]
import ../../../src/diag/engine
import ../../../src/toolchain/manager
import ../../../src/backend/c/driver as cDriver
import ../../../src/backend/zig/driver as zigDriver
import ../../../src/backend/llvm/driver as llvmDriver
import ../../../src/ir/print
import ../../../src/ir/lower as rawLower
import ../../../src/ir/monomorph
import ../../../src/ir/[node, reach]

let root = absolutePath(getEnv("FOO_LLVM_ROOT", ".artifacts/llvm-core"))
createDir(root)
writeFile(root / "project.json", "{\"name\":\"llvm-core\",\"requires\":\"system\"}")
let zig = detect().path
doAssert zig.len > 0, "Managed Zig is required; this runner never installs tools"
let fixtures = parseFile("test/backend/llvm/fixtures/cases.json")
let manifestHash = $secureHash(readFile("test/backend/llvm/fixtures/cases.json"))
let toolVersions = %*{"nim":NimVersion,"zig":execCmdEx(quoteShell(zig) & " version").output.strip(),
  "clang":execCmdEx("clang --version").output.strip(),"lld":execCmdEx("lld-link --version").output.strip()}
doAssert defined(windows) and sizeof(pointer) == 8, "LLVM core execution gate requires Windows x64"
var observations = newJArray()
var failures: seq[string]
let selection = getEnv("FOO_LLVM_CASE")
let selectedFixtures = fixtures.elems.filterIt(selection.len == 0 or it["name"].getStr() in selection.split(','))
proc saveReport(complete = false) =
  writeFile(root / "results.json",pretty(observations) & "\n")
  writeFile(root / "report.json",pretty(%*{
    "format":"foo.llvm.core.v2", "backends":["c","zig","llvm"], "modes":["dev","release"],
    "manifestHash": manifestHash,
    "fixtures": selectedFixtures.len, "observations":observations.len,
    "expectedObservations":selectedFixtures.len * 6, "failures":failures,
    "complete":complete, "passed":complete and failures.len == 0 and observations.len == selectedFixtures.len * 6,
    "fullSuite":selection.len == 0, "target":"x86_64-pc-windows-msvc", "tools":toolVersions}) & "\n")
saveReport()
proc locations(module: Module): JsonNode =
  result = newJArray()
  let output = result
  proc record(i: Instruction; function, label: string) =
    if i == nil: return
    output.add(%*{"function":function,"block":label,"operation": $i.kind,
      "file":i.span.file,"start":i.span.start,"end":i.span.end,"trace":i.trace})
    if i.fallback != nil:
      for child in i.fallback.instrs: record(child,function,i.fallback.label)
      record(i.fallback.term,function,i.fallback.label)
  for function in module.funcs:
    for basicBlock in function.blocks:
      for i in basicBlock.instrs: record(i,function.name,basicBlock.label)
      record(basicBlock.term,function.name,basicBlock.label)
for fixture in fixtures:
  let name = fixture["name"].getStr()
  if getEnv("FOO_LLVM_CASE").len > 0 and name notin getEnv("FOO_LLVM_CASE").split(','): continue
  let level = if fixture.hasKey("level"): fixture["level"].getStr() else: "system"
  writeFile(root / "project.json", $(%*{"name":"llvm-core","requires":level}))
  let file = root / (name & ".iv")
  writeFile(file, readFile("test/backend/llvm/fixtures" / (name & ".iv")))
  for mode in ["dev", "release"]:
    var baseline = ""
    var cObserved = ""
    for backend in ["c", "zig", "llvm"]:
      echo name, "/", mode, "/", backend, ": building"
      let outDir = root / name / mode / backend
      createDir(outDir)
      var success = false
      var artifact, error: string
      var phase = "frontend"
      let priorFailures = failures.len
      let frontend = newCompiler(root,backend,mode=mode)
      try:
        let module = frontend.ir(file)
        phase = "backend"
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
          let originalLocations = locations(prepare(reach(module)))
          let built = llvmDriver.build(module,mode,outDir,options,file)
          success = built.success; artifact = built.artifact; error = built.error
          if success:
            let sourceMap = parseFile(outDir / "source.json")
            if sourceMap["source"].getStr() != file or sourceMap["locations"] != originalLocations:
              failures.add(name & "/" & mode & "/llvm: source spans or structured trails changed")
            if not originalLocations.elems.anyIt(it["file"].getStr() == file and it["end"].getInt() > it["start"].getInt()):
              failures.add(name & "/" & mode & "/llvm: missing original source locations")
            for token in readFile(outDir / "main.ll").splitWhitespace():
              if token in ["nsw","nuw","noalias","nonnull","fast","inbounds"] or token.startsWith("range("):
                failures.add(name & "/" & mode & "/llvm: unproven LLVM assumption " & token)
      except Diagnostics as diagnostic:
        error = diagnostic.diagnostics.messages.mapIt(it.file & ":" & $it.span.line & ":" & $it.span.col & ": " & it.text).join("\n")
      except CatchableError as problem:
        error = problem.msg
        if frontend.typings.hasKey(file):
          writeFile(outDir / "unverified.json",encode(monomorphize(rawLower.lower(frontend.program(file),frontend.typings[file]))))
      var row = %*{"fixture":name,"mode":mode,"backend":backend,"compiled":success,"error":error,"phase":phase,
        "sourceHash": $secureHash(readFile(file))}
      if fixture.hasKey("reject"):
        let expected = fixture["reject"]
        row["reason"] = expected["reason"]
        if success or phase != "frontend" or not error.contains(expected["contains"].getStr()):
          failures.add(name & "/" & mode & "/" & backend & ": frontend rejection mismatch: " & error)
      elif fixture.hasKey("unsupported") and fixture["unsupported"].hasKey(backend):
        let expected = fixture["unsupported"][backend]
        row["reason"] = expected["reason"]
        if success or not error.contains(expected["contains"].getStr()): failures.add(name & "/" & mode & "/" & backend & ": unsupported expectation mismatch: " & error)
      elif not success: failures.add(name & "/" & mode & "/" & backend & ": " & error)
      else:
        let executed = execCmdEx(quoteShell(artifact))
        row["phase"] = %"execution"
        row["exit"] = %executed.exitCode; row["bytes"] = %executed.output.toHex()
        let actual = $executed.exitCode & ":" & executed.output.toHex()
        if backend == "c": cObserved = actual
        elif backend == "llvm" and cObserved.len > 0 and actual != cObserved:
          failures.add(name & "/" & mode & "/" & backend & ": C/LLVM output or exit differs")
        if fixture.hasKey("error"):
          let expected = fixture["error"][backend]
          row["errorKind"] = fixture["error"]["kind"]
          if executed.exitCode != expected["exit"].getInt() or not executed.output.toLowerAscii().contains(expected["contains"].getStr().toLowerAscii()):
            failures.add(name & "/" & mode & "/" & backend & ": expected checked error " & $expected & ", observed " & actual)
          if expected.hasKey("output") and executed.output != expected["output"].getStr():
            failures.add(name & "/" & mode & "/" & backend & ": checked error output bytes differ")
          row["passed"] = %(failures.len == priorFailures)
          observations.add(row)
          saveReport()
          echo name, "/", mode, "/", backend, ": checked error, exit ", executed.exitCode
          continue
        let expected = $fixture["exit"].getInt() & ":" & fixture["output"].getStr().toHex()
        if actual != expected: failures.add(name & "/" & mode & "/" & backend & ": expected " & expected & ", observed " & actual)
        if baseline.len == 0: baseline = actual
        elif actual != baseline: failures.add(name & "/" & mode & "/" & backend & ": differential mismatch")
      row["passed"] = %(failures.len == priorFailures)
      observations.add(row)
      saveReport()
      echo name, "/", mode, "/", backend, ": ", (if success: "compiled" else: error.splitLines()[0])
saveReport(true)
doAssert failures.len == 0, failures.mapIt(it.splitLines()[0]).join("\n") & "; see " & root / "report.json"
doAssert observations.len > 0, "No differential fixtures matched the selection"
doAssert observations.len == selectedFixtures.len * 6, "Incomplete backend/mode matrix"
echo "Differential gate passed: ", observations.len, " observations"
