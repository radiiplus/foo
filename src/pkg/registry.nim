import std/[algorithm, json, os, osproc, sequtils, sets, strutils, tables, times]
when not defined(windows): import std/httpclient
import ./[hash, semver, surface]
import ../fmt/formatter as fooFormatter

const
  defaultSource* = "https://raw.githubusercontent.com/radiiplus/foo.registry/main"
  defaultApi* = "https://arfoskacounswfvzjkfv.supabase.co/functions/v1/registry"

type
  RegistryResponse* = object
    status*: int
    body*: string
  Registry* = object
    source*: string
    api*: string
  RegistryTransport* = proc(config: Registry; path, methodName, body, token: string): RegistryResponse {.closure.}
  RegistryBrowserOpener* = proc(url: string) {.closure.}
  RegistryProgress* = proc(phase, name, detail: string) {.closure.}
  PublishProgress* = RegistryProgress
  Installed* = object
    name*: string
    version*: string
    repository*: string
    revision*: string
    digest*: string
    direct*: bool
    dependencies*: seq[string]

var registryTransport*: RegistryTransport
var registryBrowserOpener*: RegistryBrowserOpener

proc setRegistryTransport*(transport: RegistryTransport) =
  registryTransport = transport

proc setRegistryBrowserOpener*(opener: RegistryBrowserOpener) =
  registryBrowserOpener = opener

proc trimSlash(value: string): string =
  result = value
  while result.endsWith("/"): result.setLen(result.len - 1)

proc configuration*(root: string): Registry =
  result = Registry(
    source: getEnv("FOO_REGISTRY_URL", defaultSource),
    api: getEnv("FOO_REGISTRY_API", defaultApi),
  )
  let manifestPath = root / "project.json"
  if not fileExists(manifestPath): return
  let project = parseJson(readFile(manifestPath))
  let registry = project.getOrDefault("registry")
  if registry != nil and registry.kind == JObject:
    let source = registry.getOrDefault("url").getStr()
    let api = registry.getOrDefault("api").getStr()
    if source.len > 0: result.source = source
    if api.len > 0: result.api = api

proc request(config: Registry; path, methodName, body, token: string): RegistryResponse =
  if registryTransport != nil:
    return registryTransport(config, path, methodName, body, token)
  let base = if path.startsWith("/auth/") or path in ["/publish", "/deprecate"]: config.api else: config.source
  let endpoint = trimSlash(base) & "/" & path.strip(chars = {'/'})
  when defined(windows):
    if methodName notin ["GET", "POST"]:
      raise newException(ValueError, "Unsupported registry method: " & methodName)
    let identity = $getCurrentProcessId() & "-" & $int64(epochTime() * 1_000_000)
    let headerPath = getTempDir() / ("foo-headers-" & identity & ".txt")
    let bodyPath = getTempDir() / ("foo-body-" & identity & ".json")
    writeFile(headerPath, "accept: application/json\ncontent-type: application/json\n" &
      (if token.len > 0: "authorization: Bearer " & token & "\n" else: ""))
    if methodName == "POST": writeFile(bodyPath, body)
    try:
      var command = "curl.exe --silent --show-error --location --max-time 30 --request " & methodName &
        " --header " & quoteShell("@" & headerPath)
      if methodName == "POST": command.add(" --data-binary " & quoteShell("@" & bodyPath))
      command.add(" --write-out " & quoteShell("FOO_STATUS:%{http_code}") & " -- " & quoteShell(endpoint))
      let response = execCmdEx(command)
      if response.exitCode != 0: raise newException(IOError, response.output.strip)
      let marker = response.output.rfind("FOO_STATUS:")
      if marker < 0: raise newException(IOError, "Registry request returned no HTTP status")
      result = RegistryResponse(
        status: parseInt(response.output[marker + 11 .. ^1].strip),
        body: response.output[0 ..< marker],
      )
    finally:
      if fileExists(headerPath): removeFile(headerPath)
      if fileExists(bodyPath): removeFile(bodyPath)
  else:
    let client = newHttpClient(timeout = 30_000)
    defer: client.close()
    client.headers = newHttpHeaders({"accept": "application/json", "content-type": "application/json"})
    if token.len > 0: client.headers["authorization"] = "Bearer " & token
    let response = case methodName
      of "GET": client.get(endpoint)
      of "POST": client.request(endpoint, httpMethod = HttpPost, body = body)
      else: raise newException(ValueError, "Unsupported registry method: " & methodName)
    result = RegistryResponse(status: response.code.int, body: response.body)

