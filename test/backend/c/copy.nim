import std/[os, osproc, strutils]

let root = currentSourcePath().parentDir().parentDir().parentDir().parentDir()
let source = root / "test" / "native" / "copy.c"
let output = root / ".artifacts" /
  ("copy-" & getEnv("FOOTESTID", "local"))
let configured = getEnv("CC")
let compiler = if configured.len > 0: configured
  elif findExe("clang").len > 0: "clang"
  else: "cc"
createDir(output)

proc verify(name: string; flags: seq[string] = @[]) =
  let suffix = when defined(windows): ".exe" else: ""
  let binary = output / (name & suffix)
  var command = quoteShell(compiler) & " -std=c11 -O3 "
  for flag in flags: command.add(quoteShell(flag) & " ")
  command.add(quoteShell(source) & " -o " & quoteShell(binary))
  let compiled = execCmdEx(command, workingDir = root)
  doAssert compiled.exitCode == 0, compiled.output
  let executed = execCmdEx(quoteShell(binary), workingDir = root)
  doAssert executed.exitCode == 0, executed.output
  doAssert "copy correctness passed" in executed.output or
    "execution skipped" in executed.output, executed.output

verify("portable")
when defined(amd64):
  verify("x86", @["-DFOO_COPY_X86"])
  verify("avx2", @["-DFOO_COPY_AVX", "-mavx2"])

echo "copy boundary, alignment, and overlap parity: ok"
