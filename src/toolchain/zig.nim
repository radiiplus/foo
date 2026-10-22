## Explicit Zig cross-toolchain helper; QBE remains the FOO code generator.
import std/[json, os, osproc, sequtils, strutils, times]
when not defined(windows): import std/httpclient
import ../pkg/hash

when defined(windows):
  type Session = pointer
  const
    Proxy = 4'u32
    Secure = 0x00800000'u32
    Status = 19'u32
    Numeric = 0x20000000'u32
  proc open(agent: WideCString; representation: uint32;
      proxy, bypass: WideCString; flags: uint32): Session
      {.stdcall, dynlib: "winhttp.dll", importc: "WinHttpOpen".}
  proc connect(session: Session; server: WideCString; port: uint16;
      reserved: uint32): Session
      {.stdcall, dynlib: "winhttp.dll", importc: "WinHttpConnect".}
  proc request(connection: Session; verb, path, version,
      referrer: WideCString; types: pointer; flags: uint32): Session
      {.stdcall, dynlib: "winhttp.dll", importc: "WinHttpOpenRequest".}
  proc send(request: Session; headers: WideCString;
      header: uint32; optional: pointer; optionalLength, amount: uint32;
      context: uint): int32
      {.stdcall, dynlib: "winhttp.dll", importc: "WinHttpSendRequest".}
  proc receive(request: Session; reserved: pointer): int32
      {.stdcall, dynlib: "winhttp.dll", importc: "WinHttpReceiveResponse".}
  proc headers(request: Session; info: uint32;
      name: WideCString; buffer: pointer; length: ptr uint32;
      index: ptr uint32): int32
      {.stdcall, dynlib: "winhttp.dll", importc: "WinHttpQueryHeaders".}
  proc read(request: Session; buffer: pointer; payload: uint32;
      bytes: ptr uint32): int32
      {.stdcall, dynlib: "winhttp.dll", importc: "WinHttpReadData".}
  proc close(handle: Session): int32
      {.stdcall, dynlib: "winhttp.dll", importc: "WinHttpCloseHandle".}

type Info* = object
  version*: string
  path*: string
type Listener* = proc(phase, name, detail: string) {.closure.}

const version* = "0.16.0"
const hardware* = "Hardware-level projects on Windows require WSL 2."
let levels* = ["base", "system", "machine", "hardware"]

proc directory*(): string =
  let home = getEnv("FOO_HOME")
  if home.len > 0: home / ".artifacts" / "toolchain"
  else: getHomeDir() / ".foo" / "toolchains"

proc bundled(): string =
  parentDir(getAppDir()) / ".artifacts" / "toolchain"

proc verify*(path: string; expected = version): bool =
  if not fileExists(path): return false
  try:
    let response = execCmdEx(quoteShell(path) & " version")
    response.exitCode == 0 and response.output.strip().splitLines()[0] == expected
  except CatchableError:
    false

proc detect*(expected = version): Info =
  if expected != version: return Info()
  let executable = when defined(windows): "zig.exe" else: "zig"
  var candidates = @[
    bundled() / expected / executable,
    directory() / expected / executable
  ]
  if getEnv("FOO_HOME").len == 0:
    let home = getHomeDir()
    candidates.add(home / ".foo" / "toolchains" / expected / executable)
    candidates.add(home / ".tratio" / "toolchains" / expected / executable)
  for candidate in candidates:
    if verify(candidate, expected): return Info(version: expected, path: absolutePath(candidate))

proc list*(): seq[string] =
  let root = directory()
  if not dirExists(root): return @[]
  for kind, path in walkDir(root):
    if kind == pcDir and path.lastPathPart.len > 0 and path.lastPathPart[0].isDigit:
      if detect(path.lastPathPart).path.len > 0: result.add(path.lastPathPart)

proc pin*(project = getCurrentDir()): string =
  let current = project / "foo.ivl"
  if not fileExists(current): return version
  let selected = parseJson(readFile(current)).getOrDefault("zig").getStr()
  if selected.len == 0: return version
  if selected != version:
    raise newException(ValueError, "This FOO compiler requires Zig " & version & "; project foo.ivl requests " & selected & ".")
  selected

proc size*(release: JsonNode): int =
  let value = release.getOrDefault("size")
  try:
    case value.kind
    of JInt: result = int(value.getInt())
    of JString: result = parseInt(value.getStr())
    else: discard
  except ValueError, OverflowDefect:
    discard
  if result <= 0 or result > 512 * 1024 * 1024:
    raise newException(ValueError, "Invalid Zig release size")

proc valid(value: string): bool =
  if value.len != 64: return false
  for character in value:
    if character notin {'0'..'9', 'a'..'f'}: return false
  true

