import std/[json, os, osproc, sequtils, strutils, tables]
import ./[project as cliProject, runner]
import ../ir/print
import ../build/project as buildProject
import ../build/compiler as buildCompiler
import ../diag/render
import ../diag/engine
import ../toolchain/manager as toolchainManager
import ../toolchain/doctor as toolchainDoctor
import ../pkg/[hash, registry as packageRegistry, vendor as packageVendor]
import "../interop/bind.nim" as interopBind
import ../lsp/server as lspServer

const usage = "usage: foo <new|check|build|run|watch|graph|ir|test|fmt|doc|add|remove|install|toolchain|clean|doctor|version|task|lsp|bind|cc|publish|audit|mirror> [file] [--backend zig|c] [--target target] [-mcpu profile] [--watch]"
const packageText = staticRead("../../package.json")
const projectText = staticRead("../../project.json")

proc productVersion(): string =
  let package = parseJson(packageText)
  let project = parseJson(projectText)
  "FOO IV\ncompiler " & package.getOrDefault("version").getStr() &
    "\nlanguage " & project.getOrDefault("language").getStr()

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

proc progress(jsonOutput, verbose: bool):
    proc(phase, name, file: string; cached: bool) {.closure.} =
  result = proc(phase, name, file: string; cached: bool) =
    if jsonOutput:
      echo $(%*{"event": phase, "name": name, "file": file, "cached": cached})
    elif verbose:
      stderr.writeLine(phase.toUpperAscii & " " & name &
        (if file.len > 0: " " & file else: ""))

