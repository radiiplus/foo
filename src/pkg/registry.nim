import std/[algorithm, base64, httpclient, json, os, sequtils, strutils, tables, uri]
import ../build/files
import ./hash

type
  RegistryResponse* = object
    status*: int
    body*: string
  RegistryTransport* = proc(config: Registry; path, methodName, body, token: string): RegistryResponse {.closure.}
  RegistryCrypto* = object
    keyId*: proc(privatePath: string): string {.closure.}
    sign*: proc(privatePath, message: string): string {.closure.}
    verify*: proc(publicKey, message, signature: string): bool {.closure.}
  Registry* = object
    url*: string
    mirrors*: seq[string]
    keys*: JsonNode
  Installed* = object
    name*: string
    version*: string
    digest*: string
    signed*: JsonNode

var registryTransport*: RegistryTransport
var registryCrypto*: RegistryCrypto
const packageLimit = 32 * 1024 * 1024

proc canonical*(value: JsonNode): string

proc setRegistryTransport*(transport: RegistryTransport) =
  registryTransport = transport

proc setRegistryCrypto*(crypto: RegistryCrypto) =
  registryCrypto = crypto

proc request(config: Registry; path, methodName, body, token: string): RegistryResponse =
  if registryTransport != nil:
    return registryTransport(config, path, methodName, body, token)
  let base = if config.url.endsWith("/"): config.url else: config.url & "/"
  let endpoint = parseUri(base).combine(parseUri(path))
  let client = newHttpClient(timeout = 15000)
  defer: client.close()
  var headers = newHttpHeaders({"content-type": "application/json"})
  if token.len > 0: headers["authorization"] = "Bearer " & token
  client.headers = headers
  let response = if methodName == "GET": client.get($endpoint)
    else: client.request($endpoint, httpMethod = methodName, body = body)
  RegistryResponse(status: response.code.int, body: response.body)

proc ensureIdentity(name, version: string) =
  if name.len < 3 or name[0] notin {'a'..'z'} or '/' notin name or
      version.split('.').len != 3:
    raise newException(ValueError, "Packages need a namespace/name and an exact major.minor.patch version")

proc dependencyMap(node: JsonNode): JsonNode =
  if node.isNil or node.kind != JObject: return newJObject()
  result = newJObject()
  for name, source in node:
    let value = source.getStr()
    if not value.startsWith("registry+") or "@" notin value:
      raise newException(ValueError, "Registry dependencies need registry+namespace/name@version: " & value)
    let at = value.find('@')
    let depName = value[9 ..< at]
    let depVersion = value[at + 1 .. ^1]
    ensureIdentity(depName, depVersion)
    if depName != name: raise newException(ValueError, "Dependency name differs from its source: " & name)
    result[name] = %value

proc validateArchive(archive: JsonNode; expectedName = ""; expectedVersion = ""; expectedDependencies: JsonNode = nil) =
  if archive.kind != JObject or archive.getOrDefault("schema").getInt() != 1 or
      not archive.hasKey("files") or archive["files"].kind != JArray or archive["files"].len > 10000:
    raise newException(ValueError, "Invalid package archive")
  var seen = initTable[string, bool]()
  var size = 0
  var projectManifest = ""
  for item in archive["files"]:
    let path = item.getOrDefault("path").getStr()
    if path.len == 0 or path.startsWith("/") or path.contains('\\') or path.split('/').anyIt(it.len == 0 or it in [".", ".."]):
      raise newException(ValueError, "Unsafe package path")
    let identity = path.toLowerAscii()
    if seen.getOrDefault(identity): raise newException(ValueError, "Duplicate package path: " & path)
    seen[identity] = true
    let encoded = item.getOrDefault("data").getStr()
    let data = decode(encoded)
    if encode(data) != encoded: raise newException(ValueError, "Invalid package file encoding")
    size += data.len
    if size > packageLimit: raise newException(ValueError, "Package exceeds 32 MiB")
    if path == "project.json": projectManifest = data
  if projectManifest.len == 0: raise newException(ValueError, "Package is missing project.json")
  if expectedName.len > 0:
    let project = parseJson(projectManifest)
    if project.getOrDefault("name").getStr() != expectedName or project.getOrDefault("version").getStr() != expectedVersion:
      raise newException(ValueError, "Signed identity differs from project.json")
    if expectedDependencies != nil and canonical(dependencyMap(project.getOrDefault("dependencies"))) != canonical(expectedDependencies):
      raise newException(ValueError, "Signed dependencies differ from project.json")

