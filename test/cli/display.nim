import std/[json, os]
import ../../src/cli/display
import ../../src/build/planner

let callback = display(jsonOutput = true, verbose = true)
callback(Progress(phase: ppDone, name: "app", file: "app.exe", cached: true,
  elapsed: 12.4, stages: @[Step(name: "emit", reused: true, elapsed: 1.0)]))
let operation = newOperation("build", jsonOutput = true)
doAssert not operation.isFinished()
doAssert not operation.estimate().timingKnown
operation.report("plan", "Source", "1", false)
operation.report("plan", "Compilation", "1", false)
doAssert operation.estimate().known
doAssert operation.estimate().total == 2
doAssert operation.estimate().percent == 0
doAssert not operation.estimate().timingKnown
operation.report("check", "src/main.iv", "", false)
operation.report("checked", "src/main.iv", "", false)
doAssert operation.estimate().completed == 1
doAssert operation.estimate().percent == 0
doAssert not operation.estimate().timingKnown
operation.report("reuse", "app", "app.exe", true)
doAssert operation.estimate().percent == 99
operation.finish(summary = "1 file · 0 errors · 0 warnings")
doAssert operation.isFinished()
doAssert operation.estimate().percent == 100

let failed = newOperation("test", jsonOutput = true)
failed.report("plan", "Execution", "2", false)
failed.report("run", "first", "", false)
failed.report("ran", "first", "", false)
failed.report("run", "second", "", false)
failed.finish(false)
doAssert failed.estimate().completed == 1
doAssert failed.estimate().percent == 0

let measured = newOperation("benchmark", jsonOutput = true)
measured.report("plan", "Measurement", "2", false)
for _ in 0 ..< 2:
  measured.report("sample", "startup", "", false)
  measured.report("sampled", "startup", "", false)
doAssert measured.estimate().completed == 2
measured.finish()
doAssert measured.estimate().percent == 100

let root = getTempDir() / ("foo-progress-" & $getCurrentProcessId())
if dirExists(root): removeDir(root)
createDir(root)
let recorded = newOperation("build", jsonOutput = true)
recorded.configure(root, "c", "windows-x64", "dev")
recorded.plan("Compilation", 3, 5.0)
for _ in 0 ..< 3:
  recorded.startWork("Compilation")
  sleep(10)
  recorded.finishWork("Compilation")
recorded.finish()
doAssert fileExists(root / ".artifacts" / "progress.json")
let saved = parseJson(readFile(root / ".artifacts" / "progress.json"))
doAssert saved["version"].getInt() == 2
doAssert saved["seconds"]["BUILD|c|windows-x64|dev|Compilation"]["count"].getInt() == 3
let reused = newOperation("build", jsonOutput = true)
reused.configure(root, "c", "windows-x64", "dev")
reused.plan("Compilation", 1, 5.0)
reused.report("reuse", "app", "app.exe", true)
doAssert reused.estimate().percent == 99
reused.finish()

writeFile(root / ".artifacts" / "progress.json",
  "{\"version\":2,\"seconds\":{\"BUILD|c|windows-x64|dev|Compilation\":" &
  "{\"count\":3,\"mean\":0.01,\"m2\":0.0}}}")
let overdue = newOperation("build", jsonOutput = true)
overdue.configure(root, "c", "windows-x64", "dev")
overdue.plan("Compilation", 1, 5.0)
overdue.startWork("Compilation")
sleep(40)
doAssert not overdue.estimate().timingKnown
doAssert overdue.estimate().percent == 0
overdue.finish(false)

writeFile(root / ".artifacts" / "progress.json",
  "{\"version\":1,\"seconds\":{\"BUILD|c|windows-x64|dev|Compilation\":0.01}}")
let legacy = newOperation("build", jsonOutput = true)
legacy.configure(root, "c", "windows-x64", "dev")
legacy.plan("Compilation", 1, 5.0)
doAssert not legacy.estimate().timingKnown
doAssert legacy.estimate().remaining == 0

writeFile(root / ".artifacts" / "progress.json",
  "{\"version\":2,\"seconds\":{\"BUILD|c|windows-x64|dev|Compilation\":" &
  "{\"count\":3,\"mean\":1.0,\"m2\":0.0}}}")
let calibrated = newOperation("build", jsonOutput = true)
calibrated.configure(root, "c", "windows-x64", "dev")
calibrated.plan("Compilation", 1, 5.0)
calibrated.startWork("Compilation")
sleep(20)
doAssert calibrated.estimate().timingKnown
doAssert calibrated.estimate().percent > 0
doAssert calibrated.estimate().percent < 99
calibrated.finish(false)

writeFile(root / ".artifacts" / "progress.json",
  "{\"version\":2,\"seconds\":{\"BUILD|c|windows-x64|dev|Compilation\":" &
  "{\"count\":3,\"mean\":1.0,\"m2\":2.0}}}")
let variable = newOperation("build", jsonOutput = true)
variable.configure(root, "c", "windows-x64", "dev")
variable.plan("Compilation", 1, 5.0)
doAssert not variable.estimate().timingKnown
let concise = newOperation("test", compact = true)
concise.plan("Execution", 1, 1.0)
concise.report("run", "sample", "", false)
concise.report("ran", "sample", "", false)
concise.finish(summary = "1 test")
removeDir(root)
echo "cli display parity: ok"
