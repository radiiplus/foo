import std/[os, strutils]
import ../../src/benchmark/runner

let root = getTempDir() / "foo-benchmark-runner-test"
if dirExists(root): removeDir(root)
createDir(root / "benchmark" / "nested")
writeFile(root / "benchmark" / "startup.iv", "display \"ready\".\n")
writeFile(root / "benchmark" / "nested" / "worker.iv", "display \"work\".\n")

let suites = discoverBenchmarks(root)
doAssert suites.len == 2
doAssert suites[0].name == "nested/worker"
doAssert discoverBenchmarks(root, "startup").len == 1
let selected = discoverBenchmarks(root, "benchmark/startup.iv")
doAssert selected.len == 1
doAssert selected[0].name == "startup"
doAssert selected[0].file == absolutePath(root / "benchmark" / "startup.iv")
doAssert discoverBenchmarks(root, root / "benchmark" / "nested" / "worker.iv")[0].name ==
  "nested/worker"

var calls = 0
let results = runBenchmarks(root, "startup", warmup = 2, iterations = 4,
  executor = proc(suite: BenchmarkSuite): BenchmarkSample =
    inc calls
    BenchmarkSample(passed: true, elapsedMs: calls.float, error: "", metrics: nil))
doAssert calls == 6
doAssert results.len == 1
doAssert results[0].samplesMs.len == 4
doAssert results[0].minimumMs == 3
doAssert results[0].medianMs == 4.5
doAssert results[0].meanMs == 4.5
doAssert results[0].maximumMs == 6
doAssert results[0].percentile95Ms == 6
doAssert results[0].compilationMs == 0
doAssert results[0].metrics != nil

try:
  discard discoverBenchmarks(root, "missing.iv")
  doAssert false
except ValueError as error:
  doAssert "not found" in error.msg

removeDir(root)
echo "benchmark runner parity: ok"
