import std/[algorithm, os, strutils]
import ./options
import ./execute as execution

proc windows(target: string): bool =
  if target.len > 0: target.toLowerAscii().contains("windows")
  else: defined(windows)

proc script*(path, output, target, kind: string): string =
  if path.len == 0 or kind in ["static", "shared"] or not windows(target):
    return ""
  if not path.toLowerAscii().endsWith(".ico"):
    raise newException(ValueError,
      "Windows executable icons must use the .ico format: " & path)
  if not fileExists(path):
    raise newException(IOError, "Executable icon not found: " & path)
  createDir(output)
  let staged = output / "icon.ico"
  if absolutePath(path) != absolutePath(staged):
    copyFile(path, staged)
  result = output / "icon.rc"
  writeFile(result, "1 ICON \"icon.ico\"\n")

proc locate(): string =
  result = getEnv("FOO_RESOURCE_COMPILER")
  if result.len > 0: return
  result = findExe("rc.exe")
  if result.len > 0: return
  let sdk = getEnv("WindowsSdkDir", "C:/Program Files (x86)/Windows Kits/10")
  let bin = sdk / "bin"
  if dirExists(bin):
    var versions: seq[string]
    for kind, path in walkDir(bin):
      if kind == pcDir and fileExists(path / "x64" / "rc.exe"):
        versions.add(path)
    versions.sort()
    if versions.len > 0: result = versions[^1] / "x64" / "rc.exe"
  if result.len == 0:
    raise newException(IOError,
      "Windows SDK resource compiler missing; set FOO_RESOURCE_COMPILER")

proc compile*(source, output, name: string;
    progress: Observer = nil; compiler = ""): string =
  if source.len == 0: return ""
  result = output / "icon.res"
  let compiler = if compiler.len > 0: compiler else: locate()
  let command = quoteShell(compiler) & " /I " & quoteShell(output) &
    " /FO" & quoteShell(result) & " " & quoteShell(source)
  let compiled = execution.run(command, output / ".icon-output",
    name, progress)
  if compiled.exitCode != 0:
    raise newException(OSError,
      "Could not compile the executable icon. Install the Windows SDK resource compiler or set " &
      "FOO_RESOURCE_COMPILER.\n" & compiled.output)