proc requireResponse(response: RegistryResponse; operation: string): JsonNode =
  if response.status < 200 or response.status >= 300:
    var detail = response.body
    try:
      let parsed = parseJson(response.body)
      let message = parsed.getOrDefault("error").getStr()
      if message.len > 0: detail = message
    except CatchableError: discard
    raise newException(IOError, operation & " failed (" & $response.status & "): " & detail)
  try: parseJson(response.body)
  except CatchableError as error:
    raise newException(IOError, operation & " returned invalid JSON: " & error.msg)

proc validName(value: string): bool =
  var package = value
  if value.startsWith("std/"):
    let parts = value.split('/')
    if parts.len < 2: return false
    for part in parts[1 .. ^1]:
      if part.len == 0 or part.len > 64 or part[0] notin {'a'..'z'}: return false
      for character in part:
        if character notin {'a'..'z', '0'..'9', '-'}: return false
    return true
  if value.startsWith("@"):
    let parts = value.split('/')
    if parts.len != 2 or parts[0].len < 2 or parts[0].len > 40: return false
    for character in parts[0][1 .. ^1]:
      if character notin {'a'..'z', '0'..'9', '-'}: return false
    package = parts[1]
  if package.len == 0 or package.len > 64 or package[0] notin {'a'..'z'}: return false
  for character in package:
    if character notin {'a'..'z', '0'..'9', '-'}: return false
  true

proc exactVersion*(value: string): bool =
  let base = value.split('-', maxsplit = 1)[0]
  let parts = base.split('.')
  if parts.len != 3: return false
  for part in parts:
    if part.len == 0 or (part.len > 1 and part[0] == '0'): return false
    for character in part:
      if character notin {'0'..'9'}: return false
  if '-' in value:
    let suffix = value.split('-', maxsplit = 1)[1]
    if suffix.len == 0: return false
    for character in suffix:
      if not (character.isAlphaNumeric or character in {'.', '-'}): return false
  true

proc ensurePackage(name, version: string) =
  if not validName(name): raise newException(ValueError, "Invalid package name: " & name)
  discard parseConstraint(version)

proc ensureRelease(name, version: string) =
  if not validName(name): raise newException(ValueError, "Invalid package name: " & name)
  if not exactVersion(version): raise newException(ValueError, "Package version must be exact: " & version)

proc entries(config: Registry): tuple[revision: string, values: seq[JsonNode]] =
  let manifest = requireResponse(request(config, "indexes/index.json", "GET", "", ""), "Registry index")
  if manifest.getOrDefault("schema").getStr() != "foo.registry/v1" or
      manifest.getOrDefault("shards").kind != JArray:
    raise newException(ValueError, "Invalid registry index")
  result.revision = manifest.getOrDefault("revision").getStr()
  for descriptor in manifest["shards"]:
    let path = descriptor.getOrDefault("path").getStr()
    if not path.startsWith("indexes/index-") or not path.endsWith(".jsonl"):
      raise newException(ValueError, "Invalid registry shard path")
    let shard = request(config, path, "GET", "", "")
    if shard.status < 200 or shard.status >= 300:
      discard requireResponse(shard, "Registry shard")
    for line in shard.body.splitLines:
      if line.strip.len == 0: continue
      let entry = parseJson(line)
      if entry.getOrDefault("schema").getStr() != "foo.entry/v1":
        raise newException(ValueError, "Invalid registry JSONL entry")
      result.values.add(entry)

proc search*(root, query: string; limit = 50): seq[JsonNode] =
  let needle = query.strip.toLowerAscii()
  for entry in entries(configuration(root)).values:
    var text = entry.getOrDefault("name").getStr() & " " &
      entry.getOrDefault("description").getStr() & " " &
      entry.getOrDefault("category").getStr()
    for field in ["tags", "exports"]:
      let values = entry.getOrDefault(field)
      if values != nil and values.kind == JArray:
        for value in values: text.add(" " & value.getStr())
    if needle.len == 0 or needle in text.toLowerAscii():
      result.add(entry)
      if result.len >= limit: break

proc findEntry(config: Registry; name: string): JsonNode =
  for entry in entries(config).values:
    if entry.getOrDefault("name").getStr() == name: return entry
  raise newException(IOError, "Package not found: " & name)

