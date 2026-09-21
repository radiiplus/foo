import std/[json, os, osproc, sequtils, strutils, tables, times]
import ../ast/node as ast
import ../diag/engine
import ../diag/render
import ../lex/lexer
import ../parse/parser
import ../sema/resolver
import ../sema/link
import ../interop/expand
import "../interop/bind.nim" as cBinding
import ../pkg/lint
import ../types/checker
import ../ir/[lower, monomorph]
import ../backend/zig/driver as zigDriver
import ../backend/c/driver as cDriver
import ../build/options as buildOptions
import ../toolchain/manager

type
  TestSuite* = object
    name*: string
    file*: string
    line*: int
  TestResult* = object
    suite*: TestSuite
    passed*: bool
    timeMs*: int
    output*: string
    error*: string
    files*: seq[string]
    opaque*: bool
  TestExecutor* = proc(suite: TestSuite): TestResult {.closure.}
  TestWatcher* = ref object
    root*: string
    filter*: string
    backend*: string
    executor*: TestExecutor
    stopped*: bool
    snapshot*: Table[string, string]

proc parseFile(path: string): tuple[program: ast.Program, failed: bool] =
  let source = readFile(path)
  let diag = newEngine()
  diag.setSource(source, path)
  let program = newParser(newLexer(source, diag).lex(), diag).parse()
  (program: program, failed: diag.failed)

proc inspect(path: string; includeStart: bool; suites: var seq[TestSuite]) =
  if not path.toLowerAscii().endsWith(".iv"): return
  let parsed = parseFile(path)
  if parsed.failed:
    suites.add(TestSuite(name: splitFile(path).name, file: path, line: 1))
    return
  for unit in parsed.program.units:
    var hasTest = false
    for statement in unit.body.stmts:
      if statement.tag == "test":
        hasTest = true
        let testBlock = ast.TestBlock(statement)
        suites.add(TestSuite(name: testBlock.name.value, file: path, line: statement.span.line))
    if includeStart and not hasTest:
      for statement in unit.body.stmts:
        if statement.tag == "function" and ast.Function(statement).name.text == "start":
          suites.add(TestSuite(name: splitFile(path).name, file: path, line: statement.span.line))
          break

proc discoverTests*(root: string; includeStarts = false): seq[TestSuite] =
  var stdlib = ""
  for candidate in [getAppDir().parentDir / "test" / "stdlib",
      getAppDir().parentDir.parentDir / "test" / "stdlib",
      currentSourcePath.parentDir.parentDir.parentDir / "test" / "stdlib"]:
    if dirExists(candidate):
      stdlib = absolutePath(candidate)
      break
  let selected = if root == "std": stdlib else: absolutePath(root)
  let starts = includeStarts or fileExists(selected) or selected == stdlib
  var suites: seq[TestSuite] = @[]
  if fileExists(selected):
    inspect(selected, true, suites)
    return suites
  if not dirExists(selected): return @[]
  proc visit(directory: string) =
    for kind, path in walkDir(directory):
      let name = path.lastPathPart
      if kind == pcLinkToDir or kind == pcLinkToFile: continue
      if kind == pcDir:
        if name in ["node_modules", ".artifacts", ".git"]: continue
        visit(path)
      elif kind == pcFile:
        inspect(path, starts, suites)
  visit(selected)
  result = suites