proc size*(value: BiggestInt): string =
  if value < 1024: $value & " B"
  elif value < 1024 * 1024:
    formatFloat(value.float / 1024, ffDecimal, 1) & " KiB"
  elif value < 1024 * 1024 * 1024:
    formatFloat(value.float / (1024 * 1024), ffDecimal, 1) & " MiB"
  else:
    formatFloat(value.float / (1024 * 1024 * 1024), ffDecimal, 1) & " GiB"

proc meter*(downloaded, total, speed: BiggestInt): string =
  let percent = if total > 0: min(100, int(downloaded * 100 div total)) else: 0
  "Downloaded " & size(downloaded) & " / " & size(total) &
    " (" & $percent & "%) at " & size(speed) & "/s"

proc stage(message: string) =
  stderr.writeLine("  " & message)
  stderr.flushFile()

proc emit(progress: Listener; phase, name, detail, fallback: string) =
  if progress != nil: progress(phase, name, detail)
  else: stage(fallback)

when defined(windows):
  proc download(url, destination: string; capacity = 0;
      progress: Listener = nil): string =
    const origin = "https://ziglang.org"
    if not url.startsWith(origin & "/"):
      raise newException(ValueError, "Unexpected Zig download URL")
    let agent = newWideCString("FOO/1")
    let server = newWideCString("ziglang.org")
    let verb = newWideCString("GET")
    let path = newWideCString(url[origin.len .. ^1])
    let session = open(agent,
      Proxy, nil, nil, 0)
    if session == nil: raise newException(IOError, "Unable to open Windows HTTPS session")
    defer: discard close(session)
    let connection = connect(session, server, 443, 0)
    if connection == nil: raise newException(IOError, "Unable to connect to ziglang.org")
    defer: discard close(connection)
    let request = request(connection, verb, path, nil, nil, nil,
      Secure)
    if request == nil: raise newException(IOError, "Unable to create Windows HTTPS request")
    defer: discard close(request)
    if send(request, nil, 0, nil, 0, 0, 0) == 0 or
        receive(request, nil) == 0:
      raise newException(IOError, "Unable to download from ziglang.org")
    var status, width: uint32
    width = uint32(sizeof(status))
    if headers(request, Status or
        Numeric, nil, addr status, addr width, nil) == 0 or
        status != 200:
      raise newException(IOError, "Toolchain download returned HTTP " & $status)
    var output: File
    if destination.len > 0 and not open(output, destination, fmWrite):
      raise newException(IOError, "Unable to create toolchain archive: " & destination)
    defer:
      if destination.len > 0: output.close()
    var buffer: array[64 * 1024, byte]
    var downloaded: BiggestInt
    let started = epochTime()
    var report = started
    while true:
      var count: uint32
      if read(request, addr buffer[0], uint32(buffer.len), addr count) == 0:
        raise newException(IOError, "Unable to read toolchain download")
      if count == 0: break
      if destination.len > 0:
        if output.writeBuffer(addr buffer[0], int(count)) != int(count):
          raise newException(IOError, "Unable to write toolchain archive")
      else:
        let offset = result.len
        result.setLen(offset + int(count))
        copyMem(addr result[offset], addr buffer[0], int(count))
      downloaded.inc(BiggestInt(count))
      if capacity > 0 and downloaded > BiggestInt(capacity):
        raise newException(ValueError, "Toolchain archive exceeds its declared size")
      let now = epochTime()
      if progress != nil and now - report >= 1:
        let speed = BiggestInt(downloaded.float / max(0.001, now - started))
        progress("download", "compiler", meter(downloaded,
          BiggestInt(capacity), speed))
        report = now

