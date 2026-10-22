## Capture both observable streams without pipe-buffer deadlocks.
import std/[os, osproc]
import ../build/execute

type Observation* = object
  stdout*, stderr*: string
  exitCode*: int

proc mark*(module, name: string) =
  ## Report a completed case, never a substitute for a suite's final result.
  let identity = getEnv("FOOTESTID")
  if identity.len > 0:
    echo "FOO_NATIVE_CASE|", identity, "|", module, "|", name

proc observe*(artifact, directory, prefix: string; workingDir = ""; args: seq[string] = @[]): Observation =
  createDir(directory)
  let output = absolutePath(directory / (prefix & ".stdout"))
  let errors = absolutePath(directory / (prefix & ".stderr"))
  var command = quoteShell(absolutePath(artifact))
  for argument in args: command.add(" " & quoteShell(argument))
  command.add(" > " & quoteShell(output) & " 2> " & quoteShell(errors))
  let execution = capture(command, workingDir = workingDir)
  result.exitCode = execution.exitCode
  if not fileExists(output) or not fileExists(errors):
    raise newException(IOError, "Execution did not produce both capture files")
  result.stdout = readFile(output)
  result.stderr = readFile(errors)
