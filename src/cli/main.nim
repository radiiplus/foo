import std/[json, os, osproc, sequtils, strutils, tables]
import ./[project as cliProject, runner]
import ./link as cliLink
import ./display as cliDisplay
import ../ir/print
import ../build/project as buildProject
import ../build/release as buildRelease
import ../build/compiler as buildCompiler
import ../diag/render
import ../diag/engine
import ../diag/palette
import ../benchmark/runner as benchmarkRunner
import ../toolchain/manager as toolchainManager
import ../toolchain/doctor as toolchainDoctor
import ../pkg/[hash, registry as packageRegistry]
import "../interop/bind.nim" as interopBind
import ../lsp/server as lspServer

const usage = "usage: foo <login|init|publish|install|update|outdated|remove|deprecate|search|info|new|check|build|run|release|sign|link|unlink|path|watch|graph|ir|test|benchmark|fmt|doc|add|toolchain|clean|doctor|version|task|lsp|bind|cc> [options]"
const packageText = staticRead("../../package.json")
const projectText = staticRead("../../project.json")

proc productVersion(): string =
  let package = parseJson(packageText)
  let project = parseJson(projectText)
  "FOO IV\ncompiler " & package.getOrDefault("version").getStr() &
    "\nlanguage " & project.getOrDefault("language").getStr()

proc errorLine(value: string; color = true): string =
  let label = "error:"
  if color and getEnv("NO_COLOR").len == 0 and getEnv("TERM") != "dumb":
    shade("error") & label & "\e[0m " & value
  else:
    label & " " & value

proc projectStamp(root: string): string =
  let project = buildProject.newProject(root)
  var content = ""
  let manifest = root / "project.json"
  if fileExists(manifest): content.add(manifest & "\0" & readFile(manifest))
  for file in project.files(): content.add(file & "\0" & readFile(file))
  sha256Hex(content)

proc watch(root: string; action: proc() {.closure.}) =
  action()
  var stamp = projectStamp(root)
  stderr.writeLine("Watching for changes.")
  while true:
    sleep(250)
    let next = projectStamp(root)
    if next != stamp:
      stamp = next
      try: action()
      except CatchableError as error: stderr.writeLine(error.msg)

