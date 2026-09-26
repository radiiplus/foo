import std/[json, os, osproc, sequtils, strutils, tables]
import ../../ir/[kind, node]
import ../../build/options as buildOptions
import ../../build/execute as buildExecute
import ../../opt/arch
import ../../pkg/hash
import ../../toolchain/manager as toolchainManager
import ../substrate
import ../native/[escape, service]
import ./emitter
import ./shim as zigShim

type
  Result* = object
    success*: bool
    artifact*: string
    output*: string
    error*: string
    cached*: bool

const
  runtimeLibrary = staticRead("library.zig")
  runtimeStorage = staticRead("storage.zig")
  runtimeStream = staticRead("stream.zig")
  runtimeService = staticRead("service.zig")
  serviceHeader = staticRead("../native/service.h")
  serviceSource = staticRead("../native/service.c")

proc sharedCacheDirectory*(): string =
  let configured = getEnv("ZIG_GLOBAL_CACHE_DIR")
  if configured.len > 0: absolutePath(configured)
  else: getHomeDir() / ".foo" / "cache" / "zig" / toolchainManager.version

proc stageEmbeds(module: Module; sourceFile, outDir: string) =
  let sourceDir = parentDir(absolutePath(sourceFile))
  proc stageInstruction(instruction: Instruction)
  proc stageBlock(basicBlock: Block) =
    if basicBlock == nil: return
    for instruction in basicBlock.instrs: stageInstruction(instruction)
    stageInstruction(basicBlock.term)
  proc stageInstruction(instruction: Instruction) =
    if instruction == nil: return
    if instruction.kind == InstrKind.Embed and instruction.path.len > 0:
      let data = readFile(sourceDir / instruction.path)
      let relative = "assets" / (sha256Hex(data) & ".bin")
      let target = outDir / relative
      createDir(parentDir(target))
      writeFile(target, data)
      instruction.path = relative.replace('\\', '/')
    if instruction.fallback != nil: stageBlock(instruction.fallback)
  for fn in module.funcs:
    for basicBlock in fn.blocks: stageBlock(basicBlock)

