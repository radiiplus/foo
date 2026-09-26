import ../../src/cli/display
import ../../src/build/planner

let callback = display(jsonOutput = true, verbose = true)
callback(Progress(phase: ppDone, name: "app", file: "app.exe", cached: true,
  elapsed: 12.4, stages: @[Step(name: "emit", reused: true, elapsed: 1.0)]))
let operation = newOperation("build", jsonOutput = true)
doAssert not operation.isFinished()
operation.report("check", "src/main.iv", "", false)
operation.report("checked", "src/main.iv", "", false)
operation.report("reuse", "app", "app.exe", true)
operation.finish(summary = "1 file · 0 errors · 0 warnings")
doAssert operation.isFinished()
echo "cli display parity: ok"