proc latestVersion*(root, name: string): string =
  if not validName(name): raise newException(ValueError, "Invalid package name: " & name)
  findEntry(configuration(root), name).getOrDefault("version").getStr()

proc release(config: Registry; name, version: string): JsonNode =
  ensureRelease(name, version)
  let entry = findEntry(config, name)
  var path = ""
  let versions = entry.getOrDefault("versions")
  if versions != nil and versions.kind == JArray:
    for item in versions:
      if item.getOrDefault("version").getStr() == version:
        path = item.getOrDefault("path").getStr()
  if path.len == 0: raise newException(IOError, "Package version not found: " & name & "@" & version)
  result = requireResponse(request(config, path, "GET", "", ""), "Package metadata")
  if result.getOrDefault("schema").getStr() != "foo.package/v1" or
      result.getOrDefault("name").getStr() != name or
      result.getOrDefault("version").getStr() != version:
    raise newException(ValueError, "Registry package identity mismatch: " & name & "@" & version)

proc info*(root, name: string; version = ""): JsonNode =
  let config = configuration(root)
  let selected = if version.len > 0: version else: findEntry(config, name).getOrDefault("version").getStr()
  release(config, name, selected)

proc authFile(): string =
  getEnv("FOO_CONFIG_DIR", getConfigDir() / "foo") / "auth.json"

proc authToken*(): string =
  result = getEnv("FOO_TOKEN")
  if result.len > 0: return
  let path = authFile()
  if not fileExists(path): return
  try: result = parseJson(readFile(path)).getOrDefault("access_token").getStr()
  except CatchableError: discard

proc openUrl(url: string) =
  if registryBrowserOpener != nil:
    registryBrowserOpener(url)
    return
  when defined(windows):
    discard execCmdEx("cmd /c start \"\" " & quoteShell(url))
  elif defined(macosx):
    if findExe("open").len > 0: discard execCmdEx("open " & quoteShell(url))
  else:
    if findExe("xdg-open").len > 0: discard execCmdEx("xdg-open " & quoteShell(url))

proc login*(): string =
  let config = configuration(getCurrentDir())
  let started = requireResponse(request(config, "/auth/device", "POST", "{}", ""), "GitHub device login")
  let device = started.getOrDefault("device_code").getStr()
  let code = started.getOrDefault("user_code").getStr()
  let url = started.getOrDefault("verification_uri").getStr()
  let expires = started.getOrDefault("expires_in").getInt(900)
  var interval = started.getOrDefault("interval").getInt(5)
  if device.len == 0 or code.len == 0 or url.len == 0:
    raise newException(IOError, "GitHub device login returned incomplete instructions")
  echo "Open " & url & " and enter code " & code
  echo "GitHub keeps the device page open. Return to this terminal after authorizing."
  openUrl(url)
  let deadline = epochTime() + float(expires)
  while epochTime() < deadline:
    sleep(interval * 1000)
    let response = request(config, "/auth/device/token", "POST",
      $(%*{"device_code": device}), "")
    if response.status == 202:
      let pending = parseJson(response.body)
      if pending.getOrDefault("error").getStr() == "slow_down": interval += 5
      continue
    let token = requireResponse(response, "GitHub device login").getOrDefault("access_token").getStr()
    if token.len == 0: raise newException(IOError, "GitHub device login returned no token")
    let path = authFile()
    createDir(path.parentDir)
    writeFile(path, pretty(%*{"access_token": token}) & "\n")
    when defined(posix): setFilePermissions(path, {fpUserRead, fpUserWrite})
    return path
  raise newException(IOError, "GitHub device login expired")

proc git(root: string; arguments: varargs[string]): string =
  var command = "git"
  if root.len > 0: command.add(" -C " & quoteShell(root))
  for argument in arguments: command.add(" " & quoteShell(argument))
  let response = execCmdEx(command)
  if response.exitCode != 0: raise newException(IOError, response.output.strip)
  response.output.strip

type Requirement = object
  name: string
  version: string
  kind: string
  platforms: seq[string]
  direct: bool
  optional: bool

proc addDependencies(result: JsonNode; project: JsonNode; field, kind: string) =
  let values = project.getOrDefault(field)
  if values == nil or values.kind != JObject: return
  var names: seq[string]
  for name in values.keys: names.add(name)
  names.sort()
  for name in names:
    var version = ""
    var platforms = newJArray()
    if values[name].kind == JString:
      version = values[name].getStr()
    elif values[name].kind == JObject:
      version = values[name].getOrDefault("version").getStr()
      let configured = values[name].getOrDefault("platforms")
      if configured != nil and configured.kind == JArray: platforms = configured
    ensurePackage(name, version)
    result.add(%*{"name": name, "version": version, "kind": kind, "platforms": platforms})