proc synthesizeTests*(program: ast.Program; selected: TestSuite) : bool =
  ## Replace the selected test block with a start entry that calls only that block.
  for unit in program.units:
    var target: ast.TestBlock
    for statement in unit.body.stmts:
      if statement.tag == "test":
        let testBlock = ast.TestBlock(statement)
        if testBlock.name.value == selected.name and statement.span.line == selected.line:
          target = testBlock
          break
    if target == nil: continue
    let span = target.span
    let nameNode = ast.Name(tag: "name", span: span, text: "__test_selected")
    let function = ast.Function(tag: "function", span: span, public: false, name: nameNode,
      typeParams: @[], params: @[], returnType: nil, abi: "", constraint: nil,
      constraints: @[], attributes: @[], body: target.body)
    let callName = ast.Name(tag: "name", span: span, text: nameNode.text)
    let call = ast.Action(tag: "action", span: span, name: callName, args: @[], value: nil)
    var start: ast.Function
    for statement in unit.body.stmts:
      if statement.tag == "function" and ast.Function(statement).name.text == "start":
        start = ast.Function(statement)
        break
    if start == nil:
      let startName = ast.Name(tag: "name", span: span, text: "start")
      start = ast.Function(tag: "function", span: span, public: true, name: startName,
        typeParams: @[], params: @[], returnType: nil, abi: "", constraint: nil,
        constraints: @[], attributes: @[], body: ast.Block(tag: "block", span: span, stmts: @[ast.Statement(call)]))
      unit.body.stmts.add(ast.Statement(start))
    else:
      start.body.stmts = @[ast.Statement(call)]
    unit.body.stmts.add(ast.Statement(function))
    var filtered: seq[ast.Statement] = @[]
    for statement in unit.body.stmts:
      if statement != ast.Statement(target): filtered.add(statement)
    unit.body.stmts = filtered
    return true
  for unit in program.units:
    for statement in unit.body.stmts:
      if statement.tag == "function" and
          ast.Function(statement).name.text == "start" and
          statement.span.line == selected.line:
        return true

proc strings(node: JsonNode): seq[string] =
  if node != nil and node.kind == JArray:
    for value in node:
      if value.kind == JString: result.add(value.getStr())

proc child(node: JsonNode; name: string): JsonNode =
  if node != nil and node.kind == JObject and node.hasKey(name): node[name]
  else: nil

proc text(node: JsonNode; fallback = ""): string =
  if node != nil and node.kind == JString: node.getStr() else: fallback

proc flag(node: JsonNode): bool =
  node != nil and node.kind == JBool and node.getBool()

proc rooted(root, path: string): string =
  if isAbsolute(path): path else: absolutePath(root / path)

