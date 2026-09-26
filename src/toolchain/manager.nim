import std/[json, os, osproc, sequtils, strutils, times]
when not defined(windows): import std/httpclient
import ../pkg/hash

when defined(windows):
  type HInternet = pointer
  const
    WinHttpAccessTypeAutomaticProxy = 4'u32
    WinHttpFlagSecure = 0x00800000'u32
    WinHttpQueryStatusCode = 19'u32
    WinHttpQueryFlagNumber = 0x20000000'u32
  proc winHttpOpen(agent: WideCString; accessType: uint32;
      proxy, bypass: WideCString; flags: uint32): HInternet
      {.stdcall, dynlib: "winhttp.dll", importc: "WinHttpOpen".}
  proc winHttpConnect(session: HInternet; server: WideCString; port: uint16;
      reserved: uint32): HInternet
      {.stdcall, dynlib: "winhttp.dll", importc: "WinHttpConnect".}
  proc winHttpOpenRequest(connection: HInternet; verb, path, version,
      referrer: WideCString; acceptTypes: pointer; flags: uint32): HInternet
      {.stdcall, dynlib: "winhttp.dll", importc: "WinHttpOpenRequest".}
  proc winHttpSendRequest(request: HInternet; headers: WideCString;
      headerLength: uint32; optional: pointer; optionalLength, totalLength: uint32;
      context: uint): int32
      {.stdcall, dynlib: "winhttp.dll", importc: "WinHttpSendRequest".}
  proc winHttpReceiveResponse(request: HInternet; reserved: pointer): int32
      {.stdcall, dynlib: "winhttp.dll", importc: "WinHttpReceiveResponse".}
  proc winHttpQueryHeaders(request: HInternet; infoLevel: uint32;
      name: WideCString; buffer: pointer; bufferLength: ptr uint32;
      index: ptr uint32): int32
      {.stdcall, dynlib: "winhttp.dll", importc: "WinHttpQueryHeaders".}
  proc winHttpReadData(request: HInternet; buffer: pointer; bytesToRead: uint32;
      bytesRead: ptr uint32): int32
      {.stdcall, dynlib: "winhttp.dll", importc: "WinHttpReadData".}
  proc winHttpCloseHandle(handle: HInternet): int32
      {.stdcall, dynlib: "winhttp.dll", importc: "WinHttpCloseHandle".}

type Info* = object
  version*: string
  path*: string
type ToolchainProgress* = proc(phase, name, detail: string) {.closure.}

const version* = "0.16.0"
const hardware* = "Hardware-level projects on Windows require WSL 2."
let levels* = ["base", "system", "machine", "hardware"]

proc directory*(): string =
  let home = getEnv("FOO_HOME")
  if home.len > 0: home / ".artifacts" / "toolchain"
  else: getHomeDir() / ".foo" / "toolchains"

proc bundledDirectory(): string =
  parentDir(getAppDir()) / ".artifacts" / "toolchain"

proc verify*(path, expected = version): bool =
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
    bundledDirectory() / expected / executable,
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
  let lock = project / "foo.lock"
  if not fileExists(lock): return version
  let selected = parseJson(readFile(lock)).getOrDefault("zig").getStr()
  if selected.len == 0: return version
  if selected != version:
    raise newException(ValueError, "This FOO compiler requires Zig " & version & "; project foo.lock requests " & selected & ".")
  selected

proc releaseSize*(release: JsonNode): int =
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

proc validSha256(value: string): bool =
  if value.len != 64: return false
  for character in value:
    if character notin {'0'..'9', 'a'..'f'}: return false
  true

proc formatBytes*(value: BiggestInt): string =
  if value < 1024: $value & " B"
  elif value < 1024 * 1024:
    formatFloat(value.float / 1024, ffDecimal, 1) & " KiB"
  elif value < 1024 * 1024 * 1024:
    formatFloat(value.float / (1024 * 1024), ffDecimal, 1) & " MiB"
  else:
    formatFloat(value.float / (1024 * 1024 * 1024), ffDecimal, 1) & " GiB"

