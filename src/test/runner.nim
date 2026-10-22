import std/[json, os, sequtils, strutils, tables, times]
import ../ast/node as ast
import ../diag/engine
import ../diag/render
import ../lex/lexer
import ../ast/parser
import ../sema/resolver
import ../sema/link
import ../interop/expand
import "../interop/bind.nim" as binding
import ../pkg/lint
import ../pkg/hash
import ../types/checker
import ../ir/eval as evaluation
import ../ir/[lower, monomorph]
import ../backend/qbe/driver as qbe
import ../build/compiler as compilation
import ../build/options as configuration
import ../config/project as projectConfig
import ../toolchain/capability
import ./cache as receipts
import ./process as processes

type
  Suite* = object
    name*: string
    file*: string
    line*: int
  Result* = object
    suite*: Suite
    passed*: bool
    timeMs*: int
    output*: string
    stdout*, stderr*: string
    exitCode*: int
    executed*: bool
    error*: string
    files*: seq[string]
    opaque*: bool
  Executor* = proc(suite: Suite): Result {.closure.}
  Watcher* = ref object
    root*: string
    filter*: string
    backend*: string
    executor*: Executor
    stopped*: bool
    snapshot*: Table[string, string]

proc read(path: string): tuple[program: ast.Program, failed: bool] =
  let source = readFile(path)
  let diag = engine()
  diag.source(source, path)
  let program = parser(lexer(source, diag).lex(), diag).parse()
  (program: program, failed: diag.failed)

proc inspect(path: string; startup: bool; suites: var seq[Suite]) =
  if not path.toLowerAscii().endsWith(".iv"): return
  let parsed = read(path)
  if parsed.failed:
    suites.add(Suite(name: splitFile(path).name, file: path, line: 1))
    return
  for unit in parsed.program.units:
    var test = false
    for statement in unit.body.stmts:
      if statement.tag == "test":
        test = true
        let section = ast.Test(statement)
        suites.add(Suite(name: section.name.value, file: path, line: statement.span.line))
    if startup and not test:
      for statement in unit.body.stmts:
        if statement.tag == "function" and ast.Function(statement).name.text == "start":
          suites.add(Suite(name: splitFile(path).name, file: path, line: statement.span.line))
          break

proc discover*(root: string; includeStarts = false): seq[Suite] =
  var library = ""
  proc fixtures(directory: string): bool =
    if not dirExists(directory): return false
    for kind, path in walkDir(directory):
      if kind == pcFile and path.toLowerAscii().endsWith(".iv"): return true
  for candidate in [getCurrentDir() / "test" / "library",
      getAppDir().parentDir / "test" / "library",
      getAppDir().parentDir.parentDir / "test" / "library",
      currentSourcePath.parentDir.parentDir.parentDir / "test" / "library"]:
    if fixtures(candidate):
      library = absolutePath(candidate)
      break
  let selected = if root == "lib": library else: absolutePath(root)
  let starts = includeStarts or fileExists(selected) or selected == library
  var suites: seq[Suite] = @[]
  if fileExists(selected):
    inspect(selected, true, suites)
    return suites
  if not dirExists(selected): return @[]
  proc visit(directory: string) =
    for kind, path in walkDir(directory):
      let name = path.lastPathPart
      if kind == pcLinkToDir or kind == pcLinkToFile: continue
      if kind == pcDir:
        if name in ["node_modules", ".artifacts", ".foo", ".git", "benchmark"]:
          continue
        visit(path)
      elif kind == pcFile:
        inspect(path, starts, suites)
  if selected == library:
    visit(selected)
  elif projectConfig.manifestExists(selected):
    var source = "src"
    try:
      let manifest = projectConfig.readProject(selected)
      let configured = if manifest.hasKey("source") and
          manifest["source"].kind == JString: manifest["source"].getStr() else: ""
      if configured.len > 0: source = configured
    except CatchableError:
      discard
    let roots = @[selected / source, selected / "test"].deduplicate()
    for directory in roots:
      if dirExists(directory): visit(directory)
  else:
    visit(selected)
  result = suites

