import std/[os, osproc, sequtils, sets, strutils]
import ../../ir/node
import ../../ir/reach
import ../../build/options
import ../../build/execute as buildExecute
import ../../opt/arch
import ../docs as backendDocs
import ../substrate
import ../native/[escape, icon, service]
import ../../toolchain/native
import ../../toolchain/manager
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

proc diagnose*(output: string; libs: openArray[string]): string =
  let lower = output.toLowerAscii()
  let rules = [
    ("sodium", "sodium.h", "C crypto requires libsodium development files. Install libsodium-dev on Debian/Ubuntu, or provide its include and library paths."),
    ("z", "zlib.h", "C compression requires zlib development files. Install zlib1g-dev on Debian/Ubuntu, or provide its include and library paths."),
    ("curl", "curl/curl.h", "C HTTP requires libcurl development files. Install libcurl4-openssl-dev on Debian/Ubuntu, or provide its include and library paths.")
  ]
  for rule in rules:
    if rule[0] notin libs: continue
    let header = lower.contains(rule[1]) and
      (lower.contains("no such file") or lower.contains("file not found"))
    let linker = lower.contains("-l" & rule[0]) and
      (lower.contains("cannot find") or lower.contains("unable to find") or
        lower.contains("library not found"))
    if header or linker: return rule[2] & "\n" & output
  output

proc compilerPath(options: Native): string =
  if options.compiler.len > 0: return options.compiler
  let configured = getEnv("CC")
  if configured.len > 0: return configured
  when defined(windows):
    if findExe("clang").len > 0: return "clang"
  else:
    if findExe("cc").len > 0: return "cc"
  let backend = detect()
  if backend.path.len > 0: return backend.path
  when defined(windows): "clang" else: "cc"

proc compilerCommand(path: string): string =
  result = quoteShell(path)
  let executable = splitFile(path).name.toLowerAscii()
  if executable == "zig": result.add(" cc")

proc managed(path: string): bool =
  splitFile(path).name.toLowerAscii() == "zig"

proc deadStripFlag*(target, compiler: string): string =
  if target.contains("macos") or target.contains("darwin"):
    return "-Wl,-dead_strip"
  let windows = if target.len > 0:
      target.contains("windows") or target.contains("win32")
    else: defined(windows)
  let executable = splitFile(compiler).name.toLowerAscii()
  let gnuCompiler = executable.endsWith("gcc") or
    executable.endsWith("g++")
  if windows and (target.contains("msvc") or
      (not target.contains("gnu") and not managed(compiler) and
        not gnuCompiler)):
    return "-fuse-ld=lld -Wl,/OPT:REF,/OPT:ICF,/INCREMENTAL:NO"
  "-Wl,--gc-sections"

proc local(target: string): bool =
  if target.len == 0: return true
  let value = target.toLowerAscii()
  let platform = when defined(windows): value.contains("windows")
    elif defined(macosx): value.contains("macos") or value.contains("darwin")
    else: value.contains("linux")
  let architecture = when defined(arm64):
      value.contains("aarch64") or value.contains("arm64")
    elif defined(amd64):
      value.contains("x86_64") or value.contains("amd64")
    else: true
  platform and architecture

