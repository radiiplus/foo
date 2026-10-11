import std/[json, os, osproc, strutils]
import ../../build/options
import ../../build/execute as execute
import ../../ir/node
import ../../ir/reach
import ../../ir/monomorph
import ../../ir/valid as irValid
import ../native/service
import ./emitter
import ./runtime
import ./abi

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
  let linker = query(quoteShell(parentDir(findExe(clangPath(options))) / "lld-link.exe") & " --version")
  $(%*{"backend": "llvm", "clang": clangPath(options), "version": version,
    "triple": triple, "layout": "e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128",
    "optimization": (if mode == "release": "O2" else: "O0"),
    "features": "generic; llvm-verify-each; lld", "linker": linker,
    "runtimeAbi": runtimeAbi,
    "semanticPolicy": "foo-evidence-v2; shared-proof-call-free-memory-none; foo-inline-budget; scalar-fallback",
    "vectorization": "disabled: LLVM specialization has no backend parity/benchmark evidence"})

proc build*(module: Module; mode, outDir: string; options = Native();
    sourceFile = "main.iv"; progress: BuildProgress = nil): Result =
  try:
    validate(options)
    createDir(outDir)
    if options.kind notin ["", "exe"] or options.cpu.len > 0 or
        options.frameworks.len > 0 or options.cpp or
        options.sanitize.len > 0 or options.coverage.len > 0 or options.benchmark or
        options.threads or options.runtime == "none" or options.icon.len > 0 or
        options.exports.len > 0 or options.script.len > 0 or options.rpath.len > 0 or
        options.docs or options.profile.len > 0:
      raise newException(ValueError, "LLVM Batch 1 supports only hosted executables without runtime, CPU, instrumentation or custom linking features")
    let stamp = identity(mode, options)
    let metadata = parseJson(stamp)

    if progress != nil: progress("path", options.name, stamp, false)
    let source = absolutePath(outDir / "main.ll")
    let selected = reach(module)
    let prepared = prepare(selected)
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
    writeFile(source, emit(prepared, metadata["triple"].getStr(), metadata["layout"].getStr(), sourceFile))
    let support = runtime.support(prepared, metadata["triple"].getStr())
    writeFile(outDir / "runtime.c", support.code)
    if hosted(prepared):
      writeFile(outDir / "service.h", serviceHeader)
    writeFile(outDir / "source.json", $(%*{"source": sourceFile,
      "locations": "Every language instruction retains its original file/start/end offsets in LLVM IR; trace operations cross the runtime ABI unchanged"}))
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
      run(clang & " -std=c11 -c" & level & " " & quoteShell(absolutePath(outDir / "runtime.c")) &
        " -I " & quoteShell(absolutePath(outDir)) & " -o " & quoteShell(runtimeObject), "runtime")
      var objects = " " & quoteShell(objectPath) & " " & quoteShell(runtimeObject)
      for index, sourcePath in options.sources:
        let nativeObject = absolutePath(outDir / ("foreign" & $index & ".obj"))
        var includes: string
        for directory in options.includePaths: includes.add(" -I " & quoteShell(absolutePath(directory)))
        run(clang & " -std=c11 -c" & level & includes & " " & options.flags.join(" ") & " " & quoteShell(absolutePath(sourcePath)) & " -o " & quoteShell(nativeObject), "foreign" & $index)
        objects.add(" " & quoteShell(nativeObject))
      for objectPath in options.objects: objects.add(" " & quoteShell(absolutePath(objectPath)))
      var libraries = support.libraries & options.libs
      if hosted(prepared):
        writeFile(outDir / "service.c", serviceSource)
        let serviceObject = absolutePath(outDir / "service.obj")
        run(clang & " -std=c11 -c" & level & " " & resourceDefines(prepared).join(" ") &
          " " & quoteShell(absolutePath(outDir / "service.c")) & " -o " & quoteShell(serviceObject), "service")
        objects.add(" " & quoteShell(serviceObject))
        libraries.add(service.libraries(metadata["triple"].getStr()))
      var links: string
      for library in libraries: links.add(" -l" & library)
      run(clang & " -fuse-ld=lld" & objects & links & " -o " & quoteShell(result.artifact), "link")
      if options.run:
        let executed = execCmdEx(quoteShell(result.artifact))
        result.output = executed.output
        if executed.exitCode != 0:
          raise newException(IOError, "LLVM executable exited with " & $executed.exitCode & ": " & executed.output)
    result.success = true
  except CatchableError as error:
    result.error = error.msg