proc projectDependencies(project: JsonNode): JsonNode =
  result = newJArray()
  result.addDependencies(project, "dependencies", "runtime")
  result.addDependencies(project, "devDependencies", "dev")
  result.addDependencies(project, "optionalDependencies", "optional")
  let platformValues = project.getOrDefault("platformDependencies")
  if platformValues != nil and platformValues.kind == JObject:
    var selectors: seq[string]
    for selector in platformValues.keys: selectors.add(selector)
    selectors.sort()
    for selector in selectors:
      let values = platformValues[selector]
      if values.kind != JObject: raise newException(ValueError, "platformDependencies entries must be objects")
      var names: seq[string]
      for name in values.keys: names.add(name)
      names.sort()
      for name in names:
        let version = values[name].getStr()
        ensurePackage(name, version)
        result.add(%*{"name": name, "version": version, "kind": "platform", "platforms": [selector]})

proc bundledSource(root: string): JsonNode =
  var paths = @[root / "project.json"]
  for path in walkDirRec(root):
    if not fileExists(path) or not path.endsWith(".iv"): continue
    let relative = relativePath(path, root).replace('\\', '/')
    if relative.split('/').anyIt(it in [".git", ".foo", "node_modules", ".artifacts"]): continue
    paths.add(path)
  paths = paths.deduplicate()
  paths.sort()
  var files = newJArray()
  var canonical = ""
  var total = 0
  for path in paths:
    let relative = relativePath(path, root).replace('\\', '/')
    var content = readFile(path).replace("\r\n", "\n").replace("\r", "\n")
    if path.endsWith(".iv"): content = fooFormatter.formatSource(content)
    total += relative.len + content.len
    if total > 16 * 1024 * 1024: raise newException(ValueError, "Package source exceeds 16 MiB")
    files.add(%*{"path": relative, "content": content})
    canonical.add(relative & "\0" & content & "\0")
  %*{"format": "foo.source/v1", "digest": sha256Hex(canonical), "files": files}

proc required(node: JsonNode; field: string): string =
  result = node.getOrDefault(field).getStr().strip
  if result.len == 0: raise newException(ValueError, "project.json needs a non-empty '" & field & "' field")

proc publish*(root: string; token = ""; progress: PublishProgress = nil): string =
  let manifestPath = root / "project.json"
  if not fileExists(manifestPath): raise newException(IOError, "project.json not found")
  let project = parseJson(readFile(manifestPath))
  let name = required(project, "name").toLowerAscii()
  let version = required(project, "version")
  if name.startsWith("std/"): raise newException(ValueError, "The std/ package namespace is reserved")
  ensurePackage(name, version)
  let state = git(root, "status", "--porcelain")
  if state.len > 0: raise newException(ValueError, "Commit project changes before publishing")
  let revision = git(root, "rev-parse", "HEAD").toLowerAscii()
  if revision.len != 40: raise newException(ValueError, "Publishing requires a Git commit")
  let readmePath = root / "README.md"
  if not fileExists(readmePath): raise newException(ValueError, "README.md not found")
  var documentation = newJArray()
  for line in readFile(readmePath).splitLines:
    if line.strip.len > 0: documentation.add(%line)
  if documentation.len < 100:
    raise newException(ValueError, "README.md must contain at least 100 non-empty lines")
  let repository = required(project, "repository")
  var tags = project.getOrDefault("tags")
  if tags == nil or tags.kind != JArray: tags = newJArray()
  var platforms = project.getOrDefault("platforms")
  if platforms == nil or platforms.kind != JArray: platforms = newJArray()
  let packageName = name & "@" & version
  if progress != nil: progress("package", packageName, "revision " & revision[0 .. 11])
  let source = bundledSource(root)
  let api = publicApi(source)
  var exports = 0
  for module in api.getOrDefault("modules"):
    exports += module.getOrDefault("items").len
  if progress != nil:
    progress("bundle", packageName, $source["files"].len & " files, " &
      $exports & " exports, " & $documentation.len & " documentation lines")
  let publication = %*{
    "schema": "foo.publish/v1",
    "manifest": {
      "schema": "foo.package/v1",
      "name": name,
      "version": version,
      "description": required(project, "description"),
      "category": required(project, "category"),
      "tags": tags,
      "license": required(project, "license"),
      "compatible": project.getOrDefault("compatible").getBool(true),
      "deprecated": "",
      "platforms": platforms,
      "updated": now().utc.format("yyyy-MM-dd"),
      "repository": repository,
      "revision": revision,
      "install": "foo add " & name,
      "dependencies": projectDependencies(project),
    },
    "documentation": documentation,
    "source": source,
    "api": api,
  }
  let credential = if token.len > 0: token else: authToken()
  if credential.len == 0: raise newException(ValueError, "Run 'foo login' before publishing")
  if progress != nil: progress("upload", packageName, configuration(root).api)
  let response = requireResponse(request(configuration(root), "/publish", "POST", $publication, credential), "Publication")
  let publishedName = response.getOrDefault("package").getStr(name)
  let publishedVersion = response.getOrDefault("version").getStr(version)
  let commit = response.getOrDefault("commit").getStr()
  if progress != nil and commit.len > 0:
    progress("commit", publishedName & "@" & publishedVersion,
      if commit.len >= 12: commit[0 .. 11] else: commit)
  publishedName & "@" & publishedVersion