proc build*(module: Module; mode: string; outDir: string;
    options = Native(); sourceFile = "main.iv";
    progress: BuildProgress = nil): Result =
  try:
    validate(options)
    createDir(outDir)
    let selection = Selection(backend: "c", target: options.target, cpu: options.cpu,
      level: options.level, mode: mode, substrate: options.substrate,
      native: substrate.NativeSelection(substrate: options.native.substrate,
        clobbers: options.native.clobbers))
    let selected = reach(module, options.kind in ["static", "shared"])
    let escaped = escape(selected, selection)
    if progress != nil:
      if selected.funcs.len != module.funcs.len or
          selected.externs.len != module.externs.len:
        progress("strategy", "program",
          "reachability / " & $selected.funcs.len & " of " &
          $module.funcs.len & " functions | " & $selected.externs.len &
          " of " & $module.externs.len & " imports", false)
      for decision in escaped.decisions:
        progress("strategy", decision.operation,
          decision.stage & " / " & decision.implementation & " | " & decision.reason,
          false)
    let generated = emit(escaped.module, mode, Options(target: options.target,
      cpu: options.cpu, level: options.level, substrate: options.substrate,
      source: sourceFile, runtime: options.runtime, coverage: options.coverage,
      library: options.kind in ["static", "shared"], benchmark: options.benchmark))
    if options.docs: backendDocs.generate(escaped.module, outDir)
    let mainPath = outDir / "main.c"
    writeFile(mainPath, generated.code)
    var inputs = @[mainPath]
    if escaped.code.len > 0:
      let escapePath = outDir / "escape.c"
      writeFile(escapePath, escaped.code)
      inputs.add(escapePath)
    let needsService = options.runtime != "none" and hosted(escaped.module)
    if needsService:
      writeFile(outDir / "service.h", serviceHeader)
      let servicePath = outDir / "service.c"
      writeFile(servicePath, serviceSource)
      inputs.add(servicePath)
    else:
      for path in [outDir / "service.h", outDir / "service.c"]:
        if fileExists(path): removeFile(path)
    inputs.add(options.sources)
    let artifactPath = outDir / artifact(options)
    if options.compile:
      let iconObject = icon.compile(
        icon.script(options.icon, outDir, options.target, options.kind),
        outDir, options.name, progress)
      let compiler = compilerPath(options)
      let supply = native.prepare(generated.libraries, options.includePaths,
        compiler, options.target, progress)
      var common = @["-std=c11", "-D_POSIX_C_SOURCE=200809L",
        (if mode == "release": "-O2" else: "-O0"),
        (if mode == "release": "-g0" else: "-g"),
        "-ffunction-sections", "-fdata-sections"]
      if options.runtime == "none":
        common.add(@["-ffreestanding", "-fno-stack-protector"])
      if options.threads:
        common.add(@["-matomics", "-mbulk-memory", "-pthread"])
      if options.kind == "shared" and not options.target.contains("windows"):
        common.add("-fPIC")
      if options.target.len > 0 and (options.compiler.len == 0 or managed(compiler)) and
          not local(options.target):
        common.add(@["-target", options.target])
      if options.cpu.len > 0:
        common.add(profile(options.target, options.cpu).c)
      if options.target.contains("macos") or options.target.contains("darwin"):
        common.add("-D_DARWIN_C_SOURCE")
      if options.sanitize.len > 0:
        common.add(if options.sanitize == "c":
          "-fsanitize=undefined" else: "-fsanitize=thread")
      if needsService: common.add(@["-I", outDir])
      for path in supply.headers: common.add(@["-I", path])
      if needsService and selective(options, escaped.code.len > 0):
        common.add(resourceDefines(escaped.module))
      for path in options.includePaths: common.add(@["-I", path])
      proc addLinkOptions(command: var string) =
        if options.target.len > 0 and (options.compiler.len == 0 or managed(compiler)) and
            not local(options.target):
          command.add(" -target " & quoteShell(options.target))
        if options.kind == "shared": command.add(" -shared")
        if options.kind != "static":
          let stripping = deadStripFlag(options.target, compiler)
          command.add(" " & stripping)
          if mode == "release":
            command.add(if "/OPT:REF" in stripping:
              " -Wl,/DEBUG:NONE" else: " -s")
        if options.runtime == "none":
          command.add(" -nostdlib -Wl,-e,_start")
        if options.threads:
          command.add(" -Wl,--shared-memory -pthread")
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
          var selected = library
          for link in supply.links:
            if link.name == library: selected = link.path
          command.add(if fileExists(selected): " " & quoteShell(selected)
            else: " -l" & quoteShell(selected))
        if supply.runtime.len > 0 and options.kind != "static":
          command.add(" -Wl,-rpath," & quoteShell("$ORIGIN"))
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
        iconObject.len == 0 and
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

      if mode == "release":
        for path in [changeFileExt(artifactPath, ".pdb"),
            changeFileExt(artifactPath, ".ilk")]:
          if fileExists(path): removeFile(path)
      if fastPath:
        var command = compilerCommand(compiler)
        for argument in common: command.add(" " & quoteShell(argument))
        for input in inputs: command.add(" " & quoteShell(absolutePath(input)))
        addLinkOptions(command)
        command.add(" -o " & quoteShell(artifactPath))
        let compiled = buildExecute.runCommand(command, outDir / ".compile-output",
          options.name, progress)
        if compiled.exitCode != 0:
          raise newException(OSError, diagnose(compiled.output, generated.libraries))
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
          var command = compilerCommand(compiler)
          for argument in arguments: command.add(" " & quoteShell(argument))
          command.add(" -c " & quoteShell(sourcePath) & " -o " & quoteShell(objectPath))
          commands.add(command)
          objects.add(objectPath)
        let compiled = buildExecute.runCommands(commands, outDir / ".compile-output",
          options.name, activeJobs, progress)
        if compiled.exitCode != 0:
          raise newException(OSError, diagnose(compiled.output, generated.libraries))
        objects.add(options.objects)
        if iconObject.len > 0: objects.add(iconObject)
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
          var command = compilerCommand(compiler)
          for objectPath in objects: command.add(" " & quoteShell(objectPath))
          addLinkOptions(command)
          command.add(" -o " & quoteShell(artifactPath))
          let linked = buildExecute.runCommand(command, outDir / ".link-output",
            options.name, progress)
          if linked.exitCode != 0:
            raise newException(OSError, diagnose(linked.output, generated.libraries))
        if progress != nil:
          progress("linked", options.name,
            if options.kind == "static": "static library" else: "application", false)
      let shared = outDir / "libcurl.so.4"
      if (options.kind == "static" or supply.runtime.len == 0) and
          fileExists(shared): removeFile(shared)
      if options.kind != "static":
        for path in supply.runtime:
          copyFile(path, outDir / path.lastPathPart)
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