proc synthesize*(program: ast.Program; selected: Suite) : bool =
  ## Replace the selected test block with a start entry that calls only that block.
  for unit in program.units:
    var target: ast.Test
    for statement in unit.body.stmts:
      if statement.tag == "test":
        let section = ast.Test(statement)
        if section.name.value == selected.name and statement.span.line == selected.line:
          target = section
          break
    if target == nil: continue
    let span = target.span
    var start: ast.Function
    for statement in unit.body.stmts:
      if statement.tag == "function" and ast.Function(statement).name.text == "start":
        start = ast.Function(statement)
        break
    if start == nil:
      let label = ast.Name(tag: "name", span: span, text: "start")
      start = ast.Function(tag: "function", span: span, public: true, name: label,
        generics: @[], params: @[], returns: nil, abi: "", constraint: nil,
        constraints: @[], attributes: @[], body: target.body)
      unit.body.stmts.add(ast.Statement(start))
    else:
      start.body = target.body
    var filtered: seq[ast.Statement] = @[]
    for statement in unit.body.stmts:
      # Only the synthesized start is checked/lowered. Remaining test bodies
      # have not been linked as functions and can retain unresolved imports.
      if statement.tag != "test": filtered.add(statement)
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

proc execute*(suite: Suite; backend = "qbe"; executor: Executor = nil;
    progress: configuration.Observer = nil; mode = "dev"): Result =
  let started = epochTime()
  let optimization = if mode.len > 0: mode else: "dev"
  if executor != nil:
    if progress != nil: progress("run", suite.name, "", false)
    result = executor(suite)
    if progress != nil:
      progress(if result.passed: "ran" else: "failed", suite.name,
        result.error, false)
    result.timeMs = int((epochTime() - started) * 1000)
    return
  result.suite = suite
  try:
    if backend != "qbe":
      raise newException(ValueError, "Tests execute QBE only; select the qbe backend")
    var project = if dirExists(suite.file): suite.file else: parentDir(suite.file)
    while not projectConfig.manifestExists(project) and
        parentDir(project) != project:
      project = parentDir(project)
    if not projectConfig.manifestExists(project):
      project = parentDir(suite.file)
    let manifest = projectConfig.readProject(project)
    let build = manifest.child("build")
    let c = build.child("c")
    let linking = build.child("link")
    let testing = manifest.child("tests").child(splitFile(suite.file).name)
    var sources: seq[string]
    for source in c.child("sources").strings & testing.child("sources").strings:
      sources.add(rooted(project, source))
    if c.child("sources") != nil and c.child("sources").kind == JArray:
      for source in c.child("sources"):
        if source.kind == JObject and source.hasKey("path"):
          sources.add(rooted(project, source["path"].getStr()))
    var includes: seq[string]
    for path in c.child("include").strings: includes.add(rooted(project, path))
    let source = readFile(suite.file)
    var inputs: seq[tuple[path, sha256: string]] = @[(absolutePath(suite.file).replace('\\', '/'), digest(source))]
    for operand in projectConfig.manifestFiles(project):
      inputs.add((absolutePath(operand).replace('\\', '/'),checksum(operand)))
    if progress != nil:
      progress("check", relativePath(suite.file, project), suite.file, false)
    let diagnostics = engine()
    diagnostics.source(source, suite.file)
    var program = parser(lexer(source, diagnostics).lex(), diagnostics).parse()
    if diagnostics.failed:
      raise newException(ValueError, render(diagnostics.messages(),
        Style(style: "short", color: false)))
    if not synthesize(program, suite): raise newException(ValueError, "Test suite was not found: " & suite.name)
    evaluation.expand(program)
    compilation.prepare(program)
    expand(program, diagnostics, project,
      binding.Binding(includes: includes))
    let resolution = resolver(diagnostics, project, parse =
      proc(importedFile, input: string; diag: Engine): ast.Program =
        inputs.add((absolutePath(importedFile).replace('\\', '/'), digest(input)))
        diag.source(input, importedFile)
        result = parser(lexer(input, diag).lex(), diag).parse()
        if not diag.failed:
          evaluation.expand(result)
          compilation.prepare(result)
          expand(result, diag, project,
            binding.Binding(includes: includes))).resolve(program, suite.file)
    program = link(program, resolution)
    lint(program, diagnostics, backend)
    let level = manifest.child("requires").text("base")
    capabilities(program, diagnostics, level)
    let checker = checker(diagnostics)
    checker.check(program)
    if diagnostics.failed:
      raise newException(ValueError, render(diagnostics.messages(),
        Style(style: "short", color: false)))
    if progress != nil:
      progress("checked", relativePath(suite.file, project), suite.file, false)
    var module = monomorphize(lower(program, checker.types))
    module.inputs = inputs
    if optimization == "release":
      module = optimize(module, Policy(inline: true,
        backend: backend, mode: optimization,
        vectorize: build.child("runtime").text() != "none",
        cpu: build.child("cpu").text())).module
    let directory = receipts.directory(project, suite.file, suite.name,
      suite.line, backend, optimization)
    var guard = receipts.acquire(directory)
    defer: guard.release()
    ensure(level)
    let config = build.child("native")
    let native = configuration.Native(name: "test", kind: "exe", target:
      when defined(windows): "windows-x64"
      elif defined(arm64): "linux-arm64"
      else: "linux-x64",
      jobs: 1,
      compile: true, level: level,
      runtime: build.child("runtime").text(),
      substrate: build.child("substrate").text(),
      native: configuration.Boundary(
        substrate: config.child("substrate").text(),
        clobbers: config.child("clobbers").strings),
      cpu: build.child("cpu").text(), coverage: build.child("coverage").text(),
      sanitize: build.child("sanitize").text(), docs: build.child("docs").flag,
      sources: sources, includes: includes, flags: c.child("flags").strings,
      libs: linking.child("libs").strings,
      frameworks: linking.child("frameworks").strings,
      cpp: linking.child("cpp").flag)
    var success = false
    var location, failure: string
    if progress != nil: progress("build", suite.name, "", false)
    let built = qbe.build(module, optimization, directory, native, suite.file, progress)
    success = built.success; location = built.artifact; failure = built.error
    if not success: raise newException(OSError, if failure.len > 0: failure else: "Test build failed")
    if progress != nil: progress("done", suite.name, location, false)
    if progress != nil: progress("run", suite.name, location, false)
    let execution = processes.observe(location, directory, "execution", project)
    result.executed = true
    result.exitCode = execution.exitCode
    result.stdout = execution.stdout
    result.stderr = execution.stderr
    result.passed = execution.exitCode == 0
    if progress != nil:
      progress(if result.passed: "ran" else: "failed", suite.name,
        execution.stdout & execution.stderr, false)
    result.output = execution.stdout & execution.stderr
    result.files = @[suite.file] & sources & projectConfig.manifestFiles(project)
    result.opaque = sources.len > 0 or native.libs.len > 0
    if not result.passed: result.error = "Test process exited with " & $execution.exitCode
  except CatchableError as error:
    if progress != nil: progress("failed", suite.name, error.msg, false)
    result.passed = false
    result.error = error.msg
  result.timeMs = int((epochTime() - started) * 1000)