proc main*(input: seq[string]): int =
  if input.len == 0:
    stderr.writeLine(usage)
    return 2
  try:
    if input.len == 1 and input[0] in ["version", "--version"]:
      echo productVersion()
      return 0
    if input[0] == "doc":
      if input.len > 2: raise newException(ValueError, "usage: foo doc [file.iv|library]")
      stdout.write(doc(if input.len > 1: input[1] else: ""))
      return 0
    if input[0] == "toolchain":
      if input.len == 1:
        let found = toolchainManager.detect()
        echo if found.path.len > 0: "Installed capability: base"
          else: "Installed capability: none"
      elif input.len == 3 and input[1] == "install" and
          input[2] in toolchainManager.levels:
        discard toolchainManager.install()
        toolchainManager.ensure(input[2])
        echo "FOO " & input[2] & " toolchain is ready."
      else:
        raise newException(ValueError,
          "usage: foo toolchain [install base|system|machine|hardware]")
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
      if input.len != 2: raise newException(ValueError, "usage: foo new <directory>")
      discard cliProject.create(input[1])
      return 0
    if input[0] == "clean":
      if input.len != 1: raise newException(ValueError, "usage: foo clean")
      cliProject.clean()
      return 0
    if input[0] in ["add", "remove"]:
      let expected = if input[0] == "add": 3 else: 2
      if input.len != expected:
        raise newException(ValueError, "usage: foo " & input[0] & " <name>" &
          (if input[0] == "add": " <source>" else: ""))
      cliProject.dependency(input[0], input[1],
        if input.len > 2: input[2] else: "")
      return 0
    if input[0] in ["publish", "install", "audit", "mirror"]:
      let root = getCurrentDir()
      case input[0]
      of "publish":
        if input.len != 3 or input[1] != "--key":
          raise newException(ValueError,
            "usage: foo publish --key <private.pem> (FOO_TOKEN supplies staging authentication)")
        echo "Published " & packageRegistry.publish(root, input[2],
          getEnv("FOO_TOKEN")) & "."
      of "mirror":
        if input.len != 2:
          raise newException(ValueError, "usage: foo mirror <directory>")
        echo "Mirrored " & $packageRegistry.mirror(root, input[1]) & " packages."
      of "audit":
        if input.len != 1: raise newException(ValueError, "usage: foo audit")
        echo "Verified " & $packageRegistry.audit(root) & " signed packages."
      of "install":
        if input.len != 1: raise newException(ValueError, "usage: foo install")
        let manifestPath = root / "project.json"
        var registrySources = false
        var dependencies = 0
        if fileExists(manifestPath):
          let manifest = parseJson(readFile(manifestPath))
          for _, source in manifest.getOrDefault("dependencies"):
            inc dependencies
            if source.getStr().startsWith("registry+"): registrySources = true
        if registrySources:
          echo "Installed " & $packageRegistry.install(root).len & " signed packages."
        elif dependencies > 0:
          packageVendor.vendor(root)
          echo "Dependencies installed."
        else:
          discard toolchainManager.install()
          echo "FOO toolchain is ready."
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
    var verbose, jsonOutput, watching: bool
    var target, cpu, backend, filter: string
    var positional: seq[string]
    var index = 1
    while index < args.len:
      let argument = args[index]
      if argument == "--verbose": verbose = true
      elif argument == "--json": jsonOutput = true
      elif argument == "--watch": watching = true
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
      elif argument == "--filter" and command == "test":
        inc index
        if index < args.len: filter = args[index]
        if filter.len == 0:
          raise newException(ValueError, "--filter needs a test name")
      elif argument.startsWith("-"):
        raise newException(ValueError, "unknown option: " & argument)
      else: positional.add(argument)
      inc index

    let root = getCurrentDir()
    let projectOptions = buildProject.ProjectOptions(backend: backend,
      target: target, cpu: cpu, progress: progress(jsonOutput, verbose))
    proc executeProject() =
      let project = buildProject.newProject(root, projectOptions)
      let entry = if positional.len > 0: positional[0] else: ""
      case command
      of "graph": echo pretty(project.graph())
      of "ir":
        if entry.len == 0: raise newException(ValueError, "usage: foo ir <file>")
        echo encode(project.ir(entry))
      of "check":
        project.check(entry)
        if not jsonOutput: echo "Check passed."
      of "build": discard project.build(entry)
      of "run":
        let products = project.build(entry)
        if products.len != 1:
          raise newException(ValueError,
            "Choose an entry file when a project has multiple executables")
        let artifact = products.values.toSeq[0]
        let response = execCmdEx(quoteShell(artifact))
        if response.output.len > 0: stdout.write(response.output)
        if response.exitCode != 0: raise newException(OSError, response.output)
      of "task":
        for file in project.task(positional): echo file
      else: raise newException(ValueError, usage)
    if command in ["check", "build", "run", "task", "graph", "ir"]:
      if watching:
        if command notin ["check", "build"]:
          raise newException(ValueError, "--watch is available for check and build")
        watch(root, executeProject)
      else: executeProject()
      return 0
    case command
    of "test":
      proc executeTests() =
        let results = test(if positional.len > 0: positional[0] else: root,
          filter, if backend.len > 0: backend else: "zig")
        for item in results:
          echo (if item.passed: "PASS " else: "FAIL ") & item.suite.name &
            " (" & item.suite.file & ")"
          if item.error.len > 0: stderr.writeLine(item.error)
        if results.anyIt(not it.passed):
          raise newException(ValueError, "One or more tests failed")
      if watching: watch(root, executeTests) else: executeTests()
    of "fmt":
      discard fmt(if positional.len > 0: positional[0] else: "main.iv")
    else:
      stderr.writeLine(usage)
      return 2
    0
  except buildCompiler.Diagnostics as error:
    let verbose = "--verbose" in input
    let jsonOutput = "--json" in input
    let style = if jsonOutput: "json" elif verbose: "verbose" else: "short"
    stderr.writeLine(renderAll(error.diagnostics.messages(),
      RenderOptions(color: getEnv("NO_COLOR").len == 0 and
        getEnv("TERM") != "dumb", style: style, codes: verbose)))
    1
  except CatchableError as error:
    stderr.writeLine(error.msg)
    1

when isMainModule:
  quit(main(commandLineParams()))
