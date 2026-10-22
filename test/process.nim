import std/[os, strutils]
import ../src/test/process
if paramCount() > 0 and paramStr(1) == "--child":
  stdout.write("a\0b" & repeat("x",131072))
  stderr.write("failure\n" & repeat("y",131072))
  quit(7)
# Invoke the same binary via a tiny script argument to exercise real exit/bytes.
let root = getTempDir() / ("foo-observation-" & $getCurrentProcessId())
createDir(root)
let script = root / (when defined(windows): "child.cmd" else: "child.sh")
let executable = root / (when defined(windows): "child program.exe" else: "child program")
copyFile(getAppFilename(), executable)
when not defined(windows):
  setFilePermissions(executable,{fpUserRead,fpUserWrite,fpUserExec})
when defined(windows):
  writeFile(script, "@echo off\r\n\"" & executable & "\" --child\r\n")
else:
  writeFile(script, "#!/bin/sh\n\"" & executable & "\" --child\n")
  setFilePermissions(script,{fpUserRead,fpUserWrite,fpUserExec})
let direct = observe(executable, root, "direct", args = @["--child"])
doAssert direct.exitCode == 7
doAssert direct.stdout == "a\0b" & repeat("x",131072)
doAssert direct.stderr == "failure\n" & repeat("y",131072)
let result = observe(script, root, "capture")
doAssert result.exitCode == 7
doAssert result.stdout == "a\0b" & repeat("x",131072)
doAssert result.stderr == "failure\n" & repeat("y",131072)
removeDir(root)
echo "process stream/exit/binary parity: ok"
