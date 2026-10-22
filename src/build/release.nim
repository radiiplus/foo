import std/[algorithm, json, os, osproc, strutils, tables]
import ./[config, files, project, targets]
import ../pkg/hash

type Bundle* = object
  directory*: string
  artifacts*: seq[string]
  signatures*: seq[string]

proc erase(path: string) =
  if not dirExists(path): return
  for kind, child in walkDir(path):
    if kind == pcDir: erase(child)
    else: removeFile(child)
  removeDir(path)

proc copy(source, target: string) =
  let info = getFileInfo(source, followSymlink = false)
  if info.kind in {pcLinkToDir, pcLinkToFile}:
    raise newException(ValueError,
      "Release files cannot be symbolic links: " & source)
  if info.kind == pcDir:
    if fileExists(target):
      raise newException(ValueError, "Release file conflicts with a staged artifact: " & target)
    createDir(target)
    for _, child in walkDir(source):
      copy(child, target / child.lastPathPart)
  elif info.kind == pcFile:
    if fileExists(target) or dirExists(target):
      raise newException(ValueError, "Release file conflicts with a staged artifact: " & target)
    createDir(parentDir(target))
    copyFileWithPermissions(source, target)
  else:
    raise newException(ValueError, "Unsupported release file: " & source)

proc slug(value: string): string =
  for character in value.toLowerAscii():
    if character.isAlphaNumeric or character in {'-', '_', '.'}:
      result.add(character)
    elif result.len == 0 or result[^1] != '-':
      result.add('-')
  result = result.strip(chars = {'-'})

proc provider(value, target, artifact: string): string =
  if value.len > 0 and value != "auto": return value.toLowerAscii()
  let platform = target.toLowerAscii()
  if platform.contains("windows") or
      artifact.toLowerAscii().endsWith(".exe") or
      artifact.toLowerAscii().endsWith(".dll"):
    return "authenticode"
  if platform.contains("macos") or platform.contains("darwin"):
    return "codesign"
  "gpg"

proc sign*(artifact: string; settings = Signing(); target = "";
    selected = ""): string =
  let path = absolutePath(artifact)
  if not fileExists(path):
    raise newException(IOError, "Artifact to sign not found: " & path)
  let scheme = provider(if selected.len > 0: selected else: settings.provider,
    target, path)
  var command = ""
  case scheme
  of "gpg":
    let data = readFile(path)
    if data.len < 4 or data[0 .. 3] != "\x7fELF":
      raise newException(ValueError,
        "GPG executable signing requires an ELF Linux binary: " & path)
    let signer = getEnv("FOOSIGNER")
    if signer.len == 0:
      raise newException(ValueError,
        "Set FOOSIGNER to the GPG signing-key fingerprint")
    result = path & ".asc"
    command = quoteShell(getEnv("GPG", "gpg")) &
      " --batch --yes --armor --detach-sign --local-user " & quoteShell(signer) &
      " --output " & quoteShell(result) & " " & quoteShell(path)
  of "authenticode":
    if not (path.toLowerAscii().endsWith(".exe") or
        path.toLowerAscii().endsWith(".dll")):
      raise newException(ValueError,
        "Authenticode signing requires a Windows .exe or .dll: " & path)
    let signer = getEnv("FOOSIGNER")
    if signer.len == 0:
      raise newException(ValueError,
        "Set FOOSIGNER to the certificate thumbprint in the Windows certificate store")
    command = quoteShell(getEnv("SIGNTOOL", "signtool")) &
      " sign /fd SHA256 /sha1 " & quoteShell(signer)
    if settings.timestamp.len > 0:
      command.add(" /tr " & quoteShell(settings.timestamp) & " /td SHA256")
    command.add(" " & quoteShell(path))
    result = path
  of "codesign":
    let signer = getEnv("FOOSIGNER")
    if signer.len == 0:
      raise newException(ValueError,
        "Set FOOSIGNER to the macOS signing identity")
    command = quoteShell(getEnv("CODESIGN", "codesign")) &
      " --force --timestamp --sign " & quoteShell(signer) & " " & quoteShell(path)
    result = path
  else:
    raise newException(ValueError,
      "release.sign.provider must be auto, gpg, authenticode, or codesign")
  let response = execCmdEx(command)
  if response.exitCode != 0:
    raise newException(OSError,
      "Signing failed with " & scheme & ".\n" & response.output)

proc collect(root: string): seq[string] =
  proc visit(directory: string; found: var seq[string]) =
    for kind, path in walkDir(directory):
      if kind == pcDir: visit(path, found)
      elif kind == pcFile: found.add(path)
  visit(root, result)
  result.sort()

proc encloses(parent, child: string): bool =
  let relative = relativePath(child, parent)
  relative == "." or relative.len == 0 or
    (not isAbsolute(relative) and relative != ".." and
      not relative.startsWith(".." & DirSep))