proc removeTree(path: string) =
  if not dirExists(path): return
  for kind, child in walkDir(path):
    if kind == pcDir: removeTree(child) else: removeFile(child)
  removeDir(path)

proc sourceDigest(source: JsonNode): string =
  if source == nil or source.kind != JObject or source.getOrDefault("format").getStr() != "foo.source/v1" or
      source.getOrDefault("files").kind != JArray:
    raise newException(ValueError, "Package has no valid source bundle")
  var canonical = ""
  var previous = ""
  var seen = initHashSet[string]()
  for file in source["files"]:
    let path = file.getOrDefault("path").getStr()
    let content = file.getOrDefault("content")
    if path.len == 0 or path.startsWith("/") or '\\' in path or
        path.split('/').anyIt(it.len == 0 or it in [".", ".."]) or content == nil or content.kind != JString:
      raise newException(ValueError, "Package contains an unsafe source path")
    if previous.len > 0 and path < previous: raise newException(ValueError, "Package source is not sorted")
    let key = path.toLowerAscii()
    if key in seen: raise newException(ValueError, "Package contains duplicate source paths")
    seen.incl(key)
    previous = path
    canonical.add(path & "\0" & content.getStr() & "\0")
  result = sha256Hex(canonical)
  if source.getOrDefault("digest").getStr() != result:
    raise newException(ValueError, "Package source digest mismatch")

proc extractRelease(root: string; record: JsonNode): Installed =
  result.name = record.getOrDefault("name").getStr()
  result.version = record.getOrDefault("version").getStr()
  result.repository = record.getOrDefault("repository").getStr()
  result.revision = record.getOrDefault("revision").getStr().toLowerAscii()
  ensureRelease(result.name, result.version)
  let source = record.getOrDefault("source")
  result.digest = sourceDigest(source)
  let destination = root / ".foo" / "packages" / result.name
  removeTree(destination)
  createDir(destination)
  for file in source["files"]:
    let target = destination / file["path"].getStr()
    createDir(target.parentDir)
    writeFile(target, file["content"].getStr())

proc currentPlatform(): string =
  when defined(windows): "windows"
  elif defined(macosx): "macos"
  elif defined(linux): "linux"
  else: "other"

proc enabled(platforms: seq[string]): bool =
  platforms.len == 0 or "all" in platforms or currentPlatform() in platforms

proc dependencies(record: JsonNode): seq[Requirement] =
  let values = record.getOrDefault("dependencies")
  if values == nil or values.kind != JArray: return
  for value in values:
    let kind = value.getOrDefault("kind").getStr("runtime")
    if kind == "dev": continue
    let name = value.getOrDefault("name").getStr()
    let version = value.getOrDefault("version").getStr()
    ensurePackage(name, version)
    var platforms: seq[string]
    let selected = value.getOrDefault("platforms")
    if selected != nil and selected.kind == JArray:
      for platform in selected: platforms.add(platform.getStr())
    if kind == "platform" and not enabled(platforms): continue
    result.add(Requirement(name: name, version: version, kind: kind,
      platforms: platforms, optional: kind == "optional"))

