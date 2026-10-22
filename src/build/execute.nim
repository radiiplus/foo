import std/[os, osproc, streams, strutils, tempfiles]
import ./options

type Job = object
  index: int
  process: Process
  capture: string
  script: string

proc offline*(command: string) =
  for token in command.splitWhitespace():
    let name = splitFile(token.strip(chars = {'"', '\''})).name.toLowerAscii()
    if name in ["apt", "apt-get", "apt-cache", "dpkg-deb", "wget", "curl", "winget", "choco", "brew"]:
      raise newException(IOError, "Offline build rejected dependency provisioning command: " & name & "; use an explicit developer bootstrap outside foo build/test")

proc capture*(command: string; input = ""; workingDir = ""): tuple[output: string, exitCode: int] =
  ## Tool output uses files so inherited pipe writers cannot delay EOF forever.
  offline(command)
  let directory = createTempDir("foo-command-", "")
  let source = directory / "input"
  let output = directory / "output"
  let script = directory / (when defined(windows): "command.cmd" else: "command.sh")
  writeFile(source, input)
  let redirected = "(" & command & ") < " & quoteShell(source) & " > " & quoteShell(output) & " 2>&1"
  when defined(windows):
    writeFile(script, "@echo off\r\n" & redirected & "\r\nexit /b %errorlevel%\r\n")
  else:
    writeFile(script, "#!/bin/sh\n" & redirected & "\n")
  var child: Process
  try:
    when defined(windows):
      child = startProcess(getEnv("COMSPEC", "cmd.exe"), workingDir = workingDir,
        args = @["/d", "/c", script], options = {poUsePath, poParentStreams, poDaemon})
    else:
      child = startProcess("/bin/sh", workingDir = workingDir,
        args = @[script], options = {poParentStreams})
    result.exitCode = child.waitForExit()
    result.output = readFile(output)
  finally:
    if child != nil: child.close()
    for path in [source, output, script]:
      if fileExists(path): removeFile(path)
    removeDir(directory)

proc captureArgs*(program: string; args: openArray[string];
    workingDir = ""): tuple[output: string, exitCode: int] =
  ## Direct tool invocations avoid a shell and per-call temporary files.
  var child = startProcess(program, workingDir = workingDir, args = args,
    options = {poUsePath, poStdErrToStdOut})
  try:
    child.inputStream.close()
    result.output = child.outputStream.readAll()
    result.exitCode = child.waitForExit()
  finally:
    child.close()

proc start(command, capture: string): Job =
  offline(command)
  result.capture = absolutePath(capture)
  if fileExists(result.capture): removeFile(result.capture)
  let redirected = command & " > " & quoteShell(result.capture) & " 2>&1"
  when defined(windows):
    result.script = result.capture & ".cmd"
    writeFile(result.script, "@echo off\r\n" & redirected & "\r\nexit /b %errorlevel%\r\n")
    result.process = startProcess(getEnv("COMSPEC", "cmd.exe"),
      args = @["/d", "/c", result.script], options = {poUsePath, poParentStreams, poDaemon})
  else:
    result.script = result.capture & ".sh"
    writeFile(result.script, "#!/bin/sh\n" & redirected & "\n")
    result.process = startProcess("/bin/sh", args = [result.script],
      options = {poParentStreams})

proc finish(command: var Job): tuple[output: string, exitCode: int] =
  try:
    result.exitCode = command.process.waitForExit()
  finally:
    command.process.close()
    if fileExists(command.script): removeFile(command.script)
  if fileExists(command.capture):
    result.output = readFile(command.capture)
    removeFile(command.capture)

proc parallel*(commands: seq[string]; outputPrefix, name: string; jobs = 1;
    progress: Observer = nil): tuple[output: string, exitCode: int] =
  var active: seq[Job]
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
      when defined(windows): sleep(10)
      else: sleep(100)

proc run*(command, capture, name: string;
    progress: Observer = nil): tuple[output: string, exitCode: int] =
  parallel(@[command], capture, name, 1, progress)

proc batch*(commands: seq[tuple[command, diagnostics: string]]; name: string;
    jobs: int; progress: Observer = nil): seq[tuple[output: string, exitCode: int]] =
  ## Keep result slots in submission order, regardless of completion order.
  result.setLen(commands.len)
  var active: seq[Job]
  var next = 0
  try:
    while next < commands.len or active.len > 0:
      while next < commands.len and active.len < max(1, jobs):
        var command = start(commands[next].command, commands[next].diagnostics & ".pending")
        command.index = next
        active.add(command)
        inc next
      var index = active.high
      while index >= 0:
        if not active[index].process.running:
          result[active[index].index] = finish(active[index])
          active.delete(index)
        dec index
      if active.len > 0:
        if progress != nil: progress("tick", name, "", false)
        sleep(10)
  finally:
    # Startup/observation errors cannot orphan the workers already launched.
    for command in active.mitems:
      if command.process.running: command.process.terminate()
      discard finish(command)
