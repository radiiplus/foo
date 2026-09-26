import std/[httpclient, json, os, osproc, sequtils, strutils, times]
import ../pkg/hash

type Info* = object
  version*: string
  path*: string

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

proc install*(expected = version): Info =
  if expected != version: raise newException(ValueError, "Unsupported backend version '" & expected & "'.")
  let existing = detect(expected)
  if existing.path.len > 0: return existing
  let indexUrl = "https://ziglang.org/download/index.json"
  let hostKey = when defined(windows): "x86_64-windows" elif defined(macosx): "aarch64-macos" elif defined(arm64): "aarch64-linux" else: "x86_64-linux"
  stderr.writeLine("FOO toolchain")
  stage("Resolving Zig " & expected & " for " & hostKey)
  let client = newHttpClient(timeout = 300000)
  defer: client.close()
  let indexResponse = client.get(indexUrl)
  if indexResponse.code.int != 200: raise newException(IOError, "Unable to download Zig release index (" & $indexResponse.code & ")")
  let index = parseJson(indexResponse.body)
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
  stage("Destination " & cache)
  stage("Downloading " & formatBytes(expectedSize) & " from ziglang.org")
  client.onProgressChanged = proc(total, downloaded, speed: BiggestInt) {.gcsafe.} =
    let size = if total > 0: total else: BiggestInt(expectedSize)
    stage(progressLine(downloaded, size, speed))
  try:
    client.downloadFile(archiveUrl, archivePath)
  except CatchableError as error:
    raise newException(IOError, "Unable to download Zig " & expected & ": " & error.msg)
  client.onProgressChanged = nil
  let downloadedSize = getFileSize(archivePath)
  stage("Downloaded " & formatBytes(downloadedSize) & " / " &
    formatBytes(expectedSize) & " (100%)")
  if downloadedSize != expectedSize:
    raise newException(ValueError, "Zig archive size mismatch: expected " &
      $expectedSize & " bytes, received " & $downloadedSize)
  stage("Verifying SHA-256 checksum")
  if sha256Hex(readFile(archivePath)).toLowerAscii() != expectedHash:
    raise newException(ValueError, "Zig archive checksum mismatch")
  createDir(unpacked)
  stage("Inspecting archive paths")
  let listing = execCmdEx("tar -tf " & quoteShell(archivePath)).output
  for entry in listing.splitLines:
    let clean = entry.strip().replace('\\', '/')
    if clean.len == 0: continue
    if clean.startsWith("/") or clean.split('/').anyIt(it == ".."):
      raise newException(ValueError, "Unsafe Zig archive path")
  stage("Extracting Zig " & expected)
  let unpack = execCmdEx("tar -xf " & quoteShell(archivePath) & " -C " & quoteShell(unpacked))
  if unpack.exitCode != 0: raise newException(IOError, "Unable to extract Zig archive: " & unpack.output)
  let executable = when defined(windows): "zig.exe" else: "zig"
  let roots = toSeq(walkDir(unpacked)).filterIt(it.kind == pcDir).mapIt(it.path)
  if roots.len != 1 or not fileExists(roots[0] / executable):
    raise newException(IOError, "Unexpected Zig archive layout")
  let sourceRoot = roots[0]
  let targetRoot = cache / expected
  stage("Installing Zig " & expected)
  if dirExists(targetRoot): removeDir(targetRoot)
  copyDir(sourceRoot, targetRoot)
  let installed = targetRoot / executable
  when not defined(windows):
    setFilePermissions(installed, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  removeFile(archivePath)
  removeDir(unpacked)
  stage("Verifying installed executable")
  if not verify(installed, expected): raise newException(IOError, "Installed Zig failed version verification")
  stage("Ready Zig " & expected & " at " & absolutePath(installed))
  Info(version: expected, path: absolutePath(installed))

proc ensure*(level: string) =
  if level notin levels: raise newException(ValueError, "Unknown capability '" & level & "'")
  if level == "base": return
  if level == "hardware" and defined(windows): raise newException(ValueError, hardware)
  discard install()
