import std/[httpclient, json, os, osproc, sequtils, strutils, tables, times]
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
  else: getCurrentDir() / ".artifacts" / "toolchain"

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
  var candidates = @[directory() / expected / executable]
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

proc install*(expected = version): Info =
  if expected != version: raise newException(ValueError, "Unsupported backend version '" & expected & "'.")
  let existing = detect(expected)
  if existing.path.len > 0: return existing
  let indexUrl = "https://ziglang.org/download/index.json"
  let hostKey = when defined(windows): "x86_64-windows" elif defined(macosx): "aarch64-macos" elif defined(arm64): "aarch64-linux" else: "x86_64-linux"
  let client = newHttpClient(timeout = 30000)
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
  let expectedSize = release.getOrDefault("size").getInt()
  if expectedSize <= 0 or expectedSize > 512 * 1024 * 1024: raise newException(ValueError, "Invalid Zig release size")
  let archive = client.get(archiveUrl)
  if archive.code.int != 200: raise newException(IOError, "Unable to download Zig " & expected)
  if archive.body.len != expectedSize: raise newException(ValueError, "Zig archive size mismatch")
  if sha256Hex(archive.body).toLowerAscii() != expectedHash: raise newException(ValueError, "Zig archive checksum mismatch")
  let cache = directory()
  createDir(cache)
  let stamp = $int(epochTime())
  let archivePath = cache / ("zig-" & expected & "-" & stamp & ".archive")
  let unpacked = cache / (".extract-" & stamp)
  writeFile(archivePath, archive.body)
  createDir(unpacked)
  let listing = execCmdEx("tar -tf " & quoteShell(archivePath)).output
  for entry in listing.splitLines:
    let clean = entry.strip().replace('\\', '/')
    if clean.len == 0 or clean.startsWith("/") or clean.split('/').anyIt(it == ".."):
      raise newException(ValueError, "Unsafe Zig archive path")
  let unpack = execCmdEx("tar -xf " & quoteShell(archivePath) & " -C " & quoteShell(unpacked))
  if unpack.exitCode != 0: raise newException(IOError, "Unable to extract Zig archive: " & unpack.output)
  let executable = when defined(windows): "zig.exe" else: "zig"
  var found = ""
  for path in walkDirRec(unpacked):
    if path.lastPathPart == executable:
      found = path
      break
  if found.len == 0: raise newException(IOError, "Zig archive did not contain " & executable)
  let sourceRoot = parentDir(found)
  let targetRoot = cache / expected
  if dirExists(targetRoot): removeDir(targetRoot)
  copyDir(sourceRoot, targetRoot)
  removeFile(archivePath)
  removeDir(unpacked)
  let installed = targetRoot / executable
  if not verify(installed, expected): raise newException(IOError, "Installed Zig failed version verification")
  Info(version: expected, path: absolutePath(installed))

proc ensure*(level: string) =
  if level notin levels: raise newException(ValueError, "Unknown capability '" & level & "'")
  if level == "base": return
  if level == "hardware" and defined(windows): raise newException(ValueError, hardware)
  discard install()
