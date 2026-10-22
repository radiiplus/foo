import std/[os, osproc, strutils, tables]
when defined(linux): import std/tempfiles
import ./native
import ./qbe as toolchain
import ../backend/qbe/driver as qbe
import ../build/options as configuration
import ../build/project
import ../pkg/cache as cache

type Component* = object
  name*: string
  ready*: bool
  required*: bool
  detail*: string

proc command(name, executable: string; required: bool; hint: string; result: var seq[Component]) =
  try:
    let path = cache.executable(executable)
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
    var ready = false
    for directory in supply.headers:
      if fileExists(directory / path): ready = true
    result.add(Component(name: name, ready: ready, required: true,
      detail: if ready: path & " from checksum-verified controlled vendor input" else: hint))
  except CatchableError as error:
    result.add(Component(name: name, ready: false, required: true,
      detail: hint & " " & error.msg))

proc doctor*(root = getCurrentDir()): seq[Component] =
  let project = project(root)
  let config = project.config()
  try:
    let selected = toolchain.identity()
    result.add(Component(name:"QBE toolchain",ready:true,required:true,
      detail:selected.qbe & "; C compiler: " & selected.cc))
  except CatchableError as error:
    result.add(Component(name:"QBE toolchain",ready:false,required:true,detail:error.msg))
  if config.compiler.len > 0:
    command("C compiler", config.compiler, true, "Cannot execute build.compiler '" & config.compiler & "'.", result)
  let files = project.files()
  var needs = false
  var crypto = false
  var compress = false
  var http = false
  for file in files:
    if not fileExists(file): continue
    let source = readFile(file)
    if source.contains("use c \""): needs = true
    if source.contains("use crypto"): crypto = true
    if source.contains("use compress"): compress = true
    if source.contains("use http"): http = true
  let declaration = if needs:
    "This project imports C headers; set CLANG or provide a C compiler."
  else:
    "Not required unless this project imports C headers."
  command("Headers", if getEnv("CLANG").len > 0: getEnv("CLANG") else: "clang", needs,
    declaration, result)
  let compiler = if config.compiler.len > 0: config.compiler
    elif getEnv("CC").len > 0: getEnv("CC")
    elif defined(windows): "clang"
    elif findExe("cc").len > 0: "cc"
    else: "clang"
  if crypto:
    header("C crypto", "sodium.h", "sodium", compiler,
      "Missing controlled libsodium artifact; use the explicit tools/vendor/build.mjs bootstrap for your qualified target.", result)
  if compress:
    header("C compression", "zlib.h", "z", compiler,
      "Missing controlled zlib artifact; use the explicit tools/vendor/build.mjs bootstrap for your qualified target.", result)
  when not defined(windows):
    if http:
      header("C HTTP", "curl/curl.h", "curl", compiler,
        "Missing checksum-verified curl headers; runtime requires OS libcurl.so.4. Doctor never provisions packages.", result)
      when defined(linux):
        let probe = createTempFile("foo-doctor-curl-", ".out")
        probe.cfile.close()
        try:
          let headers = container("curl/include")
          let checked = execCmdEx(quoteShell(compiler) & " -x c - -I " & quoteShell(headers) &
            " -lcurl -o " & quoteShell(probe.path),
            input = "#include <curl/curl.h>\nint main(void) { return curl_version() == 0; }\n")
          result.add(Component(name: "OS libcurl link ABI", ready: checked.exitCode == 0,
            required: true, detail: if checked.exitCode == 0:
              "Target OS libcurl links against controlled headers; runtime needs libcurl.so.4 and its transitive providers"
            else: "Missing target OS libcurl link library or C SDK; supply it explicitly. " & checked.output))
        except CatchableError as error:
          result.add(Component(name: "OS libcurl link ABI", ready: false, required: true, detail: error.msg))
        finally:
          if fileExists(probe.path): removeFile(probe.path)
  for target in config.target:
    if target.contains("wasi"): command("WASI runner", "wasmtime", true, "Install wasmtime to run WASI outputs.", result)

  if config.backend in ["", "qbe"]:
    let requested = if config.target.len > 0: config.target else: @[host]
    for target in requested:
      var products: seq[tuple[name: string, kind: string, script: string, exports: string]]
      if config.products.len == 0:
        products.add(("",config.`type`,config.link.script,config.link.exports))
      else:
        for name, product in config.products:
          products.add((name,product.kind,
            (if product.script.len > 0: product.script else: config.link.script),
            (if product.exports.len > 0: product.exports else: config.link.exports)))
      for product in products:
        let label = "QBE target " & target & (if product.name.len > 0: " / " & product.name else: "")
        proc path(path: string): string =
          if path.len == 0 or isAbsolute(path): path else: project.root / path
        try:
          discard qbe.identity("dev",configuration.Native(target:target,compiler:config.compiler,
            runtime:config.runtime,kind:product.kind,cpu:config.cpu,debug:config.debug,
            script:path(product.script),exports:path(product.exports),threads:target == "wasi-threads"))
          result.add(Component(name:label,ready:true,required:true,
            detail:"QBE and C compiler identity verified; builds and doctor never download"))
        except CatchableError as error:
          result.add(Component(name:label,ready:false,required:true,detail:error.msg))
