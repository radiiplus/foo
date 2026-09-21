import std/[os, osproc, strutils]
import ./manager
import ../build/project
import ../pkg/cache as packageCache

type Component* = object
  name*: string
  ready*: bool
  required*: bool
  detail*: string

proc command(name, executable: string; required: bool; hint: string; result: var seq[Component]) =
  try:
    let path = packageCache.executable(executable)
    let output = execCmdEx(quoteShell(path) & " --version")
    if output.exitCode == 0:
      result.add(Component(name: name, ready: true, required: required, detail: output.output.strip().splitLines()[0]))
    else: result.add(Component(name: name, ready: false, required: required, detail: hint))
  except CatchableError:
    result.add(Component(name: name, ready: false, required: required, detail: hint))

proc doctor*(root = getCurrentDir()): seq[Component] =
  let project = newProject(root)
  let config = project.config()
  let backend = detect()
  result.add(Component(name: "Backend", ready: backend.path.len > 0, required: config.compiler.len == 0,
    detail: if backend.path.len > 0: backend.version & ": " & backend.path else: "Install Zig " & version))
  if config.compiler.len > 0:
    command("C compiler", config.compiler, true, "Cannot execute build.compiler '" & config.compiler & "'.", result)
  let files = project.files()
  var needsHeaders = false
  for file in files:
    if fileExists(file) and readFile(file).contains("use c \""): needsHeaders = true
  command("Headers", if getEnv("CLANG").len > 0: getEnv("CLANG") else: "clang", needsHeaders,
    "C header binding needs Clang; install LLVM or set CLANG.", result)
  for target in config.target:
    if target.contains("wasi"): command("WASI runner", "wasmtime", true, "Install wasmtime to run WASI outputs.", result)
