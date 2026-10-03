import std/[os, osproc, strutils]
import ./manager
import ./native
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

proc header(name, path, library, compiler, hint: string;
    result: var seq[Component]) =
  try:
    let supply = prepare(@[library], @[], compiler, "")
    if supply.links.len > 0:
      result.add(Component(name: name, ready: true, required: false,
        detail: path & " provisioned in FOO cache"))
      return
    let zig = splitFile(compiler).name.toLowerAscii() == "zig"
    let command = quoteShell(compiler) & (if zig: " cc" else: "") &
      " -x c - -fsyntax-only"
    let checked = execCmdEx(command, input = "#include <" & path & ">\n")
    result.add(Component(name: name, ready: checked.exitCode == 0,
      required: false, detail: if checked.exitCode == 0:
        path & " available" else: hint))
  except CatchableError as error:
    result.add(Component(name: name, ready: false, required: false,
      detail: hint & " " & error.msg))

proc doctor*(root = getCurrentDir()): seq[Component] =
  let project = newProject(root)
  let config = project.config()
  let backend = detect()
  result.add(Component(name: "Backend", ready: backend.path.len > 0, required: config.compiler.len == 0,
    detail: if backend.path.len > 0: backend.version & ": " & backend.path
      else: "Run `foo toolchain install base` to install Zig " & version & "."))
  if config.compiler.len > 0:
    command("C compiler", config.compiler, true, "Cannot execute build.compiler '" & config.compiler & "'.", result)
  let files = project.files()
  var needsHeaders = false
  var crypto = false
  var compress = false
  var http = false
  for file in files:
    if not fileExists(file): continue
    let source = readFile(file)
    if source.contains("use c \""): needsHeaders = true
    if source.contains("use crypto"): crypto = true
    if source.contains("use compress"): compress = true
    if source.contains("use http"): http = true
  let headerHint = if needsHeaders:
    "This project imports C headers; install LLVM or set CLANG."
  else:
    "Not required unless this project imports C headers."
  command("Headers", if getEnv("CLANG").len > 0: getEnv("CLANG") else: "clang", needsHeaders,
    headerHint, result)
  let compiler = if config.compiler.len > 0: config.compiler
    elif getEnv("CC").len > 0: getEnv("CC")
    elif defined(windows): "clang"
    elif findExe("cc").len > 0: "cc"
    elif backend.path.len > 0: backend.path
    else: "cc"
  if crypto:
    header("C crypto", "sodium.h", "sodium", compiler,
      "Install libsodium-dev on Debian/Ubuntu or provide the libsodium include path for C builds.", result)
  if compress:
    header("C compression", "zlib.h", "z", compiler,
      "Install zlib1g-dev on Debian/Ubuntu or provide the zlib include path for C builds.", result)
  when not defined(windows):
    if http:
      header("C HTTP", "curl/curl.h", "curl", compiler,
        "Install libcurl4-openssl-dev on Debian/Ubuntu or provide the libcurl include path for C builds.", result)
  for target in config.target:
    if target.contains("wasi"): command("WASI runner", "wasmtime", true, "Install wasmtime to run WASI outputs.", result)
