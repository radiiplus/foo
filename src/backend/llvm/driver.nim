import std/[json, os, osproc, strutils, sequtils]
import ../../build/options
import ../../build/execute as execute
import ../../ir/node
import ../../ir/reach
import ../../ir/monomorph
import ../../ir/valid as irValid
import ../../ir/print as irPrint
import ../../opt/arch as targetArch
import ../native/service
import ../native/escape as nativeEscape
import ../substrate
import ../../toolchain/native as nativeSupply
import ./emitter
import ./runtime
import ./abi
import ./effects

const
  serviceHeader = staticRead("../native/service.h")
  serviceSource = staticRead("../native/service.c")
  vulkanSource = staticRead("../native/vulkan.c")
  gpuSource = staticRead("../native/gpu.c")

proc bundled(relative, marker: string): string =
  var directory = getAppDir()
  for depth in 0..4:
    let candidate = directory / "vendor" / relative
    if fileExists(candidate / marker): return candidate
    directory = parentDir(directory)
  raise newException(IOError, "LLVM runtime needs vendor/" & relative & "/" & marker & "; build from a complete checkout")

type Result* = object
  success*, cached*: bool
  artifact*, output*, error*: string

proc clangPath(options: Native): string =
  if options.compiler.len > 0: options.compiler
  elif getEnv("FOO_LLVM_CLANG").len > 0: getEnv("FOO_LLVM_CLANG")
  else: "clang"

proc query(command: string): string =
  let response = execCmdEx(command)
  if response.exitCode != 0:
    raise newException(IOError, "LLVM tool failed: " & command & "\n" & response.output &
      "\nInstall LLVM Clang and LLD; set FOO_LLVM_CLANG to clang's path.")
  response.output.strip()

proc identity*(mode: string; options: Native): string =
  ## Query the selected tools before the project cache lookup.
  if getEnv("FOO_IO_BATCHING", "off") != "off":
    raise newException(ValueError, "LLVM I/O batching is not qualified; use --no-batching or FOO_IO_BATCHING=off")
  let clang = quoteShell(clangPath(options))
  let version = query(clang & " --version")
  let triple = query(clang & " -dumpmachine")
  let profile = targetArch.profile(triple, options.cpu)
  if profile.cpu != "x86-64": raise newException(ValueError, "LLVM CPU execution is qualified only for x86-64 baseline; selected " & profile.cpu)
  let windows = triple == "x86_64-pc-windows-msvc"
  let linux = triple in ["x86_64-pc-linux-gnu", "x86_64-unknown-linux-gnu"]
  if not windows and not linux:
    raise newException(ValueError, "LLVM host is qualified only for Windows/Linux x64; selected " & triple)
  let targetAlias = if windows: "x86_64-windows-msvc" else: "x86_64-linux-gnu"
  if options.target.len > 0 and options.target notin [triple, targetAlias]:
    raise newException(ValueError, "LLVM does not support cross targets: " & options.target)
  let linker = query(quoteShell(parentDir(findExe(clangPath(options))) / (if windows: "lld-link.exe" else: "ld.lld")) & " --version")
  let legacyVerifier = version.contains("clang version 14.")
  let verifier = if legacyVerifier: query(quoteShell(parentDir(findExe(clangPath(options))) / "opt") & " --version") else: "Clang LLVM verifier"
  let probe = execCmdEx(clang & " -x c - -S -emit-llvm -o -", input = "int foo_layout_probe;\n")
  if probe.exitCode != 0: raise newException(IOError, "LLVM target layout probe failed: " & probe.output)
  var effectiveTriple, layout: string
  for line in probe.output.splitLines():
    if line.startsWith("target triple = "): effectiveTriple = line.split('"')[1]
    elif line.startsWith("target datalayout = "): layout = line.split('"')[1]
  if layout.len == 0 or effectiveTriple.len == 0:
    raise newException(IOError, "LLVM did not report its effective target triple and data layout")
  $(%*{"backend": "llvm", "clang": clangPath(options), "version": version,
    "triple": effectiveTriple, "layout": layout,
    "optimization": (if mode == "release": "O2" else: "O0"),
    "features": profile.features.join(",") & "; llvm-verify-each; lld; io-probe-v1", "cpu": profile.cpu, "linker": linker,
    "verifier": verifier, "legacyVerifier": legacyVerifier,
    "runtimeAbi": runtimeAbi,
    "runtime": (if options.runtime == "none": "none; freestanding; trap failures" else: "hosted"),
    "ioBatching": "off; differential and paired benchmark gates pending",
    "semanticPolicy": "foo-evidence-v2; shared-proof-call-free-memory-none; foo-inline-budget; scalar-fallback",
    "vectorization": "disabled: LLVM specialization has no backend parity/benchmark evidence"})