proc rootRequirements(project: JsonNode): seq[Requirement] =
  for dependency in projectDependencies(project):
    var platforms: seq[string]
    for platform in dependency["platforms"]: platforms.add(platform.getStr())
    let kind = dependency["kind"].getStr()
    if kind == "platform" and not enabled(platforms): continue
    result.add(Requirement(name: dependency["name"].getStr(),
      version: dependency["version"].getStr(), kind: kind, platforms: platforms,
      direct: true, optional: kind == "optional"))

proc requirementJson(requirements: seq[Requirement]): JsonNode =
  result = newJArray()
  var sorted = requirements
  sorted.sort(proc(left, right: Requirement): int = cmp(left.name, right.name))
  for item in sorted:
    var platforms = newJArray()
    for platform in item.platforms: platforms.add(%platform)
    result.add(%*{"name": item.name, "version": item.version, "kind": item.kind, "platforms": platforms})

proc versions(catalog: seq[JsonNode]; name: string; deprecated = false): seq[string] =
  for entry in catalog:
    if entry.getOrDefault("name").getStr() != name: continue
    for item in entry.getOrDefault("versions"):
      let version = item.getOrDefault("version").getStr()
      if (deprecated or item.getOrDefault("deprecated").getStr().len == 0) and '-' notin version:
        result.add(version)
    return

proc choose(catalog: seq[JsonNode]; name: string; constraints: seq[string]): string =
  result = semver.select(versions(catalog, name), constraints)
  if result.len == 0 and constraints.anyIt(it.len > 0 and it[0] notin {'^', '~'}):
    result = semver.select(versions(catalog, name, true), constraints)

proc resolve(root: string; config: Registry; catalog: seq[JsonNode]; roots: seq[Requirement];
    progress: RegistryProgress = nil): seq[Installed] =
  var preferred = initTable[string, string]()
  var records = initTable[string, JsonNode]()
  var fetched = initTable[string, JsonNode]()
  var direct = initHashSet[string]()
  var attempts = 0
  while true:
    inc attempts
    if attempts > 10_000: raise newException(ValueError, "Dependency resolution did not converge")
    var constraints = initTable[string, seq[string]]()
    var expanded = initHashSet[string]()
    var queue = roots
    records.clear()
    direct.clear()
    var restart = false
    var position = 0
    while position < queue.len:
      let requirement = queue[position]
      inc position
      if requirement.direct: direct.incl(requirement.name)
      var requested = constraints.getOrDefault(requirement.name)
      requested.add(requirement.version)
      let selected = choose(catalog, requirement.name, requested)
      if selected.len == 0:
        if requirement.optional: continue
        raise newException(ValueError, "Dependency conflict for " & requirement.name & ": " & requested.join(", "))
      constraints[requirement.name] = requested
      if not preferred.hasKey(requirement.name) or
          not requested.allIt(satisfies(preferred[requirement.name], it)):
        preferred[requirement.name] = selected
        restart = true
        break
      if requirement.name in expanded: continue
      expanded.incl(requirement.name)
      let identity = requirement.name & "@" & preferred[requirement.name]
      var record: JsonNode
      if fetched.hasKey(identity):
        record = fetched[identity]
      else:
        if progress != nil: progress("fetch", identity, "registry")
        record = release(config, requirement.name, preferred[requirement.name])
        fetched[identity] = record
      records[requirement.name] = record
      for dependency in dependencies(record): queue.add(dependency)
    if restart: continue
    var names = toSeq(records.keys)
    names.sort()
    for name in names:
      var installed = extractRelease(root, records[name])
      installed.direct = name in direct
      for dependency in dependencies(records[name]):
        if records.hasKey(dependency.name):
          installed.dependencies.add(dependency.name & "@" & records[dependency.name]["version"].getStr())
      installed.dependencies.sort()
      if progress != nil:
        progress("install", installed.name & "@" & installed.version,
          "sha256:" & installed.digest[0 .. 11])
      result.add(installed)
    return

proc writeLock(root, registryRevision: string; requirements: seq[Requirement]; packages: seq[Installed]) =
  var values = newJArray()
  for item in packages:
    var dependencies = newJArray()
    for dependency in item.dependencies: dependencies.add(%dependency)
    values.add(%*{
      "name": item.name,
      "version": item.version,
      "source": "registry+" & item.name & "@" & item.version,
      "digest": item.digest,
      "direct": item.direct,
      "dependencies": dependencies,
    })
  writeFile(root / "foo.lock", pretty(%*{
    "format": "foo.lock",
    "version": 1,
    "registry": registryRevision,
    "requirements": requirementJson(requirements),
    "packages": values,
  }) & "\n")

