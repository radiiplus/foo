import std/[json, os, osproc, sequtils, streams, strutils, tables]
import ./[project as workspace, runner]
import ./link as linking
import ./display as presentation
import ../ir/print
import ../build/project as projects
import ../build/targets as presets
import ../build/release as publishing
import ../build/compiler as compilation
import ../diag/render
import ../diag/engine
import ../diag/palette
import ./benchmark as measurement
import ../toolchain/qbe as toolchains
import ../toolchain/doctor as inspection
import ../pkg/[hash, registry as repository]
import ../config/project as projectConfig
import ../config/document as documents
import ../config/source as configSource
import ../config/capability as configCapability
import "../interop/bind.nim" as binding
import ./lsp as protocol

const usage = "usage: foo <login|init|publish|install|update|upgrade|outdated|remove|deprecate|search|info|new|check|build|run|release|sign|link|unlink|path|watch|graph|ir|test|benchmark|fmt|doc|add|config|toolchain|clean|doctor|version|task|lsp|bind|cc> [options]"
const text = staticRead("../../package.json")
const spelling = staticRead("../../project.ivc")
const projectSchema = staticRead("../config/project.cap")

proc version(): string =
  let package = parseJson(text)
  let project = configSource.loadText(spelling, "project.ivc").values["project"]
  configCapability.validate(configCapability.readText(projectSchema, "project.cap"),
    project)
  "FOO IV\ncompiler " & package.getOrDefault("version").getStr() &
    "\nlanguage " & project.getOrDefault("language").getStr()

proc upgrade(check: bool) =
  var root = getAppDir()
  var script = ""
  for depth in 0..4:
    let candidate = root / "tools" / "upgrade.mjs"
    if fileExists(candidate): script = candidate; break
    root = parentDir(root)
  if script.len == 0: raise newException(IOError, "FOO upgrade helper is missing from this installation")
  let node = findExe("node")
  if node.len == 0: raise newException(IOError, "FOO upgrade requires Node.js on PATH")
  let current = parseJson(text)["version"].getStr()
  let command = quoteShell(node) & " " & quoteShell(script) & " " &
    quoteShell(current) & " --parent " & $getCurrentProcessId() &
    (if check: " --check" else: "")
  let response = execCmdEx(command)
  if response.exitCode != 0: raise newException(IOError, response.output.strip())
  stdout.write(response.output)

proc issue(value: string; color = true): string =
  let label = "error:"
  if color and getEnv("NO_COLOR").len == 0 and getEnv("TERM") != "dumb":
    shade("error") & label & "\e[0m " & value
  else:
    label & " " & value

proc stamp(root: string): string =
  let project = projects.project(root)
  var content = ""
  for manifest in projectConfig.manifestFiles(root):
    content.add(manifest & "\0" & readFile(manifest))
  for file in project.files(): content.add(file & "\0" & readFile(file))
  digest(content)

proc watch(root: string; action: proc() {.closure.}) =
  action()
  var stamp = stamp(root)
  stderr.writeLine("Watching for changes.")
  while true:
    sleep(250)
    let next = stamp(root)
    if next != stamp:
      stamp = next
      try: action()
      except CatchableError as error: stderr.writeLine(error.msg)

