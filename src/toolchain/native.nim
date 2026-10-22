## Offline, repository-controlled native dependency resolution. Never provisions.
import std/[algorithm, json, os, osproc, strutils]
import ../build/options
import ../pkg/hash

type Supply* = object
  headers*, sources*: seq[string]
  links*: seq[tuple[name: string, path: string]]
  runtime*, defines*: seq[string]

proc vendor*(): string =
  let configured = getEnv("FOO_VENDOR_ROOT")
  if configured.len > 0:
    if not fileExists(configured / "manifest.json"):
      raise newException(IOError, "FOO_VENDOR_ROOT lacks manifest.json: " & configured)
    return absolutePath(configured)
  var directory = getAppDir()
  for depth in 0 .. 6:
    if fileExists(directory / "vendor" / "manifest.json"):
      return directory / "vendor"
    directory = parentDir(directory)
  let fallback = currentSourcePath().parentDir.parentDir.parentDir / "vendor"
  if fileExists(fallback / "manifest.json"): return fallback
  raise newException(IOError, "Controlled vendor inputs missing; install the complete FOO release or set FOO_VENDOR_ROOT")

proc verified*(relative: string): string =
  let root = vendor()
  let manifest = parseFile(root / "manifest.json")
  if not manifest["files"].hasKey(relative):
    raise newException(IOError, "Unapproved vendor input: " & relative)
  result = root / relative
  if not fileExists(result) or digest(readFile(result)) != manifest["files"][relative].getStr():
    raise newException(IOError, "Vendor checksum mismatch or missing file: " & relative)

proc container*(relative: string): string =
  let manifest = parseFile(vendor() / "manifest.json")
  var found = false
  for path, digest in manifest["files"]:
    if path.startsWith(relative & "/"):
      if not fileExists(vendor() / path) or digest(readFile(vendor() / path)) != digest.getStr():
        raise newException(IOError, "Vendor checksum mismatch or missing file: " & path)
      found = true
  if not found: raise newException(IOError, "Unapproved vendor directory: " & relative)
  vendor() / relative

proc identity*(): string =
  let root = vendor()
  let contents = readFile(root / "manifest.json")
  let document = parseJson(contents)
  for path, digest in document["files"]:
    if not fileExists(root / path) or digest(readFile(root / path)) != digest.getStr():
      raise newException(IOError, "Vendor cache input changed or missing: " & path)
  result = digest(contents)
  # External build records participate in cache identity; all inputs are
  # separately checked before compilation, including their artifact digests.
  if not dirExists(root.parentDir / ".artifacts" / "vendor"): return
  var records: seq[string]
  for kind, path in walkDir(root.parentDir / ".artifacts" / "vendor"):
    if kind != pcDir or not fileExists(path / "provenance.json"): continue
    let name = path.lastPathPart
    when defined(windows):
      if name.startsWith("linux-"): continue
    elif defined(linux):
      if name.startsWith("linux-musl-"): continue
    records.add(path / "provenance.json")
  records.sort()
  for path in records:
    let contents = readFile(path)
    let record = parseJson(contents)
    if record["vendorIdentity"].getStr() != digest(readFile(root / "manifest.json")):
      raise newException(IOError, "Native build record does not match vendor lock: " & path)
    for name, digest in record["files"]:
      if isAbsolute(name) or ".." in name.split('/'):
        raise newException(IOError, "Unsafe native artifact path")
      let artifact = path.parentDir / name
      if not fileExists(artifact) or digest(readFile(artifact)) != digest.getStr():
        raise newException(IOError, "Native cache input checksum mismatch: " & name)
    result.add(digest(contents))

proc muslidentity*(target: string): string =
  let key = if target.contains("aarch64"): "linux-musl-arm64" else: "linux-musl-x64"
  let record = vendor().parentDir / ".artifacts" / "vendor" / key / "provenance.json"
  digest(readFile(vendor() / "manifest.json") & key &
    (if fileExists(record): readFile(record) else: "not provisioned"))

