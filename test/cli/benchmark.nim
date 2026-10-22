import std/[json, os, strutils]
import ../../src/cli/benchmark

let root = getTempDir() / ("foo-bench-" & $getCurrentProcessId())
if dirExists(root): removeDir(root)
createDir(root / "benchmark" / "nested")
writeFile(root / "benchmark" / "startup.iv", "display \"ready\".\n")
writeFile(root / "benchmark" / "nested" / "worker.iv", "display \"work\".\n")

let suites = discover(root)
doAssert suites.len == 2
doAssert suites[0].name == "nested/worker"
doAssert discover(root, "startup").len == 1
let selected = discover(root, "benchmark/startup.iv")
doAssert selected.len == 1
doAssert selected[0].name == "startup"
doAssert selected[0].file == absolutePath(root / "benchmark" / "startup.iv")
doAssert discover(root, root / "benchmark" / "nested" / "worker.iv")[0].name ==
  "nested/worker"

var calls = 0
var events: seq[string]
let results = benchmark(root, "startup", warmup = 2, iterations = 4,
  executor = proc(suite: Workload): Sample =
    inc calls
    Sample(passed: true, elapsedMs: calls.float, error: "", metrics: nil),
  progress = proc(phase, name, detail: string; cached: bool) =
    events.add(phase & ":" & name & ":" & detail))
doAssert calls == 6
doAssert events[0] == "plan:Measurement:6"
doAssert events.len == 13
doAssert events[^1] == "sampled:startup:"
doAssert results.len == 1
doAssert results[0].samplesMs.len == 4
doAssert results[0].metricsSamples.len == 4
doAssert results[0].metricsSamples[0].kind == JObject
doAssert results[0].minimumMs == 3
doAssert results[0].medianMs == 4.5
doAssert results[0].meanMs == 4.5
doAssert results[0].maximumMs == 6
doAssert results[0].percentile95Ms == 6
doAssert results[0].compilationMs == 0
doAssert results[0].metrics != nil

try:
  discard discover(root, "missing.iv")
  doAssert false
except ValueError as error:
  doAssert "not found" in error.msg

createDir(root / "benchmark" / "workloads")
writeFile(root / "benchmark" / "workloads" / "lookup.iv",
  "display \"lookup\".\n")
let moved = absolutePath(root / "benchmark" / "workloads" / "lookup.iv")
doAssert discover(root, "lookup")[0].name == "lookup"
for path in ["lookup.iv", "benchmark/lookup.iv",
    "benchmark/workloads/lookup.iv"]:
  let selected = discover(root, path)
  doAssert selected.len == 1
  doAssert selected[0].name == "lookup"
  doAssert selected[0].file == moved

createDir(root / "benchmark" / "compilation" / "fixtures")
writeFile(root / "benchmark" / "compilation" / "fixtures" / "hello.iv",
  "display \"hello\".\n")
let hello = absolutePath(root / "benchmark" / "compilation" /
  "fixtures" / "hello.iv")
doAssert discover(root, "compilation/hello")[0].name ==
  "compilation/hello"
for path in ["benchmark/compilation/hello.iv",
    "benchmark/compilation/fixtures/hello.iv"]:
  let selected = discover(root, path)
  doAssert selected.len == 1
  doAssert selected[0].name == "compilation/hello"
  doAssert selected[0].file == hello

removeDir(root)
echo "benchmark runner parity: ok"
