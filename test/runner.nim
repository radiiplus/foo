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

let project = root / "project"
createDir(project / "src")
createDir(project / "test")
writeFile(project / "project.json", """{"source":"src"}""")
writeFile(project / "src" / "values.iv",
  "public function answer() giving integer { give 42. }\n")
writeFile(project / "test" / "contract.iv", """use values.
use testing as check.
test "source import and generic equality" { check.same(values.answer(), 42). }
""")
createDir(project / "benchmark")
writeFile(project / "benchmark" / "broken.iv", "constant broken is .\n")
createDir(project / ".foo" / "packages" / "broken")
writeFile(project / ".foo" / "packages" / "broken" / "bad.iv",
  "constant broken is .\n")
let projectSuites = discoverTests(project)
doAssert projectSuites.len == 1
doAssert projectSuites[0].name == "source import and generic equality"
removeDir(root)
echo "test runner parity: ok"