proc install*(expected = version; progress: Listener = nil): Info =
  if expected != version: raise newException(ValueError, "Unsupported external Zig cross-toolchain version '" & expected & "'.")
  let existing = detect(expected)
  if existing.path.len > 0:
    if progress != nil: progress("ready", "compiler", "already installed")
    return existing
  if getEnv("FOO_OFFLINE") == "1":
    raise newException(IOError, "Offline mode forbids toolchain downloads; bootstrap explicitly first")
  let address = "https://ziglang.org/download/index.json"
  let key = when defined(windows): "x86_64-windows" elif defined(macosx): "aarch64-macos" elif defined(arm64): "aarch64-linux" else: "x86_64-linux"
  emit(progress, "resolve", "compiler", key,
    "Resolving Zig " & expected & " for " & key)
  let index = when defined(windows):
      parseJson(download(address, ""))
    else:
      let client = newHttpClient(timeout = 300000)
      defer: client.close()
      let response = client.get(address)
      if response.code.int != 200:
        raise newException(IOError, "Unable to download Zig release index (" &
          $response.code & ")")
      parseJson(response.body)
  if not index.hasKey(expected) or not index[expected].hasKey(key):
    raise newException(IOError, "Zig " & expected & " has no release for " & key)
  let release = index[expected][key]
  let endpoint = release["tarball"].getStr()
  if not endpoint.startsWith("https://ziglang.org/"):
    raise newException(ValueError, "Unexpected Zig download URL")
  let fingerprint = release.getOrDefault("shasum").getStr().toLowerAscii()
  if not valid(fingerprint):
    raise newException(ValueError, "Invalid Zig release checksum")
  let capacity = size(release)
  let cache = directory()
  createDir(cache)
  let stamp = $int(epochTime())
  let location = cache / ("zig-" & expected & "-" & stamp & ".archive")
  let unpacked = cache / (".extract-" & stamp)
  emit(progress, "destination", "cache", cache, "Destination " & cache)
  emit(progress, "download", "compiler", size(capacity),
    "Downloading " & size(capacity) & " from ziglang.org")
  try:
    when defined(windows):
      discard download(endpoint, location, capacity, progress)
    else:
      let client = newHttpClient(timeout = 300000)
      defer: client.close()
      client.onProgressChanged = proc(total, downloaded, speed: BiggestInt) {.gcsafe.} =
        let size = if total > 0: total else: BiggestInt(capacity)
        {.cast(gcsafe).}:
          emit(progress, "download", "compiler", meter(downloaded, size, speed),
            meter(downloaded, size, speed))
      client.downloadFile(endpoint, location)
  except CatchableError as error:
    raise newException(IOError, "Unable to download Zig " & expected & ": " & error.msg)
  let extent = getFileSize(location)
  emit(progress, "downloaded", "compiler", size(extent),
    "Downloaded " & size(extent) & " / " &
      size(capacity) & " (100%)")
  if extent != capacity:
    raise newException(ValueError, "Zig archive size mismatch: expected " &
      $capacity & " bytes, received " & $extent)
  emit(progress, "verify", "package checksum", "SHA-256",
    "Verifying SHA-256 checksum")
  if digest(readFile(location)).toLowerAscii() != fingerprint:
    raise newException(ValueError, "Zig archive checksum mismatch")
  if progress != nil: progress("verified", "package checksum", "SHA-256")
  createDir(unpacked)
  emit(progress, "verify", "archive paths", "safe extraction",
    "Inspecting archive paths")
  let listing = execCmdEx("tar -tf " & quoteShell(location)).output
  for entry in listing.splitLines:
    let clean = entry.strip().replace('\\', '/')
    if clean.len == 0: continue
    if clean.startsWith("/") or clean.split('/').anyIt(it == ".."):
      raise newException(ValueError, "Unsafe Zig archive path")
  if progress != nil: progress("verified", "archive paths", "safe extraction")
  emit(progress, "extract", "compiler", expected, "Extracting Zig " & expected)
  let unpack = execCmdEx("tar -xf " & quoteShell(location) & " -C " & quoteShell(unpacked))
  if unpack.exitCode != 0: raise newException(IOError, "Unable to extract Zig archive: " & unpack.output)
  let executable = when defined(windows): "zig.exe" else: "zig"
  let roots = toSeq(walkDir(unpacked)).filterIt(it.kind == pcDir).mapIt(it.path)
  if roots.len != 1 or not fileExists(roots[0] / executable):
    raise newException(IOError, "Unexpected Zig archive layout")
  let directory = roots[0]
  let target = cache / expected
  emit(progress, "install", "compiler", expected, "Installing Zig " & expected)
  if dirExists(target): removeDir(target)
  copyDir(directory, target)
  let installed = target / executable
  when not defined(windows):
    setFilePermissions(installed, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  removeFile(location)
  removeDir(unpacked)
  emit(progress, "verify", "installed compiler", expected,
    "Verifying installed executable")
  if not verify(installed, expected): raise newException(IOError, "Installed Zig failed version verification")
  if progress != nil: progress("verified", "installed compiler", expected)
  emit(progress, "ready", "compiler", expected,
    "Ready Zig " & expected & " at " & absolutePath(installed))
  Info(version: expected, path: absolutePath(installed))

proc require*(expected = version): Info =
  result = detect(expected)
  if result.path.len == 0:
    raise newException(IOError, "Missing pinned external Zig cross-toolchain " & expected & "; provision it explicitly. Normal builds are offline.")

proc ensure*(level: string) =
  if level notin levels: raise newException(ValueError, "Unknown capability '" & level & "'")
  if level == "base": return
  if level == "hardware" and defined(windows): raise newException(ValueError, hardware)