proc archiveFromProject(root: string): JsonNode =
  let projectPath = root / "project.json"
  if not fileExists(projectPath): raise newException(IOError, "Project manifest not found")
  let project = parseJson(readFile(projectPath))
  ensureIdentity(project.getOrDefault("name").getStr(), project.getOrDefault("version").getStr())
  var selected: seq[string] = @[]
  selected.add("project.json")
  if project.hasKey("publish") and project["publish"].kind == JObject and project["publish"].hasKey("files"):
    for pattern in project["publish"]["files"]:
      let matches = glob(root, pattern.getStr())
      if matches.len == 0: raise newException(ValueError, "Publish input matched no files: " & pattern.getStr())
      selected.add(matches)
  else:
    selected.add(glob(root, "src/**/*.iv"))
  selected.sort()
  var seen = initTable[string, bool]()
  var files = newJArray()
  for relative in selected:
    if relative in seen: continue
    seen[relative] = true
    let path = confined(root, relative)
    if relative.toLowerAscii().endsWith(".pem") or relative.toLowerAscii().endsWith(".key") or relative.startsWith(".env"):
      raise newException(ValueError, "Signing keys and secrets cannot be packaged")
    let content = if relative == "project.json": canonical(%*{"name": project["name"], "version": project["version"], "dependencies": dependencyMap(project.getOrDefault("dependencies"))}) else: readFile(path)
    files.add(%*{"path": relative.replace('\\', '/'), "data": encode(content)})
  %*{"schema": 1, "files": files}

proc verifySigned(config: Registry; signed: JsonNode): JsonNode =
  let release = signed.getOrDefault("release")
  if release.isNil or release.kind != JObject: raise newException(ValueError, "Invalid release metadata")
  let name = release.getOrDefault("name").getStr()
  let tag = release.getOrDefault("version").getStr()
  ensureIdentity(name, tag)
  let key = release.getOrDefault("key").getStr()
  let pinned = if config.keys.hasKey(name.split('/')[0]): config.keys[name.split('/')[0]].getOrDefault(key).getStr() else: ""
  if pinned.len == 0: raise newException(ValueError, "Untrusted signing key for namespace '" & name.split('/')[0] & "'")
  if registryCrypto.verify == nil: raise newException(ValueError, "Registry verification requires an Ed25519 provider")
  if not registryCrypto.verify(pinned, canonical(release), signed.getOrDefault("signature").getStr()):
    raise newException(ValueError, "Invalid package signature: " & name & "@" & tag)
  signed

proc canonical*(value: JsonNode): string =
  case value.kind
  of JNull: "null"
  of JBool:
    if value.getBool(): "true" else: "false"
  of JInt, JFloat: $value
  of JString: escapeJson(value.getStr())
  of JArray: "[" & value.elems.mapIt(canonical(it)).join(",") & "]"
  of JObject:
    var keys = value.keys.toSeq
    keys.sort()
    "{" & keys.mapIt(escapeJson(it) & ":" & canonical(value[it])).join(",") & "}"

proc validUrl(value: string): bool =
  value.startsWith("https://") or value.startsWith("http://127.0.0.1") or value.startsWith("http://localhost") or value.startsWith("http://[::1]")