proc main*(input: seq[string]): int =
  if input.len == 0:
    stderr.writeLine(usage)
    return 2
  var activeOperation: cliDisplay.Operation
  try:
    if input.len == 1 and input[0] in ["version", "--version"]:
      echo productVersion()
      return 0
    if input[0] == "doc":
      if input.len > 2: raise newException(ValueError, "usage: foo doc [file.iv|library]")
      stdout.write(doc(if input.len > 1: input[1] else: ""))
      return 0
    if input[0] == "toolchain":
      let explain = "--explain" in input
      let compact = "--compact" in input
      let toolInput = input.filterIt(it notin ["--explain", "--compact"])
      activeOperation = cliDisplay.newOperation("TOOLCHAIN", explain = explain,
        compact = compact)
      if toolInput.len == 1:
        let found = toolchainManager.detect()
        activeOperation.update("Compiler", "backend",
          if found.path.len > 0: cliDisplay.stateComplete else: cliDisplay.stateAttention,
          if found.path.len > 0: found.version else: "not installed", true)
        activeOperation.update("Capability", "base",
          if found.path.len > 0: cliDisplay.stateComplete else: cliDisplay.stateSkipped)
        activeOperation.finish(found.path.len > 0,
          if found.path.len > 0: "toolchain ready" else: "toolchain unavailable")
      elif toolInput.len == 3 and toolInput[1] == "install" and
          toolInput[2] in toolchainManager.levels:
        discard toolchainManager.install(progress =
          proc(phase, name, detail: string) =
            activeOperation.report(phase, name, detail))
        toolchainManager.ensure(toolInput[2])
        activeOperation.update("Capability", toolInput[2], cliDisplay.stateComplete)
        activeOperation.finish(summary = toolInput[2] & " capability ready")
      else:
        raise newException(ValueError,
          "usage: foo toolchain [install base|system|machine|hardware] [--explain] [--compact]")
      activeOperation = nil
      return 0
    if input[0] == "doctor":
      if input.len > 2 or (input.len == 2 and input[1] != "--json"):
        raise newException(ValueError, "usage: foo doctor [--json]")
      let components = toolchainDoctor.doctor()
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
      discard cliProject.create(input[1])
      return 0
    if input[0] == "init":
      if input.len > 2: raise newException(ValueError, "usage: foo init [directory|.]")
      let root = cliProject.createPackage(if input.len == 2: input[1] else: ".")
      echo "Initialized " & root & "."
      return 0
    if input[0] == "login":
      if input.len != 1: raise newException(ValueError, "usage: foo login")
      discard packageRegistry.login()
      echo "Logged in with GitHub."
      return 0
    if input[0] == "clean":
      if input.len != 1: raise newException(ValueError, "usage: foo clean")
      cliProject.clean()
      return 0
    if input[0] == "path":
      if input.len != 1: raise newException(ValueError, "usage: foo path")
      echo cliLink.directory()
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
      let linked = cliLink.install(buildProject.newProject(getCurrentDir()),
        entry, name)
      echo "Linked " & linked.lastPathPart & " at " & linked & "."
      if not cliLink.available():
        echo "Add " & cliLink.directory() & " to PATH for direct commands."
      return 0
    if input[0] == "unlink":
      if input.len != 2:
        raise newException(ValueError, "usage: foo unlink <command>")
      let removed = cliLink.remove(input[1])
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
          source = packageRegistry.latestVersion(getCurrentDir(), name)
      cliProject.dependency("add", name, source)
      let normalized = cliProject.dependencySource(name, source, getCurrentDir())
      if normalized[0] in {'^', '~'} or normalized[0].isDigit:
        echo "Added " & name & "@" & normalized & " to project.json."
      else:
        echo "Added " & name & " from " & normalized & " to project.json."
      echo "Run 'foo install' to resolve and install the dependency."
      return 0
    if input[0] in ["publish", "install", "update", "outdated", "remove", "deprecate", "search", "info"]:
      let root = getCurrentDir()
      let explain = "--explain" in input
      let compact = "--compact" in input
      if compact and input[0] notin ["publish", "install", "update", "remove"]:
        raise newException(ValueError,
          "--compact is available for publish, install, update, and remove")
      let packageInput = input.filterIt(it notin ["--explain", "--compact"])
      case packageInput[0]
      of "publish":
        if packageInput.len != 1: raise newException(ValueError, "usage: foo publish [--explain]")
        activeOperation = cliDisplay.newOperation("PUBLISH", explain = explain,
          compact = compact)
        let reporter = activeOperation.reporter()
        buildProject.newProject(root,
          buildProject.ProjectOptions(progress: reporter)).check()
        let published = packageRegistry.publish(root, progress =
          proc(phase, name, detail: string) = activeOperation.report(phase, name, detail))
        activeOperation.finish(summary = published)
        activeOperation = nil
      of "install":
        if packageInput.len > 2: raise newException(ValueError, "usage: foo install [package[@version]] [--explain]")
        activeOperation = cliDisplay.newOperation("INSTALL", explain = explain,
          compact = compact)
        let packages = packageRegistry.install(root,
          if packageInput.len == 2: packageInput[1] else: "", progress =
          proc(phase, name, detail: string) = activeOperation.report(phase, name, detail))
        activeOperation.finish(summary = $packages.len &
          (if packages.len == 1: " package" else: " packages"))
        activeOperation = nil
      of "update":
        if packageInput.len > 2: raise newException(ValueError, "usage: foo update [package] [--explain]")
        activeOperation = cliDisplay.newOperation("UPDATE", explain = explain,
          compact = compact)
        let packages = packageRegistry.update(root,
          if packageInput.len == 2: packageInput[1] else: "", progress =
          proc(phase, name, detail: string) = activeOperation.report(phase, name, detail))
        activeOperation.finish(summary = $packages.len &
          (if packages.len == 1: " package" else: " packages"))
        activeOperation = nil
      of "outdated":
        if packageInput.len != 1: raise newException(ValueError, "usage: foo outdated")
        let packages = packageRegistry.outdated(root)
        if packages.len == 0: echo "All direct dependencies are current."
        for package in packages:
          echo package["name"].getStr() & " " & package["current"].getStr() & " -> " &
            package["latest"].getStr() & " (" & package["constraint"].getStr() & ")"
      of "remove":
        if packageInput.len != 2: raise newException(ValueError, "usage: foo remove <package> [--explain]")
        activeOperation = cliDisplay.newOperation("REMOVE", explain = explain,
          compact = compact)
        let packages = packageRegistry.removePackage(root, packageInput[1], progress =
          proc(phase, name, detail: string) = activeOperation.report(phase, name, detail))
        activeOperation.finish(summary = packageInput[1] & " removed · " &
          $packages.len & " packages remain")
        activeOperation = nil
      of "deprecate":
        if packageInput.len < 3: raise newException(ValueError, "usage: foo deprecate <package@version> <message>")
        echo "Deprecated " & packageRegistry.deprecate(root, packageInput[1], packageInput[2 .. ^1].join(" ")) & "."
      of "search":
        if packageInput.len < 2: raise newException(ValueError, "usage: foo search <query>")
        for entry in packageRegistry.search(root, packageInput[1 .. ^1].join(" ")):
          echo entry.getOrDefault("name").getStr() & "@" &
            entry.getOrDefault("version").getStr() & "  " &
            entry.getOrDefault("description").getStr()
      of "info":
        if packageInput.len != 2: raise newException(ValueError, "usage: foo info <package[@version]>")
        var name = packageInput[1]
        var version = ""
        let at = name.rfind('@')
        if at > 0:
          version = name[at + 1 .. ^1]
          name = name[0 ..< at]
        echo pretty(packageRegistry.info(root, name, version))
      else: discard
      return 0
    if input[0] == "cc":
      let tool = toolchainManager.install().path
      cc(if input.len > 1: input[1 .. ^1] else: @[], tool)
      return 0
    if input[0] == "bind":
      if input.len < 2:
        raise newException(ValueError, "usage: foo bind <header.h> [-I include]")
      var includes: seq[string]
      var index = 2
      while index < input.len:
        if input[index] != "-I" or index + 1 >= input.len:
          raise newException(ValueError, "usage: foo bind <header.h> [-I include]")
        includes.add(input[index + 1])
        index += 2
      let generated = interopBind.`bind`(input[1],
        interopBind.BindOptions(includePaths: includes))
      echo (if generated.cached: "Using cached" else: "Generated") &
        " bindings: " & generated.bindingPath
      echo "Macro hints: " & generated.hintsPath
      for issue in generated.diagnostics:
        stderr.writeLine(issue.code & ": " & issue.message)
      return 0
    if input[0] == "lsp":
      if input.len != 1: raise newException(ValueError, "usage: foo lsp")
      lspServer.serve()
      return 0

    var args = input
    if args[0] == "watch":
      args = @["build", "--watch"] &
        (if args.len > 1: args[1 .. ^1] else: @[])
    let command = args[0]
    var verbose, jsonOutput, watching, signing, compact: bool
    var warmup = 1
    var iterations = 10
    var target, cpu, backend, filter, mode, provider: string
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
      elif argument == "--json": jsonOutput = true
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
      elif argument == "--backend" or argument.startsWith("--backend="):
        if argument.contains("="): backend = argument[10 .. ^1]
        else:
          inc index
          if index < args.len: backend = args[index]
        if backend notin ["c", "zig"]:
          raise newException(ValueError, "--backend must be c or zig")
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
    proc executeProject() =
      let operation = if command in ["check", "build", "run", "release"]:
          cliDisplay.newOperation(command, jsonOutput, verbose, compact)
        else: nil
      activeOperation = operation
      let projectOptions = buildProject.ProjectOptions(backend: backend,
        target: target, cpu: cpu,
        mode: if command == "release": "release" else: mode,
        progress: if operation != nil: operation.reporter() else: nil)
      let project = buildProject.newProject(root, projectOptions)
      let entry = if positional.len > 0: positional[0] else: ""
      if operation != nil:
        let config = project.config()
        operation.configure(root,
          if backend.len > 0: backend elif config.backend.len > 0:
            config.backend else: "zig",
          if target.len > 0: target elif config.target.len > 0:
            config.target[0] else: buildProject.host,
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
        let products = project.build(entry)
        if products.len != 1:
          raise newException(ValueError,
            "Choose an entry file when a project has multiple executables")
        let artifact = products.values.toSeq[0]
        operation.report("run", "application", "")
        var executable = quoteShell(artifact)
        for argument in passthrough:
          executable.add(" " & quoteShell(argument))
        let response = execCmdEx(executable)
        if response.exitCode == 0:
          operation.report("ran", "application", "")
        else:
          operation.update("Execution", "application", cliDisplay.stateFailed)
        operation.finish(response.exitCode == 0,
          $project.files().len & (if project.files().len == 1: " file" else: " files") &
          " · 0 errors · 0 warnings")
        activeOperation = nil
        if response.output.len > 0: stdout.write(response.output)
        if response.exitCode != 0: raise newException(OSError, response.output)
      of "release":
        if positional.len > 0:
          raise newException(ValueError,
            "usage: foo release [--sign] [--provider name] [--backend c|zig] [--target name]")
        operation.update("Packaging", "release", cliDisplay.stateWorking)
        operation.startWork("Packaging")
        let bundled = buildRelease.bundle(project, signing, provider)
        operation.update("Packaging", "release", cliDisplay.stateComplete,
          bundled.directory, true)
        operation.finishWork("Packaging")
        operation.finish(summary = $bundled.artifacts.len &
          (if bundled.artifacts.len == 1: " artifact" else: " artifacts") &
          (if signing: " signed" else: "") & " · " & bundled.directory)
      of "task":
        for file in project.task(positional): echo file
      else: raise newException(ValueError, usage)
      if operation != nil and not operation.isFinished():
        operation.finish()
      activeOperation = nil
    if command in ["check", "build", "run", "release", "task", "graph", "ir"]:
      if watching:
        if command notin ["check", "build"]:
          raise newException(ValueError, "--watch is available for check and build")
        watch(root, executeProject)
      else: executeProject()
      return 0
    if command == "sign":
      if positional.len != 1:
        raise newException(ValueError,
          "usage: foo sign <artifact> [--provider name] [--target name]")
      activeOperation = cliDisplay.newOperation("SIGN", jsonOutput, verbose, compact)
      activeOperation.plan("Signing", 1, 2.0)
      let project = buildProject.newProject(root)
      let artifact = if isAbsolute(positional[0]): positional[0]
        else: root / positional[0]
      activeOperation.update("Signing", artifact.lastPathPart,
        cliDisplay.stateWorking)
      activeOperation.startWork("Signing")
      let signed = buildRelease.sign(artifact,
        project.manifest().deployment.signing,
        if target.len > 0: buildProject.triple(target) else: "", provider)
      activeOperation.update("Signing", artifact.lastPathPart,
        cliDisplay.stateComplete, signed, true)
      activeOperation.finishWork("Signing")
      activeOperation.finish(summary = signed)
      activeOperation = nil
      return 0
    case command
    of "test":
      if positional.len > 1:
        raise newException(ValueError,
          "usage: foo test [file.iv|directory] [--filter name] [--backend c|zig] [--mode dev|release] [--watch]")
      proc executeTests() =
        activeOperation = cliDisplay.newOperation("TEST", jsonOutput, verbose, compact)
        activeOperation.configure(root,
          if backend.len > 0: backend else: "zig", buildProject.host,
          if mode.len > 0: mode else: "dev")
        let results = test(if positional.len > 0: positional[0] else: root,
          filter, if backend.len > 0: backend else: "zig",
          progress = activeOperation.reporter(), mode = mode)
        var failed = 0
        for item in results:
          if not item.passed: inc failed
          activeOperation.update("Results", item.suite.name,
            if item.passed: cliDisplay.stateComplete else: cliDisplay.stateFailed,
            if item.error.len > 0: item.error else: $item.timeMs & " ms", true)
        let empty = results.len == 0
        activeOperation.finish(failed == 0 and not empty, $results.len &
          (if results.len == 1: " test" else: " tests") &
          " · " & $failed & " failed")
        activeOperation = nil
        if empty:
          raise newException(ValueError,
            "No tests found. Add a test \"description\" { ... } block or select a fixture with start.")
        if failed > 0:
          raise newException(ValueError, "One or more tests failed")
      if watching: watch(root, executeTests) else: executeTests()
    of "benchmark":
      if watching: raise newException(ValueError, "--watch is not available for benchmark")
      if positional.len > 1: raise newException(ValueError,
        "usage: foo benchmark [name|benchmark/file.iv] [--warmup N] [--iterations N] [--backend c|zig] [--mode dev|release]")
      if positional.len == 1:
        if filter.len > 0: raise newException(ValueError, "Choose a benchmark name or --filter, not both")
        filter = positional[0]
      activeOperation = cliDisplay.newOperation("BENCHMARK", jsonOutput, verbose, compact)
      activeOperation.configure(root,
        if backend.len > 0: backend else: "zig", buildProject.host,
        if mode.len > 0: mode else: "project")
      let results = benchmarkRunner.runBenchmarks(root, filter,
        if backend.len > 0: backend else: "zig", warmup, iterations,
        progress = activeOperation.reporter(), mode = mode)
      if results.len == 0: raise newException(ValueError,
        "No benchmarks found in benchmark/" &
        (if filter.len > 0: " matching '" & filter & "'" else: ""))
      var failed = 0
      for item in results:
        if item.error.len > 0:
          inc failed
          activeOperation.update("Results", item.suite.name,
            cliDisplay.stateFailed, item.error, true)
        else:
          let detail = "median " & formatFloat(item.medianMs, ffDecimal, 2) &
            " ms · p95 " & formatFloat(item.percentile95Ms, ffDecimal, 2) &
            " ms · mean " & formatFloat(item.meanMs, ffDecimal, 2) &
            " ms · min " & formatFloat(item.minimumMs, ffDecimal, 2) &
            " ms · max " & formatFloat(item.maximumMs, ffDecimal, 2) & " ms"
          activeOperation.update("Results", item.suite.name,
            cliDisplay.stateComplete, detail, true)
          if jsonOutput:
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
      activeOperation.finish(failed == 0, $results.len &
        (if results.len == 1: " benchmark" else: " benchmarks") &
        " · " & $failed & " failed")
      activeOperation = nil
      if failed > 0: raise newException(ValueError, "One or more benchmarks failed")
    of "fmt":
      discard fmt(if positional.len > 0: positional[0] else: "main.iv")
    else:
      stderr.writeLine(usage)
      return 2
    0
  except buildCompiler.Diagnostics as error:
    if activeOperation != nil and not activeOperation.isFinished():
      activeOperation.finish(false, $error.diagnostics.messages().len & " errors")
    let verbose = "--verbose" in input or "--explain" in input
    let jsonOutput = "--json" in input
    let style = if jsonOutput: "json" elif verbose: "verbose" else: "short"
    stderr.writeLine(renderAll(error.diagnostics.messages(),
      RenderOptions(color: getEnv("NO_COLOR").len == 0 and
        getEnv("TERM") != "dumb", style: style, codes: verbose)))
    1
  except CatchableError as error:
    if activeOperation != nil and not activeOperation.isFinished():
      activeOperation.finish(false, "1 error")
    stderr.writeLine(errorLine(error.msg, "--json" notin input))
    1

when isMainModule:
  quit(main(commandLineParams()))
