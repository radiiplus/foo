import std/[algorithm, json, os, osproc, strutils, tables]
import ./[config, files, project]
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
    createDir(target)
    for _, child in walkDir(source):
      copy(child, target / child.lastPathPart)
  elif info.kind == pcFile:
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

proc bundle*(source: Project; signing = false; selected = ""): Bundle =
  let manifest = source.manifest()
  let deployment = manifest.deployment
  if deployment.directory.len == 0:
    raise newException(ValueError,
      "Release support is optional. Add a release object to project.json before running foo release")
  let config = source.config()
  var protected = @["src", "test", "benchmark"]
  if manifest.source notin ["", ".", "src"]: protected.add(manifest.source)
  let product = files.destination(source.root, config.output,
    protected)
  protected.add(relativePath(product, source.root))
  let root = files.destination(source.root, deployment.directory,
    protected)
  let target = triple(if source.options.target.len > 0: source.options.target
    elif config.target.len > 0: config.target[0] else: host)
  let folder = slug(manifest.name) & "-" & slug(manifest.version) & "-" & slug(target)
  result.directory = root / folder
  let artifacts = source.build()
  let staging = result.directory & ".partial"
  if dirExists(staging): erase(staging)
  createDir(staging)
  try:
    var stagedArtifacts, stagedSignatures: seq[string]
    for name, artifact in artifacts:
      let targetPath = staging / artifact.lastPathPart
      copyFileWithPermissions(artifact, targetPath)
      let shared = artifact.parentDir / "libcurl.so.4"
      if fileExists(shared):
        copyFileWithPermissions(shared, staging / shared.lastPathPart)
      stagedArtifacts.add(targetPath)
      let kind = if config.products.hasKey(name) and
          config.products[name].kind.len > 0: config.products[name].kind
        else: "exe"
      if signing and kind != "static":
        let signature = sign(targetPath, deployment.signing, target, selected)
        if signature != targetPath: stagedSignatures.add(signature)

    var additions = @[deployment.icon, deployment.license, deployment.readme]
    additions.add(deployment.files)
    for relative in additions:
      if relative.len == 0: continue
      if isAbsolute(relative):
        raise newException(ValueError,
          "Release file paths must be project-relative: " & relative)
      let sourcePath = confined(source.root, relative)
      if not fileExists(sourcePath) and not dirExists(sourcePath):
        raise newException(IOError, "Release file not found: " & relative)
      copy(sourcePath, staging / relative)

    var products = newJArray()
    for artifact in stagedArtifacts:
      products.add(%*{
        "file": artifact.lastPathPart,
        "bytes": getFileSize(artifact),
        "sha256": sha256Hex(readFile(artifact))
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
      checksums.add(sha256Hex(readFile(path)) & "  " &
        relativePath(path, staging).replace('\\', '/') & "\n")
    writeFile(staging / "SHA256SUMS", checksums)

    if dirExists(result.directory): erase(result.directory)
    moveDir(staging, result.directory)
    for path in stagedArtifacts:
      result.artifacts.add(result.directory / path.lastPathPart)
    for path in stagedSignatures:
      result.signatures.add(result.directory / path.lastPathPart)
  except:
    if dirExists(staging): erase(staging)
    raise