proc main*(input: seq[string]): int =
  if input.len == 0:
    stderr.writeLine(usage)
    return 2
  var instruction: presentation.Operation
  try:
    if input.len == 1 and input[0] in ["version", "--version"]:
      echo version()
      return 0
    if input[0] == "upgrade":
      if input.len > 2 or (input.len == 2 and input[1] != "--check"):
        raise newException(ValueError, "usage: foo upgrade [--check]")
      upgrade(input.len == 2)
      return 0
    if input[0] == "doc":
      if input.len > 2: raise newException(ValueError, "usage: foo doc [file.iv|library]")
      stdout.write(doc(if input.len > 1: input[1] else: ""))
      return 0
    if input[0] == "toolchain":
      let explain = "--explain" in input
      let compact = "--compact" in input
      let arguments = input.filterIt(it notin ["--explain", "--compact"])
      instruction = presentation.operation("TOOLCHAIN", explain = explain,
        compact = compact)
      if arguments.len == 1:
        var selected = ""
        try:
          let tools = toolchains.identity()
          selected = tools.qbe
        except CatchableError:
          selected = ""
        instruction.update("Compiler", "QBE",
          if selected.len > 0: presentation.stateComplete else: presentation.stateAttention,
          if selected.len > 0: selected else: "not configured", true)
        instruction.update("Capability", "base",
          if selected.len > 0: presentation.stateComplete else: presentation.stateSkipped)
        instruction.finish(selected.len > 0,
          if selected.len > 0: "toolchain ready" else: "toolchain unavailable")
      elif arguments.len == 2 and arguments[1] == "install":
        let selected = toolchains.identity()
        instruction.update("Compiler", "QBE", presentation.stateComplete,
          selected.qbe & "; C compiler: " & selected.cc, true)
        instruction.finish(summary = "toolchain ready")
      else:
        raise newException(ValueError,
          "usage: foo toolchain [--explain] [--compact]")
      instruction = nil
      return 0
    if input[0] == "doctor":
      if input.len > 2 or (input.len == 2 and input[1] != "--json"):
        raise newException(ValueError, "usage: foo doctor [--json]")
      let components = inspection.doctor()
      if "--json" in input:
        var values = newJArray()
        for component in components:
          values.add(%*{"name": component.name, "ready": component.ready,
            "required": component.required, "detail": component.detail})
        echo $(%*{"format": "foo.doctor", "version": 1, "components": values})
      else:
        for component in components:
          echo (if component.ready: "Ready"
            elif component.required: "Missing" else: "Optional") &
            " - " & component.name & "\n  " & component.detail
      if components.anyIt(it.required and not it.ready): return 1
      return 0
    if input[0] == "new":
      if input.len != 2: raise newException(ValueError, "usage: foo new <directory|.>")
      discard workspace.create(input[1])
      return 0
    if input[0] == "init":
      if input.len > 2: raise newException(ValueError, "usage: foo init [directory|.]")
      let root = workspace.package(if input.len == 2: input[1] else: ".")
      echo "Initialized " & root & "."
      return 0
    if input[0] == "login":
      if input.len != 1: raise newException(ValueError, "usage: foo login")
      discard repository.login()
      echo "Logged in with GitHub."
      return 0
    if input[0] == "clean":
      if input.len != 1: raise newException(ValueError, "usage: foo clean")
      workspace.clean()
      return 0
    if input[0] == "config":
      if input.len notin [2, 3] or input[1] notin ["check", "emit"]:
        raise newException(ValueError, "usage: foo config <check|emit> [file.ivc]")
      if input.len == 2 and not projectConfig.manifestExists(getCurrentDir()):
        raise newException(ValueError, "No project manifest in the current directory")
      let path = if input.len == 3: input[2]
        else: projectConfig.manifestPath(getCurrentDir())
      if input[1] == "check":
        discard documents.check(path)
        echo "Configuration valid."
      else:
        echo documents.emit(path)
      return 0
    if input[0] == "path":
      if input.len != 1: raise newException(ValueError, "usage: foo path")
      echo linking.directory()
      return 0
    if input[0] == "link":
      var entry, name: string
      var index = 1
      while index < input.len:
        if input[index] == "--name":
          inc index
          if index >= input.len:
            raise newException(ValueError, "--name needs a command name")
          name = input[index]
        elif input[index].startsWith("--"):
          raise newException(ValueError, "unknown option: " & input[index])
        elif entry.len == 0: entry = input[index]
        else:
          raise newException(ValueError,
            "usage: foo link [entry] [--name command]")
        inc index
      let linked = linking.install(projects.project(getCurrentDir()),
        entry, name)
      echo "Linked " & linked.lastPathPart & " at " & linked & "."
      if not linking.available():
        echo "Add " & linking.directory() & " to PATH for direct commands."
      return 0
    if input[0] == "unlink":
      if input.len != 2:
        raise newException(ValueError, "usage: foo unlink <command>")
      let removed = linking.remove(input[1])
      echo "Removed " & removed & "."
      return 0
    if input[0] == "add":
      if input.len notin [2, 3]:
        raise newException(ValueError, "usage: foo add <package[@version]> [url|path]")
      var name = input[1]
      var source = if input.len == 3: input[2] else: ""
      if source.len == 0:
        let at = name.rfind('@')
        if at > 0:
          source = name[at + 1 .. ^1]
          name = name[0 ..< at]
        else:
          source = repository.latest(getCurrentDir(), name)
      workspace.dependency("add", name, source)
      let normalized = workspace.origin(name, source, getCurrentDir())
      if normalized[0] in {'^', '~'} or normalized[0].isDigit:
        echo "Added " & name & "@" & normalized & " to " &
          projectConfig.manifestPath(getCurrentDir()).lastPathPart & "."
      else:
        echo "Added " & name & " from " & normalized & " to " &
          projectConfig.manifestPath(getCurrentDir()).lastPathPart & "."
      echo "Run 'foo install' to resolve and install the dependency."
      return 0
    if input[0] in ["publish", "install", "update", "outdated", "remove", "deprecate", "search", "info"]:
      let root = getCurrentDir()
      let explain = "--explain" in input
      let compact = "--compact" in input
      if compact and input[0] notin ["publish", "install", "update", "remove"]:
        raise newException(ValueError,
          "--compact is available for publish, install, update, and remove")
      let operand = input.filterIt(it notin ["--explain", "--compact"])
      case operand[0]
      of "publish":
        if operand.len != 1: raise newException(ValueError, "usage: foo publish [--explain]")
        instruction = presentation.operation("PUBLISH", explain = explain,
          compact = compact)
        let reporter = instruction.reporter()
        projects.project(root,
          projects.Settings(progress: reporter)).check()
        let published = repository.publish(root, progress =
          proc(phase, name, detail: string) = instruction.report(phase, name, detail))
        instruction.finish(summary = published)
        instruction = nil
      of "install":
        if operand.len > 2: raise newException(ValueError, "usage: foo install [package[@version]] [--explain]")
        instruction = presentation.operation("INSTALL", explain = explain,
          compact = compact)
        let packages = repository.install(root,
          if operand.len == 2: operand[1] else: "", progress =
          proc(phase, name, detail: string) = instruction.report(phase, name, detail))
        instruction.finish(summary = $packages.len &
          (if packages.len == 1: " package" else: " packages"))
        instruction = nil
      of "update":
        if operand.len > 2: raise newException(ValueError, "usage: foo update [package] [--explain]")
        instruction = presentation.operation("UPDATE", explain = explain,
          compact = compact)
        let packages = repository.update(root,
          if operand.len == 2: operand[1] else: "", progress =
          proc(phase, name, detail: string) = instruction.report(phase, name, detail))
        instruction.finish(summary = $packages.len &
          (if packages.len == 1: " package" else: " packages"))
        instruction = nil
      of "outdated":
        if operand.len != 1: raise newException(ValueError, "usage: foo outdated")
        let packages = repository.outdated(root)
        if packages.len == 0: echo "All direct dependencies are current."
        for package in packages:
          echo package["name"].getStr() & " " & package["current"].getStr() & " -> " &
            package["latest"].getStr() & " (" & package["constraint"].getStr() & ")"
      of "remove":
        if operand.len != 2: raise newException(ValueError, "usage: foo remove <package> [--explain]")
        instruction = presentation.operation("REMOVE", explain = explain,
          compact = compact)
        let packages = repository.remove(root, operand[1], progress =
          proc(phase, name, detail: string) = instruction.report(phase, name, detail))
        instruction.finish(summary = operand[1] & " removed · " &
          $packages.len & " packages remain")
        instruction = nil
      of "deprecate":
        if operand.len < 3: raise newException(ValueError, "usage: foo deprecate <package@version> <message>")
        echo "Deprecated " & repository.deprecate(root, operand[1], operand[2 .. ^1].join(" ")) & "."
      of "search":
        if operand.len < 2: raise newException(ValueError, "usage: foo search <query>")
        for entry in repository.search(root, operand[1 .. ^1].join(" ")):
          echo entry.getOrDefault("name").getStr() & "@" &
            entry.getOrDefault("version").getStr() & "  " &
            entry.getOrDefault("description").getStr()
      of "info":
        if operand.len != 2: raise newException(ValueError, "usage: foo info <package[@version]>")
        var name = operand[1]
        var version = ""
        let at = name.rfind('@')
        if at > 0:
          version = name[at + 1 .. ^1]
          name = name[0 ..< at]
        echo pretty(repository.info(root, name, version))
      else: discard
      return 0
    if input[0] == "cc":
      let tool = toolchains.cc()
      cc(if input.len > 1: input[1 .. ^1] else: @[], tool)
      return 0
    if input[0] == "bind":
      if input.len < 2:
        raise newException(ValueError, "usage: foo bind <header.h> [-I include] [--target target] [--sysroot path]")
      var includes: seq[string]
      var target = ""
      var sysroot = ""
      var index = 2
      while index < input.len:
        if index + 1 >= input.len:
          raise newException(ValueError, "usage: foo bind <header.h> [-I include] [--target target] [--sysroot path]")
        case input[index]
        of "-I": includes.add(input[index + 1])
        of "--target": target = input[index + 1]
        of "--sysroot": sysroot = input[index + 1]
        else:
          raise newException(ValueError, "usage: foo bind <header.h> [-I include] [--target target] [--sysroot path]")
        index += 2
      let generated = binding.`bind`(input[1],
        binding.Binding(includes: includes, target: target, sysroot: sysroot))
      echo (if generated.cached: "Using cached" else: "Generated") &
        " bindings: " & generated.bindingPath
      echo "Macro hints: " & generated.hintsPath
      for issue in generated.diagnostics:
        stderr.writeLine(issue.code & ": " & issue.message)
      return 0
    if input[0] == "lsp":
      if input.len != 1: raise newException(ValueError, "usage: foo lsp")
      protocol.serve()
      return 0

    var args = input
    if args[0] == "watch":
      args = @["build", "--watch"] &
        (if args.len > 1: args[1 .. ^1] else: @[])
    let command = args[0]
    var verbose, destination, watching, signing, compact: bool
    var warmup = 1
    var iterations = 10
    var target, cpu, backend, filter, mode, provider, kind: string
    var positional, passthrough: seq[string]
    var index = 1
    while index < args.len:
      let argument = args[index]
      if argument == "--":
        if command != "run":
          raise newException(ValueError, "-- argument passthrough is available for foo run")
        if index + 1 < args.len: passthrough = args[index + 1 .. ^1]
        break
      elif argument in ["--verbose", "--explain"]: verbose = true
      elif argument == "--no-batching": putEnv("FOO_IO_BATCHING", "off")
      elif argument == "--json": destination = true
      elif argument == "--compact":
        if command notin ["check", "build", "run", "release", "sign",
            "test", "benchmark"]:
          raise newException(ValueError,
            "--compact is available for check, build, run, release, sign, test, and benchmark")
        compact = true
      elif argument == "--watch": watching = true
      elif argument == "--sign":
        if command != "release":
          raise newException(ValueError, "--sign is available for foo release")
        signing = true
      elif argument == "--provider" or argument.startsWith("--provider="):
        if command notin ["release", "sign"]:
          raise newException(ValueError,
            "--provider is available for foo release and foo sign")
        if argument.contains("="): provider = argument.split("=", 1)[1]
        else:
          inc index
          if index < args.len: provider = args[index]
        if provider notin ["auto", "gpg", "authenticode", "codesign"]:
          raise newException(ValueError,
            "--provider must be auto, gpg, authenticode, or codesign")
      elif argument == "-mcpu" or argument.startsWith("-mcpu="):
        if argument.contains("="): cpu = argument[6 .. ^1]
        else:
          inc index
          if index < args.len: cpu = args[index]
        if cpu.len == 0 or cpu.startsWith("-"):
          raise newException(ValueError, "-mcpu needs a CPU profile")
      elif argument == "--target" or argument.startsWith("--target="):
        if argument.contains("="): target = argument[9 .. ^1]
        else:
          inc index
          if index < args.len: target = args[index]
        if target.len == 0 or target.startsWith("--"):
          raise newException(ValueError, "--target needs a target name")
      elif argument == "--kind" or argument.startsWith("--kind="):
        if command notin ["build", "run", "release"]:
          raise newException(ValueError, "--kind is available for build, run, and release")
        if argument.contains("="): kind = argument.split("=", 1)[1]
        else:
          inc index
          if index < args.len: kind = args[index]
        if kind notin ["exe", "static", "shared", "object", "shader"]:
          raise newException(ValueError,
            "--kind must be exe, static, shared, object, or shader")
      elif argument == "--backend" or argument.startsWith("--backend="):
        if argument.contains("="): backend = argument[10 .. ^1]
        else:
          inc index
          if index < args.len: backend = args[index]
        if backend != "qbe":
          raise newException(ValueError, "--backend must be qbe")
      elif argument == "--mode" or argument.startsWith("--mode="):
        if command notin ["check", "build", "run", "graph", "ir", "test", "benchmark"]:
          raise newException(ValueError, "--mode is available for project commands, test, and benchmark")
        if argument.contains("="): mode = argument[7 .. ^1]
        else:
          inc index
          if index < args.len: mode = args[index]
        if mode notin ["dev", "release"]:
          raise newException(ValueError, "--mode must be dev or release")
      elif argument == "--filter" and command in ["test", "benchmark"]:
        inc index
        if index < args.len: filter = args[index]
        if filter.len == 0:
          raise newException(ValueError, "--filter needs a " &
            (if command == "test": "test" else: "benchmark") & " name")
      elif argument == "--warmup" or argument.startsWith("--warmup="):
        if command != "benchmark": raise newException(ValueError, "--warmup is available for benchmark")
        var value = ""
        if argument.contains("="): value = argument.split("=", 1)[1]
        else:
          inc index
          if index < args.len: value = args[index]
        try: warmup = parseInt(value)
        except ValueError: raise newException(ValueError, "--warmup needs a nonnegative integer")
        if warmup < 0: raise newException(ValueError, "--warmup needs a nonnegative integer")
      elif argument == "--iterations" or argument.startsWith("--iterations="):
        if command != "benchmark": raise newException(ValueError, "--iterations is available for benchmark")
        var value = ""
        if argument.contains("="): value = argument.split("=", 1)[1]
        else:
          inc index
          if index < args.len: value = args[index]
        try: iterations = parseInt(value)
        except ValueError: raise newException(ValueError, "--iterations needs a positive integer")
        if iterations < 1: raise newException(ValueError, "--iterations needs a positive integer")
      elif argument.startsWith("-"):
        raise newException(ValueError, "unknown option: " & argument)
      else: positional.add(argument)
      inc index

    let root = getCurrentDir()
    proc project() =
      let operation = if command in ["check", "build", "run", "release"]:
          presentation.operation(command, destination, verbose, compact)
        else: nil
      instruction = operation
      let settings = projects.Settings(backend: backend,
        target: target, kind: kind, cpu: cpu,
        mode: if command == "release": "release" else: mode,
        progress: if operation != nil: operation.reporter() else: nil)
      let project = projects.project(root, settings)
      let entry = if positional.len > 0: positional[0] else: ""
      if operation != nil:
        let config = project.config()
        operation.configure(root,
          if backend.len > 0: backend elif config.backend.len > 0:
            config.backend else: "qbe",
          if target.len > 0: presets.stable(target, projects.host)
            else: presets.choose(config.target, projects.host),
          if command == "release": "release" elif mode.len > 0: mode
            elif config.optimize.len > 0: config.optimize else: "dev")
        operation.report("plan", "Source",
          $(if entry.len > 0: 1 else: project.files().len))
        if command != "check":
          operation.report("plan", "Compilation",
            $max(1, config.products.len))
        if command == "run": operation.report("plan", "Execution", "1")
        if command == "release": operation.plan("Packaging", 1, 2.0)
      case command
      of "graph": echo pretty(project.graph())
      of "ir":
        if entry.len == 0: raise newException(ValueError, "usage: foo ir <file>")
        echo encode(project.ir(entry))
      of "check":
        project.check(entry)
        operation.finish(summary = $project.files().len &
          (if project.files().len == 1: " file" else: " files") &
          " · 0 errors · 0 warnings")
      of "build":
        let products = project.build(entry)
        operation.finish(summary = $project.files().len &
          (if project.files().len == 1: " file" else: " files") &
          " · " & $products.len &
          (if products.len == 1: " artifact" else: " artifacts") &
          " · 0 errors · 0 warnings")
      of "run":
        let products = project.build(entry, executable = true)
        if products.len != 1:
          raise newException(ValueError,
            "Choose an entry file when a project has multiple executables")
        let artifact = products.values.toSeq[0]
        operation.report("run", "application", "")
        let child = startProcess(artifact, args = passthrough,
          options = {poStdErrToStdOut})
        var output: string
        var status: int
        try:
          child.inputStream.close()
          output = child.outputStream.readAll()
          status = child.waitForExit()
        finally:
          child.close()
        if status == 0:
          operation.report("ran", "application", "")
        else:
          operation.update("Execution", "application", presentation.stateFailed)
        operation.finish(status == 0,
          $project.files().len & (if project.files().len == 1: " file" else: " files") &
          " · 0 errors · 0 warnings")
        instruction = nil
        if output.len > 0: stdout.write(output)
        if status != 0: raise newException(OSError, output)
      of "release":
        if positional.len > 0:
          raise newException(ValueError,
            "usage: foo release [--sign] [--provider name] [--backend qbe] [--target name]")
        operation.update("Packaging", "release", presentation.stateWorking)
        operation.start("Packaging")
        let bundled = publishing.bundle(project, signing, provider)
        operation.update("Packaging", "release", presentation.stateComplete,
          bundled.directory, true)
        operation.finish("Packaging")
        operation.finish(summary = $bundled.artifacts.len &
          (if bundled.artifacts.len == 1: " artifact" else: " artifacts") &
          (if signing: " signed" else: "") & " · " & bundled.directory)
      of "task":
        for file in project.task(positional): echo file
      else: raise newException(ValueError, usage)
      if operation != nil and not operation.finished():
        operation.finish()
      instruction = nil
    if command in ["check", "build", "run", "release", "task", "graph", "ir"]:
      if watching:
        if command notin ["check", "build"]:
          raise newException(ValueError, "--watch is available for check and build")
        watch(root, project)
      else: project()
      return 0
    if command == "sign":
      if positional.len != 1:
        raise newException(ValueError,
          "usage: foo sign <artifact> [--provider name] [--target name]")
      instruction = presentation.operation("SIGN", destination, verbose, compact)
      instruction.plan("Signing", 1, 2.0)
      let project = projects.project(root)
      let artifact = if isAbsolute(positional[0]): positional[0]
        else: root / positional[0]
      instruction.update("Signing", artifact.lastPathPart,
        presentation.stateWorking)
      instruction.start("Signing")
      let signed = publishing.sign(artifact,
        project.manifest().deployment.signing,
        if target.len > 0: projects.triple(target) else: "", provider)
      instruction.update("Signing", artifact.lastPathPart,
        presentation.stateComplete, signed, true)
      instruction.finish("Signing")
      instruction.finish(summary = signed)
      instruction = nil
      return 0
    case command
    of "test":
      if positional.len > 1:
        raise newException(ValueError,
          "usage: foo test [file.iv|directory] [--filter name] [--backend qbe] [--mode dev|release] [--watch]")
      proc tests() =
        instruction = presentation.operation("TEST", destination, verbose, compact)
        instruction.configure(root,
          if backend.len > 0: backend else: "qbe", projects.host,
          if mode.len > 0: mode else: "dev")
        let results = test(if positional.len > 0: positional[0] else: root,
          filter, if backend.len > 0: backend else: "qbe",
          progress = instruction.reporter(),
          mode = if mode.len > 0: mode else: "dev")
        var failed = 0
        for item in results:
          if destination:
            stdout.writeLine($( %*{"event": "test-result", "file": item.suite.file,
              "name": item.suite.name, "line": item.suite.line, "passed": item.passed,
              "executed": item.executed, "exitCode": item.exitCode,
              "stdoutHex": item.stdout.toHex(), "stderrHex": item.stderr.toHex(),
              "error": item.error}))
          if not item.passed: inc failed
          instruction.update("Results", item.suite.name,
            if item.passed: presentation.stateComplete else: presentation.stateFailed,
            if item.error.len > 0: item.error else: $item.timeMs & " ms", true)
        let empty = results.len == 0
        instruction.finish(failed == 0 and not empty, $results.len &
          (if results.len == 1: " test" else: " tests") &
          " · " & $failed & " failed")
        instruction = nil
        if empty:
          raise newException(ValueError,
            "No tests found. Add a test \"description\" { ... } block or select a fixture with start.")
        if failed > 0:
          raise newException(ValueError, "One or more tests failed")
      if watching: watch(root, tests) else: tests()
    of "benchmark":
      if watching: raise newException(ValueError, "--watch is not available for benchmark")
      if positional.len > 1: raise newException(ValueError,
        "usage: foo benchmark [name|benchmark/file.iv] [--warmup N] [--iterations N] [--backend qbe] [--mode dev|release]")
      if positional.len == 1:
        if filter.len > 0: raise newException(ValueError, "Choose a benchmark name or --filter, not both")
        filter = positional[0]
      instruction = presentation.operation("BENCHMARK", destination, verbose, compact)
      instruction.configure(root,
        if backend.len > 0: backend else: "qbe", projects.host,
        if mode.len > 0: mode else: "project")
      let results = measurement.benchmark(root, filter,
        if backend.len > 0: backend else: "qbe", warmup, iterations,
        progress = instruction.reporter(), mode = mode)
      if results.len == 0: raise newException(ValueError,
        "No benchmarks found in benchmark/" &
        (if filter.len > 0: " matching '" & filter & "'" else: ""))
      var failed = 0
      for item in results:
        if item.error.len > 0:
          inc failed
          instruction.update("Results", item.suite.name,
            presentation.stateFailed, item.error, true)
        else:
          let detail = "median " & formatFloat(item.medianMs, ffDecimal, 2) &
            " ms · p95 " & formatFloat(item.percentile95Ms, ffDecimal, 2) &
            " ms · mean " & formatFloat(item.meanMs, ffDecimal, 2) &
            " ms · min " & formatFloat(item.minimumMs, ffDecimal, 2) &
            " ms · max " & formatFloat(item.maximumMs, ffDecimal, 2) & " ms"
          instruction.update("Results", item.suite.name,
            presentation.stateComplete, detail, true)
          if destination:
            echo $(%*{"event": "benchmark", "name": item.suite.name,
              "mode": if mode.len > 0: mode else: "project",
              "warmup": item.warmup, "iterations": item.iterations,
              "minimumMs": item.minimumMs, "medianMs": item.medianMs,
              "meanMs": item.meanMs, "maximumMs": item.maximumMs,
              "percentile95Ms": item.percentile95Ms,
              "samplesMs": item.samplesMs,
              "metricsSamples": item.metricsSamples,
              "compilationMs": item.compilationMs, "cached": item.cached,
              "metrics": item.metrics, "optimization": item.optimization})
      instruction.finish(failed == 0, $results.len &
        (if results.len == 1: " benchmark" else: " benchmarks") &
        " · " & $failed & " failed")
      instruction = nil
      if failed > 0: raise newException(ValueError, "One or more benchmarks failed")
    of "fmt":
      discard fmt(if positional.len > 0: positional[0] else: "main.iv")
    else:
      stderr.writeLine(usage)
      return 2
    0
  except compilation.Diagnostics as error:
    if instruction != nil and not instruction.finished():
      instruction.finish(false, $error.diagnostics.messages().len & " errors")
    let verbose = "--verbose" in input or "--explain" in input
    let destination = "--json" in input
    let style = if destination: "json" elif verbose: "verbose" else: "short"
    stderr.writeLine(render(error.diagnostics.messages(),
      Style(color: getEnv("NO_COLOR").len == 0 and
        getEnv("TERM") != "dumb", style: style, codes: verbose)))
    1
  except CatchableError as error:
    if instruction != nil and not instruction.finished():
      instruction.finish(false, "1 error")
    stderr.writeLine(issue(error.msg, "--json" notin input))
    1

when isMainModule:
  quit(main(commandLineParams()))
