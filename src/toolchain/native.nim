import ../build/options

type Supply* = object
  headers*: seq[string]
  links*: seq[tuple[name: string, path: string]]
  runtime*: seq[string]

when defined(linux):
  import std/[os, osproc, strutils]
  import ../pkg/hash
  import ./manager

  proc distro(): string =
    if not fileExists("/etc/os-release"): return
    var id: string
    var version: string
    for line in readFile("/etc/os-release").splitLines:
      if line.startsWith("ID="): id = line[3 .. ^1].strip(chars = {'\"'})
      if line.startsWith("VERSION_ID="):
        version = line[11 .. ^1].strip(chars = {'\"'})
    if id in ["ubuntu", "debian"]: result = id & "-" & version

  proc candidate(name: string): string =
    let checked = execCmdEx("apt-cache policy " & quoteShell(name))
    if checked.exitCode != 0: return
    for line in checked.output.splitLines:
      let clean = line.strip()
      if clean.startsWith("Candidate: "):
        result = clean[11 .. ^1].strip()
        if result == "(none)": result = ""
        return

  proc fetch(name, version, root: string; progress: BuildProgress) =
    if progress != nil: progress("download", name, "native dependency", false)
    let downloaded = execCmdEx("apt-get download " &
      quoteShell(name & "=" & version), workingDir = root)
    if downloaded.exitCode != 0:
      raise newException(IOError, "Unable to provision " & name & ": " & downloaded.output)
    var archive: string
    for path in walkFiles(root / "*.deb"):
      if path.lastPathPart.startsWith(name & "_"):
        archive = path
        break
    if archive.len == 0:
      raise newException(IOError, "The " & name & " download did not contain a Debian package.")
    let extracted = execCmdEx("dpkg-deb -x " & quoteShell(archive) & " " & quoteShell(root))
    if extracted.exitCode != 0:
      raise newException(IOError, "Unable to extract " & name & ": " & extracted.output)
    removeFile(archive)
    if progress != nil: progress("downloaded", name, "native dependency", false)

  proc runtime(): string =
    let checked = execCmdEx("apt-cache depends libcurl4-openssl-dev")
    if checked.exitCode != 0: return
    for line in checked.output.splitLines:
      let clean = line.strip()
      if clean.startsWith("Depends: libcurl") and not clean.endsWith("-dev"):
        return clean[9 .. ^1].strip()

  proc probe(compiler, name, header: string; paths: seq[string]): bool =
    var command = quoteShell(compiler)
    if splitFile(compiler).name.toLowerAscii() == "zig": command.add(" cc")
    command.add(" -x c - -o /dev/null")
    for path in paths: command.add(" -I " & quoteShell(path))
    command.add(" -l" & quoteShell(name))
    try:
      let checked = execCmdEx(command,
        input = "#include <" & header & ">\nint main(void) { return 0; }\n")
      checked.exitCode == 0
    except CatchableError:
      false

proc prepare*(libs, paths: seq[string]; compiler, target: string;
    progress: BuildProgress = nil): Supply =
  when defined(linux):
    if target.len > 0 and (not target.contains("linux") or
        (defined(amd64) and not target.contains("x86_64")) or
        (defined(arm64) and not target.contains("aarch64"))): return
    if findExe("apt-get").len == 0 or findExe("dpkg-deb").len == 0 or
        findExe("apt-cache").len == 0: return
    let system = distro()
    if not (system.startsWith("ubuntu-") or system.startsWith("debian-")): return
    let arch = execCmdEx("dpkg --print-architecture")
    if arch.exitCode != 0: return
    let multi = case arch.output.strip()
      of "amd64": "x86_64-linux-gnu"
      of "arm64": "aarch64-linux-gnu"
      else: return
    for name in libs:
      let package = case name
        of "sodium": "libsodium-dev"
        of "z": "zlib1g-dev"
        of "curl": "libcurl4-openssl-dev"
        else: continue
      let header = case name
        of "sodium": "sodium.h"
        of "z": "zlib.h"
        else: "curl/curl.h"
      if probe(compiler, name, header, paths): continue
      let version = candidate(package)
      if version.len == 0:
        raise newException(IOError, "No apt candidate for " & package & ". Update apt package lists or install it manually.")
      let dependency = if name == "curl": runtime() else: ""
      if name == "curl" and dependency.len == 0:
        raise newException(IOError, "Unable to find libcurl's runtime package in apt metadata.")
      let revision = if dependency.len > 0: candidate(dependency) else: ""
      if dependency.len > 0 and revision.len == 0:
        raise newException(IOError, "No apt candidate for " & dependency &
          ". Update apt package lists or install it manually.")
      let stamp = sha256Hex(package & version & dependency & revision)[0 .. 15]
      let root = directory() / "native" / system / arch.output.strip() / name / stamp
      let marker = root / ".ready"
      let folder = root / "usr" / "lib" / multi
      let library = folder / ("lib" & name & (if name == "curl": ".so" else: ".a"))
      let location = root / "usr" / "include" /
        (if name == "curl": multi else: "")
      if not fileExists(marker) or not fileExists(library) or
          not fileExists(location / header):
        createDir(root)
        fetch(package, version, root, progress)
        if dependency.len > 0: fetch(dependency, revision, root, progress)
        if not fileExists(library) or not fileExists(location / header):
          raise newException(IOError, "The " & package & " package lacks " & header &
            " or lib" & name & ".")
        writeFile(marker, version & "\n" & revision & "\n")
      result.headers.add(location)
      result.links.add((name, library))
      if name == "curl":
        let shared = folder / "libcurl.so.4"
        if not fileExists(shared):
          raise newException(IOError, "The libcurl runtime package lacks libcurl.so.4.")
        result.runtime.add(shared)