proc reproduce(root: string; config: Registry; lock: JsonNode;
    progress: RegistryProgress = nil): seq[Installed] =
  let packages = lock.getOrDefault("packages")
  if lock.getOrDefault("format").getStr() != "foo.lock" or packages == nil or packages.kind != JArray:
    raise newException(ValueError, "Invalid foo.lock")
  var locked = initTable[string, JsonNode]()
  for item in packages:
    let name = item.getOrDefault("name").getStr()
    let version = item.getOrDefault("version").getStr()
    ensureRelease(name, version)
    if locked.hasKey(name): raise newException(ValueError, "Duplicate lockfile package: " & name)
    locked[name] = item
  for requirement in lock.getOrDefault("requirements"):
    let name = requirement["name"].getStr()
    let constraint = requirement["version"].getStr()
    if not locked.hasKey(name) or not satisfies(locked[name]["version"].getStr(), constraint):
      raise newException(ValueError, "Lockfile does not satisfy " & name & " " & constraint)
  for item in packages:
    let name = item.getOrDefault("name").getStr()
    let version = item.getOrDefault("version").getStr()
    if progress != nil: progress("fetch", name & "@" & version, "locked")
    let record = release(config, name, version)
    var installed = extractRelease(root, record)
    if installed.digest != item.getOrDefault("digest").getStr():
      raise newException(ValueError, "Lockfile digest mismatch for " & name & "@" & version)
    installed.direct = item.getOrDefault("direct").getBool()
    var expected: seq[string]
    for dependency in dependencies(record):
      if not locked.hasKey(dependency.name):
        if dependency.optional: continue
        raise newException(ValueError, "Lockfile is missing dependency " & dependency.name & " for " & name)
      let selected = locked[dependency.name]["version"].getStr()
      if not satisfies(selected, dependency.version):
        raise newException(ValueError, "Lockfile dependency conflict for " & dependency.name)
      expected.add(dependency.name & "@" & selected)
    expected.sort()
    let declared = item.getOrDefault("dependencies")
    if declared == nil or declared.kind != JArray:
      raise newException(ValueError, "Invalid lockfile dependencies for " & name)
    for dependency in declared: installed.dependencies.add(dependency.getStr())
    installed.dependencies.sort()
    if installed.dependencies != expected:
      raise newException(ValueError, "Lockfile dependency graph mismatch for " & name)
    if progress != nil:
      progress("install", installed.name & "@" & installed.version,
        "sha256:" & installed.digest[0 .. 11])
    result.add(installed)

proc install*(root: string; package = ""; progress: RegistryProgress = nil): seq[Installed] =
  let manifestPath = root / "project.json"
  if not fileExists(manifestPath): raise newException(IOError, "project.json not found")
  let config = configuration(root)
  var project = parseJson(readFile(manifestPath))
  if project.getOrDefault("dependencies").kind != JObject: project["dependencies"] = newJObject()
  if package.len > 0:
    var name = package
    var version = ""
    let marker = package.rfind('@')
    if marker > 0:
      name = package[0 ..< marker]
      version = package[marker + 1 .. ^1]
    if version.len == 0: version = "^" & findEntry(config, name).getOrDefault("version").getStr()
    ensurePackage(name, version)
    project["dependencies"][name] = %version
    writeFile(manifestPath, pretty(project) & "\n")
  let requirements = rootRequirements(project)
  if progress != nil:
    progress("resolve", "dependencies", $requirements.len & " direct requirements")
  let catalog = entries(config)
  let lockPath = root / "foo.lock"
  if package.len == 0 and fileExists(lockPath):
    let lock = parseJson(readFile(lockPath))
    if lock.getOrDefault("requirements") != nil and
        $lock.getOrDefault("requirements") == $requirementJson(requirements):
      if progress != nil:
        let revision = lock.getOrDefault("registry").getStr()
        progress("locked", "foo.lock", if revision.len >= 12: revision[0 .. 11] else: revision)
      return reproduce(root, config, lock, progress)
  removeTree(root / ".foo" / "packages")
  result = resolve(root, config, catalog.values, requirements, progress)
  writeLock(root, catalog.revision, requirements, result)
  if progress != nil: progress("lock", "foo.lock", catalog.revision[0 .. 11])