proc build*(module: Module; mode: string; outDir: string; zigPath = "zig";
    sourceFile = "foo_source.iv"; options = buildOptions.Native();
    progress: buildOptions.BuildProgress = nil): Result =
  try:
    buildOptions.validate(options)
    createDir(outDir)
    let selection = Selection(backend: "zig", target: options.target, cpu: options.cpu,
      level: options.level, mode: mode, substrate: options.substrate,
      native: substrate.NativeSelection(substrate: options.native.substrate,
        clobbers: options.native.clobbers))
    let escaped = escape(module, selection)
    stageEmbeds(escaped.module, sourceFile, outDir)
    let generated = emit(escaped.module, mode, EmitOptions(
      library: options.kind in ["static", "shared"], runtime: options.runtime,
      coverage: options.coverage, target: options.target))
    let mainPath = outDir / "main.zig"
    writeFile(mainPath, generated.code)
    writeFile(outDir / "shim.zig", zigShim.`shim`)
    writeFile(outDir / "library.zig", runtimeLibrary)
    let copy = select("copy", selection)
    let transferBlock = case copy.implementation
      of "block-32": "32"
      of "block-16": "16"
      else: "@sizeOf(usize)"
    writeFile(outDir / "storage.zig",
      runtimeStorage.replace("FOO_TRANSFER_BLOCK", transferBlock))
    writeFile(outDir / "stream.zig", runtimeStream)
    writeFile(outDir / "service.zig", runtimeService)
    var mappings = newJArray()
    for sourceLine, generatedLine in generated.map:
      mappings.add(%*{"source": sourceLine, "generated": generatedLine})
    writeFile(outDir / "source.json", pretty(%*{
      "source": sourceFile, "mappings": mappings}) & "\n")
    var fragment = ""
    if escaped.code.len > 0:
      fragment = outDir / "escape.c"
      writeFile(fragment, escaped.code)
    let needsService = hosted(escaped.module, includeIo = false)
    if needsService:
      writeFile(outDir / "service.h", serviceHeader)
      writeFile(outDir / "service.c", serviceSource)
    let artifactPath = outDir / buildOptions.artifact(options)
    if options.compile:
      let cache = sharedCacheDirectory()
      createDir(cache)
      let llvmRequired = fragment.len > 0 or needsService or
        options.sources.len > 0 or options.sanitize.len > 0 or
        options.exports.len > 0 or options.script.len > 0
      let intensive = llvmRequired or mode == "release"
      let jobs = if options.jobs > 0: options.jobs else: buildOptions.jobLimit(intensive)
      if progress != nil:
        var path = if intensive: "Compatibility path" else: "Fast path"
        if mode == "release": path = "Optimized path"
        elif fragment.len > 0: path.add(" (native interop)")
        elif needsService: path.add(" (system services)")
        elif options.sources.len > 0: path.add(" (native sources)")
        elif options.sanitize.len > 0: path.add(" (safety checks)")
        elif options.exports.len > 0 or options.script.len > 0:
          path.add(" (custom linking)")
        progress("path", options.name,
          path & " | " & $jobs & (if jobs == 1: " job" else: " jobs") &
          " | shared cache enabled", false)
      var command = quoteShell(zigPath) &
        (if options.kind in ["static", "shared"]: " build-lib " else: " build-exe ") &
        quoteShell(mainPath) & " -O " &
        (if mode == "release": "ReleaseSafe" else: "Debug") &
        " --cache-dir " & quoteShell(outDir / "cache") &
        " --global-cache-dir " & quoteShell(cache) &
        " -j" & $jobs &
        " -femit-bin=" & quoteShell(artifactPath)
      if options.name.len > 0: command.add(" --name " & quoteShell(options.name))
      if options.exports.len > 0 or options.script.len > 0:
        command.add(" -flld -fllvm")
      if options.kind == "shared": command.add(" -dynamic")
      if options.soname.len > 0:
        command.add(" -fsoname=" & quoteShell(options.soname))
      if options.version.len > 0:
        command.add(" --version " & quoteShell(options.version))
      if options.exports.len > 0:
        command.add(" --version-script " & quoteShell(options.exports))
      if options.script.len > 0:
        command.add(" --script " & quoteShell(options.script))
      if mode != "release" and not llvmRequired:
        command.add(" -fno-llvm")
      for path in options.rpath: command.add(" -rpath " & quoteShell(path))
      for framework in options.frameworks:
        command.add(" -framework " & quoteShell(framework))
      for path in options.objects: command.add(" " & quoteShell(path))
      if options.target.len > 0:
        command.add(" -target " & quoteShell(options.target))
      if fragment.len > 0:
        command.add(" " & quoteShell(fragment) & " -lc")
      if options.target.contains("freestanding"): command.add(" -fno-entry")
      if options.threads:
        command.add(" -mcpu generic+atomics+bulk_memory --shared-memory")
      elif options.cpu.len > 0:
        command.add(" -mcpu " & quoteShell(profile(options.target, options.cpu).zig))
      if options.debug: command.add(" -fno-strip")
      if options.sanitize == "c": command.add(" -fsanitize-c=full")
      elif options.sanitize == "thread": command.add(" -fsanitize-thread")
      if options.docs:
        command.add(" -femit-docs=" & quoteShell(outDir / "docs"))
      for path in options.includePaths:
        command.add(" -I " & quoteShell(path))
      if needsService:
        command.add(" -I " & quoteShell(outDir) & " " &
          quoteShell(outDir / "service.c") & " -lc")
        for library in libraries(options.target):
          command.add(" -l" & quoteShell(library))
      if options.flags.len > 0 and options.sources.len > 0:
        command.add(" -cflags " &
          options.flags.mapIt(quoteShell(it)).join(" ") & " --")
      for path in options.sources: command.add(" " & quoteShell(path))
      for library in options.libs:
        command.add(if fileExists(library): " " & quoteShell(library)
          else: " -l" & quoteShell(library))
      if options.cpp: command.add(" -lc++")
      let process = buildExecute.runCommand(command, outDir / ".compile-output",
        options.name, progress)
      if process.exitCode != 0: raise newException(OSError, process.output)
    result.success = true
    result.artifact = artifactPath
    result.cached = false
    if options.compile and options.run and
        (options.kind.len == 0 or options.kind == "exe"):
      let executed = execCmdEx(quoteShell(artifactPath))
      result.output = executed.output
      if executed.exitCode != 0: raise newException(OSError, executed.output)
  except CatchableError as error:
    result.success = false
    result.error = error.msg