proc prepare*(libs, paths: seq[string]; compiler, target: string;
    progress: Observer = nil): Supply =
  if libs.len == 0: return
  let selected = target.toLowerAscii()
  let windows = if selected.len > 0: "windows" in selected or "win32" in selected else: defined(windows)
  let linux = if selected.len > 0: "linux" in selected else: defined(linux)
  let x64 = if selected.len > 0: "x86_64" in selected or "amd64" in selected or "x64" in selected else: defined(amd64)
  let arm64 = if selected.len > 0: "aarch64" in selected or "arm64" in selected else: defined(arm64)
  for name in libs:
    case name
    of "sodium", "z":
      if windows and x64:
        let dep = if name == "sodium": "libsodium" else: "zlib"
        result.headers.add(container(dep & "/windows-x64/include"))
        let archive = if name == "sodium": "libsodium.lib" else: "zlib.lib"
        result.links.add((name, verified(dep & "/windows-x64/" & archive)))
        if name == "sodium": result.defines.add("SODIUM_STATIC=1")
      elif linux and (x64 or arm64):
        let musl = selected.contains("musl")
        let key = (if musl: "linux-musl-" else: "linux-") &
          (if x64: "x64" else: "arm64")
        let root = vendor().parentDir / ".artifacts" / "vendor" / key
        let record = root / "provenance.json"
        if not fileExists(record):
          raise newException(IOError, "Missing controlled native artifacts for " & key & "; explicitly run node tools/vendor/build.mjs --target " & key & " on that target. Normal builds never download/install dependencies.")
        let document = parseFile(record)
        if document["target"].getStr() != key or document["vendorIdentity"].getStr() != digest(readFile(vendor() / "manifest.json")):
          raise newException(IOError, "Native artifacts do not match target/vendor lock; rebuild " & key)
        if musl and not document["compilerTarget"].getStr().endsWith("-linux-musl"):
          raise newException(IOError, "Native musl artifacts require a musl compiler target: " & key)
        for path, digest in document["files"]:
          if isAbsolute(path) or ".." in path.split('/'): raise newException(IOError, "Unsafe native artifact path")
          if not fileExists(root / path) or digest(readFile(root / path)) != digest.getStr():
            raise newException(IOError, "Native artifact checksum mismatch: " & path)
        let dep = if name == "sodium": "libsodium" else: "zlib"
        let archive = dep & "/lib/" & (if name == "sodium": "libsodium.a" else: "libz.a")
        let header = dep & "/include/" & (if name == "sodium": "sodium.h" else: "zlib.h")
        if not document["files"].hasKey(archive) or not document["files"].hasKey(header):
          raise newException(IOError, "Native build record omits required archive/header: " & dep)
        result.headers.add(root / dep / "include")
        result.links.add((name, root / dep / "lib" / (if name == "sodium": "libsodium.a" else: "libz.a")))
      else:
        raise newException(IOError, "No qualified controlled " & name & " artifact for target '" & target & "'; Windows ARM, macOS, WASI and freestanding are not qualified")
    of "curl":
      if not linux:
        raise newException(IOError, "OS-linked libcurl is currently qualified for Linux only")
      result.headers.add(container("curl/include"))
      if selected.contains("musl"):
        let key = "linux-musl-" & (if x64: "x64" else: "arm64")
        let root = vendor().parentDir / ".artifacts" / "vendor" / key
        let record = root / "provenance.json"
        if not fileExists(record):
          raise newException(IOError, "Missing controlled native artifacts for " & key)
        let document = parseFile(record)
        if document["target"].getStr() != key or
            document["vendorIdentity"].getStr() != digest(readFile(vendor() / "manifest.json")) or
            not document["compilerTarget"].getStr().startsWith(
              (if x64: "x86_64-" else: "aarch64-")) or
            not document["compilerTarget"].getStr().endsWith("-linux-musl"):
          raise newException(IOError, "Native curl archive does not match target/vendor lock")
        for path, expected in document["files"]:
          if isAbsolute(path) or ".." in path.split('/') or
              not fileExists(root / path) or
              digest(readFile(root / path)) != expected.getStr():
            raise newException(IOError, "Native artifact checksum mismatch: " & path)
        let archive = "curl/lib/libcurl.a"
        if not document["files"].hasKey(archive):
          raise newException(IOError, "Missing controlled musl curl archive; run node tools/vendor/curl.mjs --target " & key & " --archive <curl source archive>")
        var recipe = newJNull()
        for item in document["recipes"]:
          if item["dependency"].getStr() == "curl": recipe = item
        if recipe.kind != JObject or not recipe.hasKey("archiveSha256") or
            not recipe.hasKey("tlsBackend") or recipe["archiveSha256"].getStr() !=
            document["files"][archive].getStr():
          raise newException(IOError, "Native curl archive lacks matching build provenance")
        result.links.add((name, root / archive))
        if recipe["tlsBackend"].getStr() == "openssl-static":
          let lock = parseFile(vendor() / "openssl-musl.json")
          let expected = lock["targets"][key]
          if recipe["opensslLockIdentity"].getStr() !=
              digest(readFile(vendor() / "openssl-musl.json")) or
              recipe["opensslDevSha256"].getStr() != expected["devSha256"].getStr() or
              recipe["opensslStaticSha256"].getStr() != expected["staticSha256"].getStr():
            raise newException(IOError, "Native curl OpenSSL inputs do not match the target lock")
          for dep in ["ssl", "crypto"]:
            let relative = "curl/lib/lib" & dep & ".a"
            if not document["files"].hasKey(relative):
              raise newException(IOError, "Native curl OpenSSL archive missing: " & relative)
            result.links.add((dep, root / relative))
        elif recipe["tlsBackend"].getStr() == "none":
          result.defines.add("FOO_HTTP_NO_HTTPS=1")
        else:
          raise newException(IOError, "Unsupported native curl TLS backend")
      # Other Linux targets retain the OS-owned TLS/CA-store integration.
    else: discard

proc requirements*(artifact, target, compiler, vendorIdentity: string; libraries: seq[string];
    providers: seq[string] = @[]; inspectorOverride = "") =
  let windows = if target.len > 0: "windows" in target else: defined(windows)
  let macos = if target.len > 0: "darwin" in target or "macos" in target else: defined(macosx)
  let wasm = "wasm" in target or "wasi" in target
  let label = if windows: "dumpbin.exe" elif wasm: "wasm-objdump"
    elif macos: "otool" else: "readelf"
  let inspector = if inspectorOverride.len > 0: inspectorOverride else: findExe(label)
  if inspector.len == 0:
    raise newException(IOError, "Runtime/architecture audit requires " & label &
      "; install it with the selected toolchain or set an inspector override.")
  let flags = if windows: " /headers /imports "
    elif wasm: " -x " elif macos: " -hv -L " else: " -h -d "
  let checked = execCmdEx(quoteShell(inspector) & flags & quoteShell(artifact))
  if checked.exitCode != 0:
    raise newException(IOError, "Runtime/architecture audit requires " & label &
      " at " & inspector & ": " & checked.output)
  writeFile(artifact & ".dependencies.json", pretty(%*{
    "format": "foo.runtime-requirements", "version": 1, "target": target,
    "compilerFrontend": compiler, "vendorIdentity": vendorIdentity,
    "linkedLibraries": libraries, "optionalRuntimeProviders": providers,
    "inspectionTool": inspector, "inspection": checked.output}) & "\n")
