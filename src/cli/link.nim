import std/[os, strutils]
import ../build/project

proc directory*(): string =
  let configured = getEnv("FOO_BIN")
  if configured.len > 0: absolutePath(configured)
  else: getHomeDir() / ".foo" / "bin"

proc valid(name: string): bool =
  if name.len == 0 or not name[0].isAlphaAscii: return false
  for character in name:
    if not (character.isAlphaNumeric or character == '-'): return false
  true

proc quoted(value: string): string =
  when defined(windows):
    "\"" & value.replace("\"", "\"\"") & "\""
  else:
    "'" & value.replace("'", "'\"'\"'") & "'"

proc install*(project: Project; entry = ""; name = ""): string =
  discard project.entryPath(entry)
  let command = if name.len > 0: name
    elif entry.len > 0: entry
    else: project.manifest().name
  if not valid(command):
    raise newException(ValueError,
      "Command names begin with a letter and use letters, digits, or hyphens")
  let bin = directory()
  createDir(bin)
  when defined(windows):
    result = bin / (command & ".cmd")
    writeFile(result, "@echo off\r\npushd " & quoted(project.root) &
      "\r\n" & quoted(getAppFilename()) & " run" &
      (if entry.len > 0: " " & quoted(entry) else: "") &
      " -- %*\r\nset \"FOO_EXIT=%errorlevel%\"\r\npopd\r\nexit /b %FOO_EXIT%\r\n")
  else:
    result = bin / command
    writeFile(result, "#!/bin/sh\ncd " & quoted(project.root) &
      " || exit 1\nexec " & quoted(getAppFilename()) & " run" &
      (if entry.len > 0: " " & quoted(entry) else: "") & " -- \"$@\"\n")
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc remove*(name: string): string =
  if not valid(name):
    raise newException(ValueError, "Invalid command name: " & name)
  result = directory() / (name & (when defined(windows): ".cmd" else: ""))
  if not fileExists(result):
    raise newException(IOError, "Linked command not found: " & name)
  removeFile(result)

proc available*(): bool =
  let wanted = absolutePath(directory()).normalizePathEnd(false)
  for value in getEnv("PATH").split(PathSep):
    if value.len > 0 and cmpPaths(absolutePath(value).normalizePathEnd(false), wanted) == 0:
      return true