proc bundle*(source: Project; signing = false; selected = ""): Bundle =
  let manifest = source.manifest()
  let deployment = manifest.deployment
  if deployment.directory.len == 0:
    raise newException(ValueError,
      "Release support is optional. Add a release section to the project manifest before running foo release")
  let config = source.config()
  var protected = @["src", "test", "benchmark"]
  if manifest.source notin ["", ".", "src"]: protected.add(manifest.source)
  let product = files.destination(source.root, config.output,
    protected)
  protected.add(relativePath(product, source.root))
  let root = files.destination(source.root, deployment.directory,
    protected)
  let target = triple(if source.options.target.len > 0: source.options.target
    else: targets.choose(config.target, host))
  let folder = slug(manifest.name) & "-" & slug(manifest.version) & "-" & slug(target)
  result.directory = root / folder
  let staging = result.directory & ".partial"

  var additions = @[deployment.icon, deployment.license, deployment.readme]
  additions.add(deployment.files)
  for relative in additions:
    if relative.len == 0: continue
    if isAbsolute(relative):
      raise newException(ValueError,
        "Release file paths must be project-relative: " & relative)
    for part in relative.replace('\\', '/').split('/'):
      if part in ["", ".", ".."]:
        raise newException(ValueError,
          "Release file paths must not contain empty, dot or parent components: " & relative)
    let location = confined(source.root, relative)
    if not fileExists(location) and not dirExists(location):
      raise newException(IOError, "Release file not found: " & relative)
    if dirExists(location) and encloses(location, root):
      raise newException(ValueError,
        "Release files cannot contain the release directory: " & relative)
    if relative.toLowerAscii() in ["release.json", "sha256sums"]:
      raise newException(ValueError,
        "Release file conflicts with release metadata: " & relative)

  let artifacts = source.build()
  if dirExists(staging): erase(staging)
  createDir(staging)
  try:
    var copies, seals: seq[string]
    for name, artifact in artifacts:
      let file = staging / artifact.lastPathPart
      copyFileWithPermissions(artifact, file)
      let shared = artifact.parentDir / "libcurl.so.4"
      if fileExists(shared):
        copyFileWithPermissions(shared, staging / shared.lastPathPart)
      copies.add(file)
      for suffix in [".dependencies.json", ".qbe.json"]:
        if fileExists(artifact & suffix):
          copyFile(artifact & suffix, file & suffix)
          copies.add(file & suffix)
      if artifact.endsWith(".spv") and fileExists(artifact & ".json"):
        copyFile(artifact & ".json", file & ".json")
        copies.add(file & ".json")
      let metadata = artifact & ".qbe.json"
      if fileExists(metadata):
        let descriptor = parseFile(metadata)
        if descriptor.hasKey("sharedAliases"):
          for alias in descriptor["sharedAliases"]:
            let name = alias.getStr()
            if name != name.lastPathPart or name in ["", ".", ".."]:
              raise newException(ValueError, "Unsafe shared-library alias: " & name)
            let staged = staging / name
            copy(artifact.parentDir / name, staged)
            copies.add(staged)
      let pdb = not fileExists(metadata) or
        parseFile(metadata).getOrDefault("debug").getStr() == "CodeView/PDB"
      for extension in ["pdb", "lib"]:
        if extension == "pdb" and not pdb: continue
        let sidecar = changeFileExt(artifact,extension)
        if sidecar != artifact and fileExists(sidecar):
          let staged = changeFileExt(file,extension)
          copyFileWithPermissions(sidecar,staged)
          copies.add(staged)
      let kind = if config.products.hasKey(name) and
          config.products[name].kind.len > 0: config.products[name].kind
        else: "exe"
      if signing and kind != "static":
        let signature = sign(file, deployment.signing, target, selected)
        if signature != file: seals.add(signature)

    for relative in additions:
      if relative.len == 0: continue
      let location = confined(source.root, relative)
      copy(location, staging / relative)

    var products = newJArray()
    for artifact in collect(staging):
      products.add(%*{
        "file": relativePath(artifact, staging).replace('\\', '/'),
        "bytes": getFileSize(artifact),
        "sha256": digest(readFile(artifact))
      })
    let metadata = %*{
      "format": "foo.release",
      "schema": 1,
      "name": manifest.name,
      "version": manifest.version,
      "license": manifest.license,
      "target": target,
      "artifacts": products
    }
    writeFile(staging / "release.json", pretty(metadata) & "\n")

    var checksums = ""
    for path in collect(staging):
      if path.lastPathPart == "SHA256SUMS": continue
      checksums.add(digest(readFile(path)) & "  " &
        relativePath(path, staging).replace('\\', '/') & "\n")
    writeFile(staging / "SHA256SUMS", checksums)

    if dirExists(result.directory): erase(result.directory)
    moveDir(staging, result.directory)
    for path in copies:
      result.artifacts.add(result.directory / path.lastPathPart)
    for path in seals:
      result.signatures.add(result.directory / path.lastPathPart)
  except:
    if dirExists(staging): erase(staging)
    raise
