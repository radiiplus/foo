import std/[os, osproc, sequtils, sets, strutils]
import ../../ir/node
import ../../build/options
import ../../build/execute as buildExecute
import ../../opt/arch
import ../substrate
import ../native/[escape, service]
import ./emitter

type Result* = object
  success*: bool
  artifact*: string
  output*: string
  error*: string
  cached*: bool

const
  serviceHeader = staticRead("../native/service.h")
  serviceSource = staticRead("../native/service.c")

proc dependencies*(text: string): seq[string] =
  var body = text.replace("\\\r\n", " ").replace("\\\n", " ")
  let colon = body.find(':')
  if colon >= 0: body = body[colon + 1 .. ^1]
  for word in body.splitWhitespace:
    let value = word.replace("\\ ", " ").replace("\\#", "#").replace("\\\\", "\\")
    if value.len > 0: result.add(absolutePath(value))

proc compilerPath(options: Native): string =
  if options.compiler.len > 0: return options.compiler
  let configured = getEnv("CC")
  if configured.len > 0: return configured
  when defined(windows): "clang" else: "cc"

proc build*(module: Module; mode: string; outDir: string;
    options = Native(); sourceFile = "main.iv";
    progress: BuildProgress = nil): Result =
  try:
    validate(options)
    if options.runtime == "none":
      raise newException(ValueError, "The C backend currently requires a hosted C11 runtime")
    if options.docs or options.threads:
      raise newException(ValueError, "C backend does not yet support docs or WASI threads")
    createDir(outDir)
    let selection = Selection(backend: "c", target: options.target, cpu: options.cpu,
      level: options.level, mode: mode, substrate: options.substrate,
      native: substrate.NativeSelection(substrate: options.native.substrate,
        clobbers: options.native.clobbers))
    let escaped = escape(module, selection)
    let generated = emit(escaped.module, mode, Options(target: options.target,
      cpu: options.cpu, level: options.level, substrate: options.substrate,
      source: sourceFile, runtime: options.runtime, coverage: options.coverage,
      library: options.kind in ["static", "shared"]))
    let mainPath = outDir / "main.c"
    writeFile(mainPath, generated.code)
    var inputs = @[mainPath]
    if escaped.code.len > 0:
      let escapePath = outDir / "escape.c"
      writeFile(escapePath, escaped.code)
      inputs.add(escapePath)
    let needsService = hosted(escaped.module)
    if needsService:
      writeFile(outDir / "service.h", serviceHeader)
      let servicePath = outDir / "service.c"
      writeFile(servicePath, serviceSource)
      inputs.add(servicePath)
    inputs.add(options.sources)
    let artifactPath = outDir / artifact(options)
    if options.compile:
      let compiler = compilerPath(options)
      var common = @["-std=c11", "-D_POSIX_C_SOURCE=200809L",
        (if mode == "release": "-O2" else: "-O0"), "-g"]
      if options.kind == "shared": common.add("-fPIC")
      if options.target.len > 0 and options.compiler.len == 0:
        common.add(@["-target", options.target])
      if options.cpu.len > 0:
        common.add(profile(options.target, options.cpu).c)
      if options.target.contains("macos") or options.target.contains("darwin"):
        common.add("-D_DARWIN_C_SOURCE")
      if options.sanitize.len > 0:
        common.add(if options.sanitize == "c":
          "-fsanitize=undefined" else: "-fsanitize=thread")
      if needsService: common.add(@["-I", outDir])
      for path in options.includePaths: common.add(@["-I", path])
      proc addLinkOptions(command: var string) =
        if options.target.len > 0 and options.compiler.len == 0:
          command.add(" -target " & quoteShell(options.target))
        if options.kind == "shared": command.add(" -shared")
        if options.soname.len > 0:
          command.add(" -Xlinker -soname -Xlinker " & quoteShell(options.soname))
        elif options.version.len > 0 and
            (options.target.len == 0 or options.target.contains("linux")):
          command.add(" -Xlinker -soname -Xlinker " &
            quoteShell("lib" & (if options.name.len > 0: options.name else: "app") &
              ".so." & options.version.split('.')[0]))
        if options.exports.len > 0:
          command.add(" -Xlinker --version-script -Xlinker " & quoteShell(options.exports))
        if options.script.len > 0: command.add(" -T " & quoteShell(options.script))
        for path in options.rpath:
          command.add(" -Xlinker -rpath -Xlinker " & quoteShell(path))
        for framework in options.frameworks:
          command.add(" -framework " & quoteShell(framework))
        var linkedLibraries = initHashSet[string]()
        for library in generated.libraries & options.libs:
          if library in linkedLibraries: continue
          linkedLibraries.incl(library)
          command.add(if fileExists(library): " " & quoteShell(library)
            else: " -l" & quoteShell(library))
        if needsService:
          for library in libraries(options.target):
            if library notin linkedLibraries:
              linkedLibraries.incl(library)
              command.add(" -l" & quoteShell(library))
        if options.cpp:
          command.add(if options.compiler.len > 0: " -lstdc++" else: " -lc++")
        if options.sanitize.len > 0:
          command.add(if options.sanitize == "c":
            " -fsanitize=undefined" else: " -fsanitize=thread")

      let fastPath = options.kind != "static" and escaped.code.len == 0 and
        options.sources.len == 0 and options.objects.len == 0 and
        options.flags.len == 0 and not options.cpp and options.sanitize.len == 0 and
        options.exports.len == 0 and options.script.len == 0 and
        options.rpath.len == 0 and options.frameworks.len == 0
      let jobs = if options.jobs > 0: options.jobs else: jobLimit(not fastPath or mode == "release")
      let activeJobs = if fastPath: 1 else: min(jobs, max(1, inputs.len))
      if progress != nil:
        var path = if fastPath: "Fast path" else: "Compatibility path"
        if mode == "release": path = "Optimized path"
        elif not fastPath:
          if escaped.code.len > 0: path.add(" (native interop)")
          elif options.sources.len > 0: path.add(" (native sources)")
          elif options.objects.len > 0: path.add(" (native objects)")
          elif options.kind == "static": path.add(" (static library)")
          elif options.sanitize.len > 0: path.add(" (safety checks)")
          else: path.add(" (custom linking)")
        progress("path", options.name,
          path & " | " & $activeJobs &
          (if activeJobs == 1: " job" else: " jobs") &
          " | project cache checked", false)

      if fastPath:
        var command = quoteShell(compiler)
        for argument in common: command.add(" " & quoteShell(argument))
        for input in inputs: command.add(" " & quoteShell(absolutePath(input)))
        addLinkOptions(command)
        command.add(" -o " & quoteShell(artifactPath))
        let compiled = buildExecute.runCommand(command, outDir / ".compile-output",
          options.name, progress)
        if compiled.exitCode != 0: raise newException(OSError, compiled.output)
      else:
        var objects: seq[string]
        var commands: seq[string]
        for index, input in inputs:
          let sourcePath = absolutePath(input)
          let objectPath = outDir / ($index & ".o")
          let cpp = sourcePath.toLowerAscii.endsWith(".cc") or
            sourcePath.toLowerAscii.endsWith(".cpp") or
            sourcePath.toLowerAscii.endsWith(".cxx")
          var arguments = common
          if cpp:
            arguments = arguments.filterIt(it != "-std=c11")
            arguments.add("-std=c++17")
          if index > 0: arguments.add(options.flags)
          var command = quoteShell(compiler)
          for argument in arguments: command.add(" " & quoteShell(argument))
          command.add(" -c " & quoteShell(sourcePath) & " -o " & quoteShell(objectPath))
          commands.add(command)
          objects.add(objectPath)
        let compiled = buildExecute.runCommands(commands, outDir / ".compile-output",
          options.name, activeJobs, progress)
        if compiled.exitCode != 0: raise newException(OSError, compiled.output)
        objects.add(options.objects)
        if progress != nil:
          progress("link", options.name,
            if options.kind == "static": "static library" else: "application", false)
        if options.kind == "static":
          let archiver = when defined(windows): "llvm-ar" else: "ar"
          var command = quoteShell(archiver) & " rcs " & quoteShell(artifactPath)
          for objectPath in objects: command.add(" " & quoteShell(objectPath))
          let archived = buildExecute.runCommand(command, outDir / ".archive-output",
            options.name, progress)
          if archived.exitCode != 0: raise newException(OSError, archived.output)
        else:
          var command = quoteShell(compiler)
          for objectPath in objects: command.add(" " & quoteShell(objectPath))
          addLinkOptions(command)
          command.add(" -o " & quoteShell(artifactPath))
          let linked = buildExecute.runCommand(command, outDir / ".link-output",
            options.name, progress)
          if linked.exitCode != 0: raise newException(OSError, linked.output)
        if progress != nil:
          progress("linked", options.name,
            if options.kind == "static": "static library" else: "application", false)
    result.success = true
    result.artifact = artifactPath
    result.cached = false
    if options.compile and options.run and
        (options.kind.len == 0 or options.kind == "exe"):
      let executed = execCmdEx(quoteShell(artifactPath))
      result.output = executed.output
      if executed.exitCode != 0:
        raise newException(OSError, executed.output)
  except CatchableError as error:
    result.success = false
    result.error = error.msg
