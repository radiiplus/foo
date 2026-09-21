import std/[os, strutils]
import ../src/test/runner

let root = getTempDir() / "foo-test-discovery"
if dirExists(root): removeDir(root)
createDir(root / "nested")
writeFile(root / "nested" / "suite.iv", "test \"addition\" { give. }\n")
writeFile(root / "main.iv", "start() { give nothing. }\n")
let suites = discoverTests(root)
doAssert suites.len == 1
doAssert suites[0].name == "addition"
doAssert suites[0].file.endsWith("suite.iv")
let withStarts = discoverTests(root, includeStarts = true)
doAssert withStarts.len == 2
var called = 0
let results = runTests(root, "addition", executor = proc(suite: TestSuite): TestResult =
  called.inc
  TestResult(suite: suite, passed: true, output: "ok"))
doAssert called == 1
doAssert results.len == 1 and results[0].passed and results[0].output == "ok"
let watcher = watchTests(root, executor = proc(suite: TestSuite): TestResult =
  TestResult(suite: suite, passed: true))
doAssert watcher.poll().len == 1
watcher.stop()
doAssert watcher.poll().len == 0
removeDir(root)
echo "test runner parity: ok"