proc run*(root = getCurrentDir(); filter = ""; backend = "qbe";
    executor: Executor = nil; progress: configuration.Observer = nil;
    mode = "dev"): seq[Result] =
  var suites = discover(root)
  if filter.len > 0: suites = suites.filterIt(filter in it.name)
  if progress != nil:
    if executor == nil:
      for stage in ["Source", "Compilation"]:
        progress("plan", stage, $suites.len, false)
    progress("plan", "Execution", $suites.len, false)
  for suite in suites:
    result.add(execute(suite, backend, executor, progress, mode))

proc watch*(root = getCurrentDir(); filter = ""; backend = "qbe"; executor: Executor = nil): Watcher =
  Watcher(root: absolutePath(root), filter: filter, backend: backend, executor: executor,
    snapshot: initTable[string, string]())

proc poll*(watcher: Watcher): seq[Result] =
  if watcher == nil or watcher.stopped: return @[]
  var changed = watcher.snapshot.len == 0
  var current = initTable[string, string]()
  for suite in discover(watcher.root):
    let stamp = $getLastModificationTime(suite.file)
    current[suite.file] = stamp
    if watcher.snapshot.getOrDefault(suite.file) != stamp: changed = true
  watcher.snapshot = current
  if changed: result = run(watcher.root, watcher.filter, watcher.backend, watcher.executor)

proc stop*(watcher: Watcher) =
  if watcher != nil: watcher.stopped = true
