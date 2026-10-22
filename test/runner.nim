import std/[os, strutils]
import ../src/test/runner
import ../src/diag/engine
import ../src/lex/lexer
import ../src/ast/parser
import ../src/test/cache

let root = getTempDir() / "foo-test-discovery"
if dirExists(root): removeDir(root)
createDir(root / "nested")
writeFile(root / "nested" / "suite.iv", "test \"addition\" { give. }\n")
writeFile(root / "main.iv", "start { give nothing. }\n")
let suites = discover(root)
doAssert suites.len == 1
doAssert suites[0].name == "addition"
doAssert suites[0].file.endsWith("suite.iv")
let stable = directory(root, suites[0].file, suites[0].name,
  suites[0].line, "qbe", "dev")
doAssert stable == directory(root, suites[0].file, suites[0].name,
  suites[0].line, "qbe", "dev")
doAssert stable != directory(root, suites[0].file, suites[0].name,
  suites[0].line, "unsupported-reference", "dev")
doAssert stable != directory(root, suites[0].file, suites[0].name,
  suites[0].line, "qbe", "release")
doAssert stable != directory(root, suites[0].file, "different",
  suites[0].line, "qbe", "dev")
doAssert stable != directory(root, root / "other" / "suite.iv",
  suites[0].name, suites[0].line, "qbe", "dev")
var guard = acquire(stable)
guard.release()
let starts = discover(root, includeStarts = true)
doAssert starts.len == 2

let source = "test \"selected\" { give. }\ntest \"other\" { give undefinedName. }\n"
let diagnostics = engine()
let program = parser(lexer(source, diagnostics).lex(), diagnostics).parse()
doAssert not diagnostics.failed
doAssert synthesize(program, Suite(name: "selected", line: 1))
for unit in program.units:
  for statement in unit.body.stmts:
    doAssert statement.tag != "test"

var called = 0
var events: seq[string]
let results = run(root, "addition", executor = proc(suite: Suite): Result =
  called.inc
  Result(suite: suite, passed: true, output: "ok"),
  progress = proc(phase, name, detail: string; cached: bool) =
    events.add(phase & ":" & name & ":" & detail))
doAssert called == 1
doAssert results.len == 1 and results[0].passed and results[0].output == "ok"
doAssert events == @["plan:Execution:1", "run:addition:", "ran:addition:"]
let watcher = watch(root, executor = proc(suite: Suite): Result =
  Result(suite: suite, passed: true))
doAssert watcher.poll().len == 1
watcher.stop()
doAssert watcher.poll().len == 0

let project = root / "project"
createDir(project / "src")
createDir(project / "test")
writeFile(project / "project.ivc", """capability "project"
project { name is "runner" version is "0.1.0" source is "src" }
""")
writeFile(project / "src" / "values.iv",
  "public function answer giving integer { give 42. }\n")
writeFile(project / "test" / "contract.iv", """use values.
use testing as check.
test "source import and generic equality" { check.same(values.answer, 42). }
""")
createDir(project / "benchmark")
writeFile(project / "benchmark" / "broken.iv", "constant broken is .\n")
createDir(project / ".foo" / "packages" / "broken")
writeFile(project / ".foo" / "packages" / "broken" / "bad.iv",
  "constant broken is .\n")
let projects = discover(project)
doAssert projects.len == 1
doAssert projects[0].name == "source import and generic equality"
removeDir(root)
let rejected = execute(Suite(file: project / "test" / "contract.iv", name: "source import and generic equality", line: 3), backend = "c")
doAssert not rejected.passed and not rejected.executed
doAssert rejected.error.contains("Tests execute QBE only")
echo "QBE test runner: ok"
