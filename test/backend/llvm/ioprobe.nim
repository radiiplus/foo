import std/[os, osproc]

let directory = absolutePath(".artifacts/llvm-ioprobe-" & getEnv("FOOTESTID", "local"))
createDir(directory)
let executable = directory / (if defined(windows): "probe.exe" else: "probe")
let compiled = execCmdEx("clang -std=c11 " & quoteShell(absolutePath("test/backend/llvm/ioprobe.c")) &
  " -o " & quoteShell(executable))
doAssert compiled.exitCode == 0, compiled.output
let run = execCmdEx(quoteShell(executable))
doAssert run.exitCode == 0, run.output
echo run.output