proc update*(root: string; package = ""; progress: RegistryProgress = nil): seq[Installed] =
  let manifestPath = root / "project.json"
  if not fileExists(manifestPath): raise newException(IOError, "project.json not found")
  let project = parseJson(readFile(manifestPath))
  let config = configuration(root)
  let requirements = rootRequirements(project)
  if progress != nil:
    progress("resolve", "dependencies", $requirements.len & " direct requirements")
  let catalog = entries(config)
  var resolution = requirements
  let lockPath = root / "foo.lock"
  if package.len > 0:
    if requirements.allIt(it.name != package):
      raise newException(ValueError, "Package is not a direct project dependency: " & package)
    if fileExists(lockPath):
      let lock = parseJson(readFile(lockPath))
      var locked = initTable[string, JsonNode]()
      for item in lock.getOrDefault("packages"): locked[item["name"].getStr()] = item
      var unlocked = initHashSet[string]()
      var queue = @[package]
      while queue.len > 0:
        let name = queue.pop()
        if name in unlocked: continue
        unlocked.incl(name)
        if locked.hasKey(name):
          for dependency in locked[name].getOrDefault("dependencies"):
            let identity = dependency.getStr()
            let marker = identity.rfind('@')
            if marker > 0: queue.add(identity[0 ..< marker])
      for name, item in locked:
        if name notin unlocked:
          resolution.add(Requirement(name: name, version: item["version"].getStr(), kind: "locked"))
  removeTree(root / ".foo" / "packages")
  result = resolve(root, config, catalog.values, resolution, progress)
  writeLock(root, catalog.revision, requirements, result)
  if progress != nil: progress("lock", "foo.lock", catalog.revision[0 .. 11])

proc outdated*(root: string): seq[JsonNode] =
  let lockPath = root / "foo.lock"
  if not fileExists(lockPath): raise newException(IOError, "foo.lock not found; run foo install")
  let project = parseJson(readFile(root / "project.json"))
  let catalog = entries(configuration(root))
  let lock = parseJson(readFile(lockPath))
  var locked = initTable[string, string]()
  for item in lock.getOrDefault("packages"):
    locked[item["name"].getStr()] = item["version"].getStr()
  for requirement in rootRequirements(project):
    let latest = semver.select(versions(catalog.values, requirement.name), @[requirement.version])
    let current = locked.getOrDefault(requirement.name)
    if latest.len > 0 and current.len > 0 and latest != current:
      result.add(%*{"name": requirement.name, "current": current, "latest": latest,
        "constraint": requirement.version})

proc removePackage*(root, name: string;
    progress: RegistryProgress = nil): seq[Installed] =
  if not validName(name): raise newException(ValueError, "Invalid package name: " & name)
  let path = root / "project.json"
  let project = parseJson(readFile(path))
  var removed = false
  for field in ["dependencies", "devDependencies", "optionalDependencies"]:
    let values = project.getOrDefault(field)
    if values != nil and values.kind == JObject and values.hasKey(name):
      values.delete(name)
      removed = true
  let platformValues = project.getOrDefault("platformDependencies")
  if platformValues != nil and platformValues.kind == JObject:
    for _, values in platformValues:
      if values.kind == JObject and values.hasKey(name):
        values.delete(name)
        removed = true
  if not removed: raise newException(ValueError, "Package is not a project dependency: " & name)
  writeFile(path, pretty(project) & "\n")
  let lockPath = root / "foo.lock"
  if fileExists(lockPath): removeFile(lockPath)
  if progress != nil: progress("remove", name, "project dependency")
  install(root, progress = progress)

proc deprecate*(root, package, message: string; token = ""): string =
  let marker = package.rfind('@')
  if marker <= 0 or marker == package.high:
    raise newException(ValueError, "Deprecation requires package@version")
  let name = package[0 ..< marker]
  let version = package[marker + 1 .. ^1]
  ensureRelease(name, version)
  if message.strip.len == 0: raise newException(ValueError, "Deprecation message is required")
  let credential = if token.len > 0: token else: authToken()
  if credential.len == 0: raise newException(ValueError, "Run 'foo login' before deprecating a package")
  let response = requireResponse(request(configuration(root), "/deprecate", "POST",
    $(%*{"name": name, "version": version, "message": message.strip}), credential), "Deprecation")
  response.getOrDefault("package").getStr(name) & "@" & response.getOrDefault("version").getStr(version)
