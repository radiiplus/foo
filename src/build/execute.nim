import std/[os, osproc]
import ./options

type RunningCommand = object
  process: Process
  outputFile: string
  script: string

proc start(command, outputFile: string): RunningCommand =
  if fileExists(outputFile): removeFile(outputFile)
  result.outputFile = outputFile
  result.script = outputFile & (when defined(windows): ".cmd" else: ".sh")
  let redirected = command & " > " & quoteShell(outputFile) & " 2>&1"
  when defined(windows):
    writeFile(result.script,
      "@echo off\r\n" & redirected & "\r\nexit /b %errorlevel%\r\n")
    result.process = startProcess(getEnv("COMSPEC", "cmd.exe"),
      args = ["/d", "/s", "/c", result.script], options = {poStdErrToStdOut})
  else:
    writeFile(result.script, "#!/bin/sh\n" & redirected & "\n")
    result.process = startProcess("/bin/sh", args = [result.script],
      options = {poStdErrToStdOut})

proc finish(command: var RunningCommand): tuple[output: string, exitCode: int] =
  try:
    result.exitCode = command.process.waitForExit()
  finally:
    command.process.close()
    if fileExists(command.script): removeFile(command.script)
  if fileExists(command.outputFile):
    result.output = readFile(command.outputFile)
    removeFile(command.outputFile)

proc runCommands*(commands: seq[string]; outputPrefix, name: string; jobs = 1;
    progress: BuildProgress = nil): tuple[output: string, exitCode: int] =
  var active: seq[RunningCommand]
  var next = 0
  result.exitCode = 0
  while next < commands.len or active.len > 0:
    while next < commands.len and active.len < max(1, jobs):
      active.add(start(commands[next], outputPrefix & "-" & $next))
      inc next
    var index = active.high
    while index >= 0:
      if not active[index].process.running:
        var command = active[index]
        let completed = finish(command)
        if completed.output.len > 0: result.output.add(completed.output)
        if result.exitCode == 0 and completed.exitCode != 0:
          result.exitCode = completed.exitCode
        active.delete(index)
      dec index
    if active.len > 0:
      if progress != nil: progress("tick", name, "", false)
      sleep(100)

proc runCommand*(command, outputFile, name: string;
    progress: BuildProgress = nil): tuple[output: string, exitCode: int] =
  runCommands(@[command], outputFile, name, 1, progress)