proc configuration*(root: string): Registry =
  let file = root / "project.json"
  if not fileExists(file): raise newException(IOError, "Configure registry.url and pinned registry.keys in project.json")
  let project = parseJson(readFile(file))
  if not project.hasKey("registry") or project["registry"].kind != JObject:
    raise newException(ValueError, "Configure registry.url and pinned registry.keys in project.json")
  let node = project["registry"]
  result.url = node.getOrDefault("url").getStr()
  if result.url.len == 0 or not node.hasKey("keys"): raise newException(ValueError, "Configure registry.url and pinned registry.keys in project.json")
  if node.hasKey("mirrors"):
    for item in node["mirrors"]: result.mirrors.add(item.getStr())
  result.keys = node["keys"]
  for url in @[result.url] & result.mirrors:
    if not validUrl(url): raise newException(ValueError, "Registry URLs require HTTPS (loopback HTTP is allowed for staging)")

proc verifyFiles(root: string; archive: JsonNode) =
  var expected = initTable[string, string]()
  for item in archive["files"]:
    let path = item["path"].getStr()
    if path.startsWith("/") or path.split('/').anyIt(it.len == 0 or it in [".", ".."]): raise newException(ValueError, "Unsafe package path")
    expected[path] = decode(item["data"].getStr())
  proc visit(directory, prefix: string) =
    if not dirExists(directory): raise newException(IOError, "Missing package directory: " & directory)
    for kind, path in walkDir(directory):
      let relative = prefix & path.lastPathPart
      if kind == pcDir: visit(path, relative & "/")
      elif kind != pcFile or relative notin expected or readFile(path) != expected[relative]:
        raise newException(ValueError, "Tampered package file: " & relative)
      else: expected.del(relative)
  visit(root, "")
  if expected.len > 0:
    for path in expected.keys: raise newException(ValueError, "Missing package file: " & path)

proc audit*(root: string): int =
  discard configuration(root)
  let lockPath = confined(root, ".artifacts/registry/lock.json")
  if not fileExists(lockPath): raise newException(IOError, "No signed package lock; run foo install first")
  let lock = parseJson(readFile(lockPath))
  if lock.getOrDefault("schema").getInt() != 1 or not lock.hasKey("packages") or lock["packages"].kind != JArray:
    raise newException(ValueError, "Invalid registry lock")
  var names = initTable[string, string]()
  for item in lock["packages"]:
    let name = item["name"].getStr()
    let digest = item["digest"].getStr()
    if name in names: raise newException(ValueError, "Duplicate locked package")
    names[name] = item["version"].getStr()
    let objectPath = confined(root, ".artifacts/registry/objects/" & digest & ".json")
    if not fileExists(objectPath): raise newException(IOError, "Missing registry object: " & digest)
    let data = readFile(objectPath)
    if sha256Hex(data) != digest: raise newException(ValueError, "Package object digest mismatch: " & name)
    let archive = parseJson(data)
    let signed = verifySigned(configuration(root), item["signed"])
    if signed["release"]["digest"].getStr() != digest: raise newException(ValueError, "Lock digest differs from signed release")
    validateArchive(archive, name, item["version"].getStr(), signed["release"].getOrDefault("dependencies"))
    verifyFiles(confined(root, ".artifacts/packages/" & name), archive)
    result.inc

proc mirror*(root, destination: string): int =
  result = audit(root)
  let lock = parseJson(readFile(root / ".artifacts" / "registry" / "lock.json"))
  for item in lock["packages"]:
    let name = item["name"].getStr()
    let version = item["version"].getStr()
    let digest = item["digest"].getStr()
    let metadata = confined(destination, "packages/" & name & "/" & version & ".json")
    let objectTarget = confined(destination, "objects/" & digest & ".json")
    write(metadata, canonical(item["signed"]))
    write(objectTarget, readFile(root / ".artifacts" / "registry" / "objects" / (digest & ".json")))

