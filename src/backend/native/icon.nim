import std/[os, strutils]
import ../../build/options
import ../../build/execute as buildExecute

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

proc compile*(source, output, name: string;
    progress: BuildProgress = nil): string =
  if source.len == 0: return ""
  result = output / "icon.res"
  let compiler = getEnv("FOO_RESOURCE_COMPILER", "llvm-rc")
  let command = quoteShell(compiler) & " /I " & quoteShell(output) &
    " /FO" & quoteShell(result) & " " & quoteShell(source)
  let compiled = buildExecute.runCommand(command, output / ".icon-output",
    name, progress)
  if compiled.exitCode != 0:
    raise newException(OSError,
      "Could not compile the executable icon. Install llvm-rc or set " &
      "FOO_RESOURCE_COMPILER.\n" & compiled.output)