proc build*(module: Module; mode, outDir: string; options = Native();
    sourceFile = "main.iv"; progress: BuildProgress = nil): Result =
  try:
    validate(options)
    if getEnv("FOO_IO_BATCHING", "off") != "off":
      raise newException(ValueError, "LLVM I/O batching is not qualified; use --no-batching or FOO_IO_BATCHING=off")
    createDir(outDir)
    if options.kind notin ["", "exe"] or
        options.frameworks.len > 0 or options.cpp or
        options.sanitize.len > 0 or options.coverage.len > 0 or options.benchmark or
        options.threads or options.icon.len > 0 or
        options.exports.len > 0 or options.script.len > 0 or options.rpath.len > 0 or
        options.docs or options.profile.len > 0:
      raise newException(ValueError, "LLVM currently supports executable products without CPU, instrumentation, framework or custom linker-script features")
    let stamp = identity(mode, options)
    let metadata = parseJson(stamp)

    if progress != nil: progress("path", options.name, stamp, false)
    let source = absolutePath(outDir / "main.ll")
    let escaped = nativeEscape.escape(reach(module), Selection(backend: "llvm",
      target: metadata["triple"].getStr(), cpu: options.cpu, level: options.level,
      mode: mode, substrate: options.substrate,
      native: NativeSelection(substrate: options.native.substrate, clobbers: options.native.clobbers)))
    let selected = escaped.module
    writeFile(outDir / "typed-ir.json", irPrint.encode(selected))
    let prepared = prepare(selected)
    let batching = ioReport(prepared)
    writeFile(outDir / "io-batches.json", pretty(batching) & "\n")
    if progress != nil:
      progress("path", options.name, "I/O batches / 0 formed; " & $batching["operations"].getInt() &
        " writes retain their own result/error slots; see " & outDir / "io-batches.json", false)
      for candidate in batching["candidates"]:
        progress("strategy", "io-batching", candidate["function"].getStr() & "/" &
          candidate["block"].getStr() & ": " & $candidate["count"].getInt() &
          " operations; " & candidate["reason"].getStr() & "; " &
          candidate["boundary"].getStr(), false)
    let decisions = prepared.optimization
    metadata["semanticDecisions"] = %*{
      "generics": decisions.generics, "bounds": decisions.bounds,
      "expressions": decisions.expressions, "functions": decisions.functions,
      "dead": decisions.dead, "inlined": decisions.inlined,
      "boundaries": decisions.boundaries, "allocations": decisions.allocations,
      "pipelines": decisions.pipelines, "continuations": decisions.continuations,
      "serializations": decisions.serializations, "vectors": decisions.vectors}
    writeFile(outDir / "llvm.json", pretty(metadata) & "\n")
    if progress != nil:
      progress("path", options.name,
        "semantic / shared FOO proofs; retained call boundaries use noinline; " &
        "vectorization / scalar fallback: LLVM evidence is not established", false)
    # Validate semantic successors before prepare removes panic-only blocks;
    # LLVM numeric lowering emits the checked runtime failure path itself.
    let invalid = irValid.validate(selected)
    if invalid.len > 0:
      raise newException(ValueError, "Invalid typed IR: " & invalid[0].msg)
    let useRuntime = options.runtime != "none"
    let support = newSupport()
    writeFile(source, emit(prepared, metadata["triple"].getStr(), metadata["layout"].getStr(), support, sourceFile, hosted = useRuntime, cpu = options.cpu, modernMemory = not metadata["legacyVerifier"].getBool()))
    writeFile(outDir / "runtime.c", support.code(prepared, metadata["triple"].getStr(), hosted = useRuntime))
    if hosted(prepared):
      writeFile(outDir / "service.h", serviceHeader)
    var locations = newJArray()
    proc record(i: Instruction; function, label: string) =
      if i == nil: return
      locations.add(%*{"function": function, "block": label, "operation": $i.kind,
        "file": i.span.file, "start": i.span.start, "end": i.span.end, "trace": i.trace})
      if i.fallback != nil:
        for child in i.fallback.instrs: record(child, function, i.fallback.label)
        record(i.fallback.term, function, i.fallback.label)
    for function in prepared.funcs:
      for basicBlock in function.blocks:
        for i in basicBlock.instrs: record(i, function.name, basicBlock.label)
        record(basicBlock.term, function.name, basicBlock.label)
    writeFile(outDir / "source.json", pretty(%*{"source": sourceFile, "locations": locations}))
    let clang = quoteShell(clangPath(options))
    let level = " -" & metadata["optimization"].getStr() & " -fno-vectorize -fno-slp-vectorize"
    proc run(command, stage: string) =
      writeFile(outDir / (stage & ".command"), command & "\n")
      let response = execute.runCommand(command, outDir / (stage & ".diagnostics"), options.name, progress)
      writeFile(outDir / (stage & ".diagnostics"), response.output & "\nexitCode=" & $response.exitCode & "\n")
      if response.exitCode != 0:
        raise newException(IOError, "LLVM " & stage & " failed for " & sourceFile &
          "; see " & outDir / (stage & ".diagnostics") & "\n" & response.output)
    # Clang's LLVM pass manager runs the LLVM verifier after every pass.
    # This separate stage is mandatory even for emit-only builds.
    let verificationFlags = if metadata["legacyVerifier"].getBool(): " -mllvm -opaque-pointers" else: " -Xclang -llvm-verify-each"
    if metadata["legacyVerifier"].getBool():
      run(quoteShell(parentDir(findExe(clangPath(options))) / "opt") & " -opaque-pointers -verify-each -S " & quoteShell(source) &
        " -o " & quoteShell(absolutePath(outDir / "verified.ll")), "verify")
    else:
      run(clang & " -x ir -S -emit-llvm" & verificationFlags & level &
        " " & quoteShell(source) & " -o " & quoteShell(absolutePath(outDir / "verified.ll")), "verify")
    result.artifact = absolutePath(outDir / artifact(options))
    if options.compile:
      let libraries = support.libraries & options.libs
      let supplied = nativeSupply.prepare(libraries, options.includePaths, clangPath(options), metadata["triple"].getStr(), progress)
      var common = " -I " & quoteShell(absolutePath(outDir))
      if not useRuntime: common.add(" -ffreestanding -fno-stack-protector")
      for directory in supplied.headers & options.includePaths:
        common.add(" -I " & quoteShell(absolutePath(directory)))
      for define in supplied.defines: common.add(" -D" & quoteShell(define))
      var runtimeSources = options.sources
      if escaped.code.len > 0:
        let nativePath = absolutePath(outDir / "native-escape.c")
        writeFile(nativePath, (if useRuntime: "" else: "#define abort() __builtin_trap()\n") & escaped.code)
        runtimeSources.add(nativePath)
      if "sodium" in libraries:
        let directory = bundled("blake3/c", "blake3.c")
        common.add(" -I " & quoteShell(directory) & " -DBLAKE3_NO_SSE41 -DBLAKE3_NO_AVX2 -DBLAKE3_NO_AVX512")
        for name in ["blake3.c", "blake3_dispatch.c", "blake3_portable.c", "blake3_sse2.c"]:
          runtimeSources.add(directory / name)
      if prepared.externs.anyIt(it.abi in ["runtime.gpu", "runtime.vulkan"]):
        let directory = bundled("vulkan", "volk.c")
        common.add(" -I " & quoteShell(directory) & " -I " & quoteShell(directory / "include"))
        writeFile(outDir / "vulkan.c", vulkanSource)
        writeFile(outDir / "gpu.c", gpuSource)
        runtimeSources.add(directory / "volk.c")
      let objectPath = absolutePath(outDir / "main.obj")
      run(clang & " -x ir -c" & verificationFlags & level & " " & quoteShell(source) &
        " -o " & quoteShell(objectPath), "compile")
      let runtimeObject = absolutePath(outDir / "runtime.obj")
      run(clang & " -std=c11 -c" & level & common & " " & quoteShell(absolutePath(outDir / "runtime.c")) &
        " -I " & quoteShell(absolutePath(outDir)) & " -o " & quoteShell(runtimeObject), "runtime")
      var objects = " " & quoteShell(objectPath) & " " & quoteShell(runtimeObject)
      for index, sourcePath in runtimeSources:
        let nativeObject = absolutePath(outDir / ("foreign" & $index & ".obj"))
        var includes: string
        for directory in options.includePaths: includes.add(" -I " & quoteShell(absolutePath(directory)))
        run(clang & " -std=c11 -c" & level & common & includes & " " & options.flags.join(" ") & " " & quoteShell(absolutePath(sourcePath)) & " -o " & quoteShell(nativeObject), "foreign" & $index)
        objects.add(" " & quoteShell(nativeObject))
      for objectPath in options.objects: objects.add(" " & quoteShell(absolutePath(objectPath)))
      var linked = libraries
      if hosted(prepared):
        writeFile(outDir / "service.c", serviceSource)
        let serviceObject = absolutePath(outDir / "service.obj")
        var serviceFlags = resourceDefines(prepared)
        if not selective(options, escaped.code.len > 0): serviceFlags.delete(0)
        run(clang & " -std=c11 -c" & level & common & " " & serviceFlags.join(" ") &
          " " & quoteShell(absolutePath(outDir / "service.c")) & " -o " & quoteShell(serviceObject), "service")
        objects.add(" " & quoteShell(serviceObject))
        linked.add(service.libraries(metadata["triple"].getStr()))
      var links: string
      if not useRuntime:
        let entry = if prepared.funcs.anyIt("start" in it.attributes): "_start" else: "main"
        if metadata["triple"].getStr().contains("windows"):
          links.add(" -nostdlib -Wl,/entry:" & entry & ",/subsystem:console,/nodefaultlib")
        else:
          raise newException(ValueError, "Linux runtime-none startup is not yet qualified; use the hosted runtime")
      for library in linked:
        var found = false
        for entry in supplied.links:
          if entry.name == library:
            links.add(" " & quoteShell(entry.path)); found = true; break
        if not found: links.add(" -l" & quoteShell(library))
      run(clang & " -fuse-ld=lld" & objects & links & " -o " & quoteShell(result.artifact), "link")
      if options.run:
        let executed = execCmdEx(quoteShell(result.artifact))
        result.output = executed.output
        if executed.exitCode != 0:
          raise newException(IOError, "LLVM executable exited with " & $executed.exitCode & ": " & executed.output)
    result.success = true
  except CatchableError as error:
    result.error = error.msg