proc runSingleTest*(suite: TestSuite; backend = "zig"; executor: TestExecutor = nil): TestResult =
  let started = epochTime()
  if executor != nil:
    result = executor(suite)
    result.timeMs = int((epochTime() - started) * 1000)
    return
  result.suite = suite
  try:
    var projectRoot = if dirExists(suite.file): suite.file else: parentDir(suite.file)
    while not fileExists(projectRoot / "project.json") and
        parentDir(projectRoot) != projectRoot:
      projectRoot = parentDir(projectRoot)
    if not fileExists(projectRoot / "project.json"):
      projectRoot = parentDir(suite.file)
    let manifestPath = projectRoot / "project.json"
    let manifest = parseJson(if fileExists(manifestPath): readFile(manifestPath) else: "{}")
    let build = manifest.child("build")
    let c = build.child("c")
    let linkOptions = build.child("link")
    let suiteOptions = manifest.child("tests").child(splitFile(suite.file).name)
    var sources: seq[string]
    for source in c.child("sources").strings & suiteOptions.child("sources").strings:
      sources.add(rooted(projectRoot, source))
    if c.child("sources") != nil and c.child("sources").kind == JArray:
      for source in c.child("sources"):
        if source.kind == JObject and source.hasKey("path"):
          sources.add(rooted(projectRoot, source["path"].getStr()))
    var includePaths: seq[string]
    for path in c.child("include").strings: includePaths.add(rooted(projectRoot, path))
    let source = readFile(suite.file)
    let diagnostics = newEngine()
    diagnostics.setSource(source, suite.file)
    var program = newParser(newLexer(source, diagnostics).lex(), diagnostics).parse()
    if diagnostics.failed:
      raise newException(ValueError, renderAll(diagnostics.messages(),
        RenderOptions(style: "short", color: false)))
    if not synthesizeTests(program, suite): raise newException(ValueError, "Test suite was not found: " & suite.name)
    expand(program, diagnostics, projectRoot,
      cBinding.BindOptions(includePaths: includePaths))
    let resolution = newResolver(diagnostics, projectRoot).resolve(program, suite.file)
    program = link(program, resolution)
    lint(program, diagnostics, backend)
    let level = manifest.child("requires").text("base")
    capabilities(program, diagnostics, level)
    let checker = newChecker(diagnostics)
    checker.check(program)
    if diagnostics.failed:
      raise newException(ValueError, renderAll(diagnostics.messages(),
        RenderOptions(style: "short", color: false)))
    let module = monomorphize(lower(program, checker.types))
    let outDir = projectRoot / ".artifacts" / "test" /
      (splitFile(suite.file).name & "_" & suite.name).replace(' ', '_')
    createDir(outDir)
    let cCompiler = if getEnv("CC").len > 0: getEnv("CC") elif findExe("clang").len > 0: findExe("clang") else: "cc"
    ensure(level)
    let nativeConfig = build.child("native")
    let native = buildOptions.Native(name: "test", kind: "exe",
      compile: true, level: level,
      compiler: if backend == "c": cCompiler else: "",
      runtime: build.child("runtime").text(),
      substrate: build.child("substrate").text(),
      native: buildOptions.NativeBinding(
        substrate: nativeConfig.child("substrate").text(),
        clobbers: nativeConfig.child("clobbers").strings),
      cpu: build.child("cpu").text(), coverage: build.child("coverage").text(),
      sanitize: build.child("sanitize").text(), docs: build.child("docs").flag,
      sources: sources, includePaths: includePaths, flags: c.child("flags").strings,
      libs: linkOptions.child("libs").strings,
      frameworks: linkOptions.child("frameworks").strings,
      cpp: linkOptions.child("cpp").flag)
    var success = false
    var artifactPath, buildError: string
    if backend == "c":
      let built = cDriver.build(module, "dev", outDir, native, suite.file)
      success = built.success; artifactPath = built.artifact; buildError = built.error
    else:
      let zig = detect().path
      if zig.len == 0: raise newException(IOError, "Zig backend is missing; install the pinned toolchain")
      let built = zigDriver.build(module, "dev", outDir, zig, suite.file, native)
      success = built.success; artifactPath = built.artifact; buildError = built.error
    if not success: raise newException(OSError, if buildError.len > 0: buildError else: "Test build failed")
    let execution = execCmdEx(quoteShell(artifactPath), workingDir = projectRoot)
    result.passed = execution.exitCode == 0
    result.output = execution.output
    result.files = @[suite.file] & sources & (if fileExists(manifestPath): @[manifestPath] else: @[])
    result.opaque = sources.len > 0 or native.libs.len > 0
    if not result.passed: result.error = "Test process exited with " & $execution.exitCode
  except CatchableError as error:
    result.passed = false
    result.error = error.msg
  result.timeMs = int((epochTime() - started) * 1000)

proc runTests*(root = getCurrentDir(); filter = ""; backend = "zig"; executor: TestExecutor = nil): seq[TestResult] =
  var suites = discoverTests(root)
  if filter.len > 0: suites = suites.filterIt(filter in it.name)
  for suite in suites: result.add(runSingleTest(suite, backend, executor))

proc watchTests*(root = getCurrentDir(); filter = ""; backend = "zig"; executor: TestExecutor = nil): TestWatcher =
  TestWatcher(root: absolutePath(root), filter: filter, backend: backend, executor: executor,
    snapshot: initTable[string, string]())

proc poll*(watcher: TestWatcher): seq[TestResult] =
  if watcher == nil or watcher.stopped: return @[]
  var changed = watcher.snapshot.len == 0
  var current = initTable[string, string]()
  for suite in discoverTests(watcher.root):
    let stamp = $getLastModificationTime(suite.file)
    current[suite.file] = stamp
    if watcher.snapshot.getOrDefault(suite.file) != stamp: changed = true
  watcher.snapshot = current
  if changed: result = runTests(watcher.root, watcher.filter, watcher.backend, watcher.executor)

proc stop*(watcher: TestWatcher) =
  if watcher != nil: watcher.stopped = true