proc progressLine*(downloaded, total, speed: BiggestInt): string =
  let percent = if total > 0: min(100, int(downloaded * 100 div total)) else: 0
  "Downloaded " & formatBytes(downloaded) & " / " & formatBytes(total) &
    " (" & $percent & "%) at " & formatBytes(speed) & "/s"

proc stage(message: string) =
  stderr.writeLine("  " & message)
  stderr.flushFile()

proc emit(progress: ToolchainProgress; phase, name, detail, fallback: string) =
  if progress != nil: progress(phase, name, detail)
  else: stage(fallback)

when defined(windows):
  proc windowsGet(url, destination: string; expectedSize = 0;
      progress: ToolchainProgress = nil): string =
    const origin = "https://ziglang.org"
    if not url.startsWith(origin & "/"):
      raise newException(ValueError, "Unexpected Zig download URL")
    let agent = newWideCString("FOO/1")
    let server = newWideCString("ziglang.org")
    let verb = newWideCString("GET")
    let path = newWideCString(url[origin.len .. ^1])
    let session = winHttpOpen(agent,
      WinHttpAccessTypeAutomaticProxy, nil, nil, 0)
    if session == nil: raise newException(IOError, "Unable to open Windows HTTPS session")
    defer: discard winHttpCloseHandle(session)
    let connection = winHttpConnect(session, server, 443, 0)
    if connection == nil: raise newException(IOError, "Unable to connect to ziglang.org")
    defer: discard winHttpCloseHandle(connection)
    let request = winHttpOpenRequest(connection, verb, path, nil, nil, nil,
      WinHttpFlagSecure)
    if request == nil: raise newException(IOError, "Unable to create Windows HTTPS request")
    defer: discard winHttpCloseHandle(request)
    if winHttpSendRequest(request, nil, 0, nil, 0, 0, 0) == 0 or
        winHttpReceiveResponse(request, nil) == 0:
      raise newException(IOError, "Unable to download from ziglang.org")
    var status, statusSize: uint32
    statusSize = uint32(sizeof(status))
    if winHttpQueryHeaders(request, WinHttpQueryStatusCode or
        WinHttpQueryFlagNumber, nil, addr status, addr statusSize, nil) == 0 or
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
    var lastReport = started
    while true:
      var count: uint32
      if winHttpReadData(request, addr buffer[0], uint32(buffer.len), addr count) == 0:
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
      if expectedSize > 0 and downloaded > BiggestInt(expectedSize):
        raise newException(ValueError, "Toolchain archive exceeds its declared size")
      let now = epochTime()
      if progress != nil and now - lastReport >= 1:
        let speed = BiggestInt(downloaded.float / max(0.001, now - started))
        progress("download", "compiler", progressLine(downloaded,
          BiggestInt(expectedSize), speed))
        lastReport = now

