import std/os
import ../../src/cli/display
import ../../src/build/planner

let callback = display(jsonOutput = true, verbose = true)
callback(Progress(phase: ppDone, name: "app", file: "app.exe", cached: true,
  elapsed: 12.4, stages: @[Step(name: "emit", reused: true, elapsed: 1.0)]))
let operation = newOperation("build", jsonOutput = true)
doAssert not operation.isFinished()
operation.report("plan", "Source", "1", false)
operation.report("plan", "Compilation", "1", false)
doAssert operation.estimate().known
doAssert operation.estimate().total == 2
doAssert operation.estimate().percent == 0
operation.report("check", "src/main.iv", "", false)
operation.report("checked", "src/main.iv", "", false)
doAssert operation.estimate().completed == 1
doAssert operation.estimate().percent > 0
doAssert operation.estimate().percent < 100
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
doAssert failed.estimate().percent == 50

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
recorded.plan("Compilation", 1, 5.0)
recorded.startWork("Compilation")
recorded.finishWork("Compilation")
recorded.finish()
doAssert fileExists(root / ".artifacts" / "progress.json")
let reused = newOperation("build", jsonOutput = true)
reused.configure(root, "c", "windows-x64", "dev")
reused.plan("Compilation", 1, 5.0)
let learned = reused.estimate().remaining
doAssert learned < 1.0
reused.report("reuse", "app", "app.exe", true)
reused.finish()
let retained = newOperation("build", jsonOutput = true)
retained.configure(root, "c", "windows-x64", "dev")
retained.plan("Compilation", 1, 5.0)
doAssert abs(retained.estimate().remaining - learned) < 0.1
removeDir(root)
echo "cli display parity: ok"