proc publish*(root, privatePath: string; token = ""): string =
  let config = configuration(root)
  let project = parseJson(readFile(root / "project.json"))
  let name = project.getOrDefault("name").getStr()
  let tag = project.getOrDefault("version").getStr()
  ensureIdentity(name, tag)
  if registryCrypto.keyId == nil or registryCrypto.sign == nil: raise newException(ValueError, "Registry publishing requires an Ed25519 provider")
  let archive = archiveFromProject(root)
  validateArchive(archive, name, tag, dependencyMap(project.getOrDefault("dependencies")))
  let data = canonical(archive)
  let digest = sha256Hex(data)
  let key = registryCrypto.keyId(privatePath)
  let release = %*{"schema": 1, "name": name, "version": tag, "digest": digest,
    "key": key, "dependencies": dependencyMap(project.getOrDefault("dependencies"))}
  let signed = %*{"release": release, "signature": registryCrypto.sign(privatePath, canonical(release))}
  discard verifySigned(config, signed)
  for item in @[("objects/" & digest & ".json", data), ("packages/" & name & "/" & tag & ".json", canonical(signed))]:
    let response = request(config, item[0], "PUT", item[1], token)
    if response.status == 412:
      let existing = request(config, item[0], "GET", "", "")
      if existing.status != 200 or existing.body != item[1]:
        raise newException(ValueError, "Release already exists with different content: " & name & "@" & tag)
    elif response.status notin [200, 201, 204]:
      raise newException(IOError, "Publishing failed (" & $response.status & ")")
  name & "@" & tag

proc install*(root: string): seq[Installed] =
  let config = configuration(root)
  let project = parseJson(readFile(root / "project.json"))
  var queue: seq[tuple[name, version: string]] = @[]
  for _, source in dependencyMap(project.getOrDefault("dependencies")):
    let value = source.getStr(); let at = value.find('@')
    queue.add((value[9 ..< at], value[at + 1 .. ^1]))
  var installed = initTable[string, Installed]()
  while queue.len > 0:
    let item = queue[0]; queue.delete(0)
    if installed.hasKey(item.name):
      if installed[item.name].version != item.version: raise newException(ValueError, "Dependency version conflict: " & item.name)
      continue
    let metadataResponse = request(config, "packages/" & item.name & "/" & item.version & ".json", "GET", "", "")
    if metadataResponse.status != 200: raise newException(IOError, "Package unavailable: " & item.name & "@" & item.version)
    let signed = verifySigned(config, parseJson(metadataResponse.body))
    let release = signed["release"]
    let digest = release["digest"].getStr()
    let objectResponse = request(config, "objects/" & digest & ".json", "GET", "", "")
    if objectResponse.status != 200 or sha256Hex(objectResponse.body) != digest: raise newException(ValueError, "Package digest mismatch: " & item.name)
    let archive = parseJson(objectResponse.body)
    validateArchive(archive, item.name, item.version, release.getOrDefault("dependencies"))
    write(confined(root, ".artifacts/registry/objects/" & digest & ".json"), objectResponse.body)
    let target = confined(root, ".artifacts/packages/" & item.name)
    createDir(target)
    for file in archive["files"]:
      let relative = file["path"].getStr()
      let targetPath = confined(target, relative)
      write(targetPath, decode(file["data"].getStr()))
    let dependencies = release.getOrDefault("dependencies")
    for _, source in dependencyMap(dependencies):
      let value = source.getStr(); let at = value.find('@')
      queue.add((value[9 ..< at], value[at + 1 .. ^1]))
    installed[item.name] = Installed(name: item.name, version: item.version, digest: digest, signed: signed)
  var names = installed.keys.toSeq
  names.sort()
  var packages = newJArray()
  for name in names:
    let item = installed[name]
    packages.add(%*{"name": item.name, "version": item.version, "digest": item.digest, "signed": item.signed})
  write(confined(root, ".artifacts/registry/lock.json"), canonical(%*{"schema": 1, "packages": packages}))
  for name in names: result.add(installed[name])