proc install*(expected = version; progress: ToolchainProgress = nil): Info =
  if expected != version: raise newException(ValueError, "Unsupported backend version '" & expected & "'.")
  let existing = detect(expected)
  if existing.path.len > 0:
    if progress != nil: progress("ready", "compiler", "already installed")
    return existing
  let indexUrl = "https://ziglang.org/download/index.json"
  let hostKey = when defined(windows): "x86_64-windows" elif defined(macosx): "aarch64-macos" elif defined(arm64): "aarch64-linux" else: "x86_64-linux"
  emit(progress, "resolve", "compiler", hostKey,
    "Resolving Zig " & expected & " for " & hostKey)
  let index = when defined(windows):
      parseJson(windowsGet(indexUrl, ""))
    else:
      let client = newHttpClient(timeout = 300000)
      defer: client.close()
      let response = client.get(indexUrl)
      if response.code.int != 200:
        raise newException(IOError, "Unable to download Zig release index (" &
          $response.code & ")")
      parseJson(response.body)
  if not index.hasKey(expected) or not index[expected].hasKey(hostKey):
    raise newException(IOError, "Zig " & expected & " has no release for " & hostKey)
  let release = index[expected][hostKey]
  let archiveUrl = release["tarball"].getStr()
  if not archiveUrl.startsWith("https://ziglang.org/"):
    raise newException(ValueError, "Unexpected Zig download URL")
  let expectedHash = release.getOrDefault("shasum").getStr().toLowerAscii()
  if not validSha256(expectedHash):
    raise newException(ValueError, "Invalid Zig release checksum")
  let expectedSize = releaseSize(release)
  let cache = directory()
  createDir(cache)
  let stamp = $int(epochTime())
  let archivePath = cache / ("zig-" & expected & "-" & stamp & ".archive")
  let unpacked = cache / (".extract-" & stamp)
  emit(progress, "destination", "cache", cache, "Destination " & cache)
  emit(progress, "download", "compiler", formatBytes(expectedSize),
    "Downloading " & formatBytes(expectedSize) & " from ziglang.org")
  try:
    when defined(windows):
      discard windowsGet(archiveUrl, archivePath, expectedSize, progress)
    else:
      let client = newHttpClient(timeout = 300000)
      defer: client.close()
      client.onProgressChanged = proc(total, downloaded, speed: BiggestInt) {.gcsafe.} =
        let size = if total > 0: total else: BiggestInt(expectedSize)
        {.cast(gcsafe).}:
          emit(progress, "download", "compiler", progressLine(downloaded, size, speed),
            progressLine(downloaded, size, speed))
      client.downloadFile(archiveUrl, archivePath)
  except CatchableError as error:
    raise newException(IOError, "Unable to download Zig " & expected & ": " & error.msg)
  let downloadedSize = getFileSize(archivePath)
  emit(progress, "downloaded", "compiler", formatBytes(downloadedSize),
    "Downloaded " & formatBytes(downloadedSize) & " / " &
      formatBytes(expectedSize) & " (100%)")
  if downloadedSize != expectedSize:
    raise newException(ValueError, "Zig archive size mismatch: expected " &
      $expectedSize & " bytes, received " & $downloadedSize)
  emit(progress, "verify", "package checksum", "SHA-256",
    "Verifying SHA-256 checksum")
  if sha256Hex(readFile(archivePath)).toLowerAscii() != expectedHash:
    raise newException(ValueError, "Zig archive checksum mismatch")
  if progress != nil: progress("verified", "package checksum", "SHA-256")
  createDir(unpacked)
  emit(progress, "verify", "archive paths", "safe extraction",
    "Inspecting archive paths")
  let listing = execCmdEx("tar -tf " & quoteShell(archivePath)).output
  for entry in listing.splitLines:
    let clean = entry.strip().replace('\\', '/')
    if clean.len == 0: continue
    if clean.startsWith("/") or clean.split('/').anyIt(it == ".."):
      raise newException(ValueError, "Unsafe Zig archive path")
  if progress != nil: progress("verified", "archive paths", "safe extraction")
  emit(progress, "extract", "compiler", expected, "Extracting Zig " & expected)
  let unpack = execCmdEx("tar -xf " & quoteShell(archivePath) & " -C " & quoteShell(unpacked))
  if unpack.exitCode != 0: raise newException(IOError, "Unable to extract Zig archive: " & unpack.output)
  let executable = when defined(windows): "zig.exe" else: "zig"
  let roots = toSeq(walkDir(unpacked)).filterIt(it.kind == pcDir).mapIt(it.path)
  if roots.len != 1 or not fileExists(roots[0] / executable):
    raise newException(IOError, "Unexpected Zig archive layout")
  let sourceRoot = roots[0]
  let targetRoot = cache / expected
  emit(progress, "install", "compiler", expected, "Installing Zig " & expected)
  if dirExists(targetRoot): removeDir(targetRoot)
  copyDir(sourceRoot, targetRoot)
  let installed = targetRoot / executable
  when not defined(windows):
    setFilePermissions(installed, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  removeFile(archivePath)
  removeDir(unpacked)
  emit(progress, "verify", "installed compiler", expected,
    "Verifying installed executable")
  if not verify(installed, expected): raise newException(IOError, "Installed Zig failed version verification")
  if progress != nil: progress("verified", "installed compiler", expected)
  emit(progress, "ready", "compiler", expected,
    "Ready Zig " & expected & " at " & absolutePath(installed))
  Info(version: expected, path: absolutePath(installed))

proc ensure*(level: string) =
  if level notin levels: raise newException(ValueError, "Unknown capability '" & level & "'")
  if level == "base": return
  if level == "hardware" and defined(windows): raise newException(ValueError, hardware)
  discard install()
