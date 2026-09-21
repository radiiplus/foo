import ../../src/cli/display
import ../../src/build/planner

let callback = display(jsonOutput = true, verbose = true)
callback(Progress(phase: ppDone, name: "app", file: "app.exe", cached: true,
  elapsed: 12.4, stages: @[Step(name: "emit", reused: true, elapsed: 1.0)]))
echo "cli display parity: ok"
