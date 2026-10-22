import std/[os, strutils, times]
import ../../src/build/execute

if paramCount() > 0 and paramStr(1) == "--stdin":
  stdout.write(stdin.readAll())
  quit(0)

if paramCount() > 0 and paramStr(1) == "--child":
  echo (if paramStr(2) == "--large": repeat("x", 131072) else: paramStr(2))
  quit(parseInt(paramStr(3)))

let executable = quoteShell(getAppFilename())
let success = executable & " --child " & quoteShell("two words") & " 0"
let failed = executable & " --child failure 7"
let one = run(success, getTempDir() / "foo-execute-one", "test")
doAssert one.exitCode == 0 and one.output.strip() == "two words"
let two = run(failed, getTempDir() / "foo-execute-two", "test")
doAssert two.exitCode == 7 and two.output.strip() == "failure"
let parallel = parallel(@[success, failed], getTempDir() / "foo-execute-many", "test", 2)
doAssert parallel.exitCode == 7
doAssert "two words" in parallel.output and "failure" in parallel.output
let large = run(executable & " --child --large 0",
  getTempDir() / "foo-execute-large", "test")
doAssert large.exitCode == 0 and large.output.strip().len == 131072

let captured = capture(success)
doAssert captured.exitCode == 0 and captured.output.strip() == "two words"
let rejection = capture(failed)
doAssert rejection.exitCode == 7 and rejection.output.strip() == "failure"
let streamed = capture(executable & " --child --large 0")
doAssert streamed.exitCode == 0 and streamed.output.strip().len == 131072
let input = capture(executable & " --stdin", input = "binary\0input\n")
doAssert input.exitCode == 0 and input.output == "binary\0input\n"
let direct = captureArgs(getAppFilename(), @["--child", "two words", "0"])
doAssert direct.exitCode == 0 and direct.output.strip() == "two words"
let directFailure = captureArgs(getAppFilename(), @["--child", "failure", "7"])
doAssert directFailure.exitCode == 7 and directFailure.output.strip() == "failure"
let directLarge = captureArgs(getAppFilename(), @["--child", "--large", "0"])
doAssert directLarge.exitCode == 0 and directLarge.output.strip().len == 131072

if paramCount() > 0 and paramStr(1) == "--bench":
  let started = epochTime()
  for index in 0 ..< 20:
    let run = run(success, getTempDir() / "foo-execute-bench", "test")
    doAssert run.exitCode == 0 and run.output.strip() == "two words"
  echo "20 launches: ", int((epochTime() - started) * 1000), " ms"
else:
  echo "build execution parity: ok"
