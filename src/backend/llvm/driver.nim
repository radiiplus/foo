import std/[json, os, osproc, strutils, tempfiles]
import ../../build/options
import ../../build/execute as execute
import ../../ir/node
import ../../ir/reach
import ../../ir/monomorph
import ../../ir/valid as irValid
import ./emitter
import ./runtime

const
  serviceHeader = staticRead("../native/service.h")
  serviceSource = staticRead("../native/service.c")

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
  let clang = quoteShell(clangPath(options))
  let version = query(clang & " --version")
  let triple = query(clang & " -dumpmachine")
  if triple != "x86_64-pc-windows-msvc":
    raise newException(ValueError, "LLVM Batch 1 is verified only for x86_64-pc-windows-msvc; selected " & triple)
  if options.target.len > 0 and options.target notin [triple, "x86_64-windows-msvc"]:
    raise newException(ValueError, "LLVM Batch 1 does not support cross targets: " & options.target)
  # Ask the selected LLVM target machine for its effective ABI, including
  # Clang's detected MSVC version. The probe is LLVM IR, never C or Zig.
  let probe = createTempFile("foo-llvm-target-", ".ll")
  var effectiveTriple, layout: string
  try:
    probe.cfile.write("define void @foo_target_probe() { ret void }\n")
    probe.cfile.close()
    let ir = query(clang & " -x ir -S -emit-llvm " & quoteShell(probe.path) & " -o -")
    for line in ir.splitLines():
      if line.startsWith("target triple = "):
        effectiveTriple = line.split('"')[1]
      elif line.startsWith("target datalayout = "):
        layout = line.split('"')[1]
    if effectiveTriple.len == 0 or layout.len == 0:
      raise newException(IOError, "Clang did not report an LLVM target triple and data layout")
  finally:
    if fileExists(probe.path): removeFile(probe.path)
  let linker = query(quoteShell(parentDir(findExe(clangPath(options))) / "lld-link.exe") & " --version")
  $(%*{"backend": "llvm", "clang": clangPath(options), "version": version,
    "triple": effectiveTriple, "layout": layout,
    "optimization": (if mode == "release": "O2" else: "O0"),
    "features": "generic; llvm-verify-each; lld", "linker": linker,
    "runtimeAbi": "llvm.core.pointer.v1",
    "semanticPolicy": "foo-llvm-core-v2; checked-width-1-128; pointer-runtime-abi; scalar-proof-memory-none",
    "vectorization": "disabled: LLVM specialization has no backend parity/benchmark evidence"})

proc build*(module: Module; mode, outDir: string; options = Native();
    sourceFile = "main.iv"; progress: BuildProgress = nil): Result =
  try:
    validate(options)
    createDir(outDir)
    let errors = irValid.validate(module)
    if errors.len > 0:
      var messages: seq[string]
      for error in errors: messages.add(error.msg)
      raise newException(ValueError, "Invalid typed IR before LLVM lowering: " & messages.join("\n"))
    if options.kind notin ["", "exe"] or options.cpu.len > 0 or
        options.sources.len > 0 or options.objects.len > 0 or options.flags.len > 0 or
        options.libs.len > 0 or options.frameworks.len > 0 or options.cpp or
        options.sanitize.len > 0 or options.coverage.len > 0 or options.benchmark or
        options.threads or options.runtime == "none" or options.icon.len > 0 or
        options.exports.len > 0 or options.script.len > 0 or options.rpath.len > 0 or
        options.docs or options.debug or options.profile.len > 0 or options.includePaths.len > 0 or
        options.substrate notin ["", "auto"] or options.native.substrate.len > 0 or
        options.native.clobbers.len > 0:
      raise newException(ValueError, "LLVM Batch 1 supports only hosted executables without runtime, CPU, instrumentation or custom linking features")
    let stamp = identity(mode, options)
    let metadata = parseJson(stamp)
    let selected = prepare(reach(module))
    let decisions = selected.optimization
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
    if progress != nil: progress("path", options.name, stamp, false)
    let source = absolutePath(outDir / "main.ll")
    let support = newSupport()
    writeFile(source, emit(selected, metadata["triple"].getStr(), metadata["layout"].getStr(), support, sourceFile))
    let runtimePath = absolutePath(outDir / "runtime.c")
    let runtimeCode = support.code(selected)
    writeFile(runtimePath, runtimeCode)
    if runtimeCode.contains("#define FOO_SERVICE"):
      writeFile(outDir / "service.h", serviceHeader)
      writeFile(outDir / "service.c", serviceSource)
    var locations = newJArray()
    proc record(i: Instruction; function, label: string) =
      if i == nil: return
      locations.add(%*{"function":function,"block":label,"operation": $i.kind,
        "file":i.span.file,"start":i.span.start,"end":i.span.end,"trace":i.trace})
      if i.fallback != nil:
        for child in i.fallback.instrs: record(child,function,i.fallback.label)
        record(i.fallback.term,function,i.fallback.label)
    for function in selected.funcs:
      for basicBlock in function.blocks:
        for i in basicBlock.instrs: record(i,function.name,basicBlock.label)
        record(basicBlock.term,function.name,basicBlock.label)
    writeFile(outDir / "source.json", pretty(%*{"source": sourceFile,"locations":locations}))
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
    run(clang & " -x ir -S -emit-llvm -Xclang -llvm-verify-each" & level &
      " " & quoteShell(source) & " -o " & quoteShell(absolutePath(outDir / "verified.ll")), "verify")
    result.artifact = absolutePath(outDir / artifact(options))
    if options.compile:
      let objectPath = absolutePath(outDir / "main.obj")
      run(clang & " -x ir -c -Xclang -llvm-verify-each" & level & " " & quoteShell(source) &
        " -o " & quoteShell(objectPath), "compile")
      let runtimeObject = absolutePath(outDir / "runtime.obj")
      run(clang & " -std=c11 -c" & level & " " & quoteShell(runtimePath) & " -o " & quoteShell(runtimeObject), "runtime")
      var inputs = quoteShell(objectPath) & " " & quoteShell(runtimeObject)
      if runtimeCode.contains("#define FOO_SERVICE"):
        let serviceObject = absolutePath(outDir / "service.obj")
        run(clang & " -std=c11 -c" & level & " " & quoteShell(absolutePath(outDir / "service.c")) & " -o " & quoteShell(serviceObject), "service")
        inputs.add(" " & quoteShell(serviceObject) & " -lws2_32 -ldnsapi -liphlpapi")
      for library in support.libraries: inputs.add(" -l" & library)
      run(clang & " -fuse-ld=lld " & inputs & " -o " & quoteShell(result.artifact), "link")
      if options.run:
        let executed = execCmdEx(quoteShell(result.artifact))
        result.output = executed.output
        if executed.exitCode != 0:
          raise newException(IOError, "LLVM executable exited with " & $executed.exitCode & ": " & executed.output)
    result.success = true
  except CatchableError as error:
    result.error = error.msg
