import std/[algorithm, json, os, osproc, strutils, tables, times]
import ./[compiler, options]
import ./files as discovery
import ./config as schema
import ./targets
import ../ir/node
import ../ir/eval as evaluation
import ../ast/node as syntax
import ../ast/parser
import ../lex/lexer
import ../diag/engine
import ../backend/qbe/driver as qbe
import ../pkg/hash
import ../config/project as configuration
import ./tasks as tasks

type
  Settings* = object
    backend*: string
    target*: string
    kind*: string
    cpu*: string
    mode*: string
    benchmark*: bool
    progress*: Observer
  Project* = ref object
    root*: string
    options*: Settings
    frontend: Compiler

let host* =
  when defined(windows) and defined(arm64): "windows-arm64"
  elif defined(windows): "windows-x64"
  elif defined(macosx) and defined(amd64): "macos-x64"
  elif defined(macosx): "macos-arm64"
  elif defined(arm64): "linux-arm64"
  else: "linux-x64"

proc triple*(name: string): string =
  let resolved = targets.stable(name, host)
  if targets.presets.hasKey(resolved):
    let target = targets.presets[resolved]
    result = target.arch & "-" & target.os
    if target.abi != "none" or target.os == "freestanding": result.add("-" & target.abi)
    return
  resolved

proc field(node: JsonNode; key, fallback: string): JsonNode =
  if node.hasKey(key): node[key] else: newJString(fallback)

proc strings(node: JsonNode; key: string): seq[string] =
  if node.hasKey(key) and node[key].kind == JArray:
    for value in node[key]: result.add(value.getStr())

proc boolean(node: JsonNode; key: string): bool =
  node.hasKey(key) and node[key].kind == JBool and node[key].getBool()

proc named(name: string): bool =
  if name.len == 0 or not name[0].isAlphaAscii: return false
  for character in name:
    if not (character.isAlphaNumeric or character == '-'): return false
  true

proc valid(path: string): bool =
  path.len > 3 and path.toLowerAscii().endsWith(".iv") and
    not isAbsolute(path) and ".." notin path.replace('\\', '/').split('/')

proc project*(root = getCurrentDir(); options = Settings()): Project =
  Project(root: absolutePath(root), options: options)

proc mode(project: Project; config: Build): string =
  result = if project.options.mode.len > 0: project.options.mode
    elif config.optimize.len > 0: config.optimize else: "dev"
  if result notin ["dev", "release"]:
    raise newException(ValueError, "Build mode must be dev or release")

proc manifest*(project: Project): Manifest =
  if not configuration.manifestExists(project.root): return manifest()
  let node = configuration.readProject(project.root)
  result = manifest()
  result.name = field(node, "name", result.name).getStr()
  result.version = field(node, "version", result.version).getStr()
  result.license = field(node, "license", "").getStr()
  result.language = field(node, "language", result.language).getStr()
  result.source = field(node, "source", "").getStr()
  result.entry = field(node, "entry", "").getStr()
  if result.entry.len > 0 and not valid(result.entry):
    raise newException(ValueError, "entry must be a project-relative .iv file")
  result.entries = initTable[string, string]()
  if node.hasKey("entries") and node["entries"].kind == JObject:
    for name, entry in node["entries"]:
      if not named(name):
        raise newException(ValueError,
          "Entry names begin with a letter and use letters, digits, or hyphens")
      if entry.kind != JString or not valid(entry.getStr()):
        raise newException(ValueError,
          "Entry '" & name & "' must name a project-relative .iv file")
      result.entries[name] = entry.getStr()
  result.requires = field(node, "requires", "").getStr()
  result.dependencies = initTable[string, string]()
  if node.hasKey("dependencies") and node["dependencies"].kind == JObject:
    for name, source in node["dependencies"]: result.dependencies[name] = source.getStr()
  if node.hasKey("release"):
    if node["release"].kind != JObject:
      raise newException(ValueError, "release must be an object")
    let release = node["release"]
    result.deployment.directory = field(release, "directory", "release").getStr()
    result.deployment.icon = field(release, "icon", "").getStr()
    result.deployment.license = field(release, "license", "").getStr()
    result.deployment.readme = field(release, "readme", "").getStr()
    result.deployment.files = strings(release, "files")
    if release.hasKey("sign"):
      if release["sign"].kind != JObject:
        raise newException(ValueError, "release.sign must be an object")
      result.deployment.signing.provider =
        field(release["sign"], "provider", "auto").getStr()
      result.deployment.signing.timestamp =
        field(release["sign"], "timestamp", "").getStr()
      if result.deployment.signing.provider notin
          ["auto", "gpg", "authenticode", "codesign"]:
        raise newException(ValueError,
          "release.sign.provider must be auto, gpg, authenticode, or codesign")

proc config*(project: Project): Build

proc files*(project: Project): seq[string] =
  let manifest = project.manifest()
  let config = project.config()
  var ignored = @[discovery.destination(project.root, config.output,
    @["src", "test", "benchmark"])]
  if manifest.deployment.directory.len > 0:
    ignored.add(discovery.destination(project.root, manifest.deployment.directory,
      @["src", "test", "benchmark", relativePath(ignored[0], project.root)]))
  discover(project.root, manifest.source, ignored)

proc config*(project: Project): Build =
  let node = configuration.readProject(project.root)
  result.products = initTable[string, schema.Product]()
  result.target = @[]
  if node.hasKey("build") and node["build"].kind == JObject:
    let build = node["build"]
    result.backend = field(build, "backend", "").getStr()
    result.compiler = field(build, "compiler", "").getStr()
    result.optimize = field(build, "optimize", "dev").getStr()
    result.`type` = field(build, "type", "").getStr()
    result.substrate = field(build, "substrate", "").getStr()
    result.runtime = field(build, "runtime", "").getStr()
    result.coverage = field(build, "coverage", "").getStr()
    result.profile = field(build, "profile", "").getStr()
    result.cpu = field(build, "cpu", "").getStr()
    result.sanitize = field(build, "sanitize", "").getStr()
    result.output = field(build, "output", "output").getStr()
    result.icon = field(build, "icon", "").getStr()
    result.semantic = boolean(build, "semantic")
    result.docs = boolean(build, "docs")
    result.debug = boolean(build, "debug")
    if build.hasKey("target"):
      if build["target"].kind == JArray:
        for target in build["target"]: result.target.add(target.getStr())
      elif build["target"].kind == JString:
        result.target.add(build["target"].getStr())
    if build.hasKey("products") and build["products"].kind == JObject:
      for name, product in build["products"]:
        result.products[name] = schema.Product(entry: product.getOrDefault("entry").getStr(), kind: field(product, "kind", "").getStr(),
          needs: strings(product, "needs"), soname: product.getOrDefault("soname").getStr(), version: product.getOrDefault("version").getStr(),
          script: product.getOrDefault("script").getStr(), exports: product.getOrDefault("exports").getStr(), rpath: strings(product, "rpath"))
    result.tasks = build.getOrDefault("tasks")
    result.hooks = build.getOrDefault("hooks")
    if result.hooks != nil and result.hooks.kind != JNull:
      if result.hooks.kind != JObject: raise newException(ValueError, "build.hooks must be an object")
      for name, command in result.hooks:
        if name notin ["prebuild", "postbuild"] or command.kind != JString or command.getStr().len == 0:
          raise newException(ValueError, "build.hooks supports nonempty prebuild and postbuild commands")
    result.resources = strings(build, "resources")
    if build.hasKey("native") and build["native"].kind == JObject:
      result.native.substrate = field(build["native"], "substrate", "").getStr()
      result.native.clobbers = strings(build["native"], "clobbers")
    if build.hasKey("c") and build["c"].kind == JObject:
      let c = build["c"]
      result.c.`include` = strings(c, "include")
      result.c.sysroot = field(c, "sysroot", "").getStr()
      result.c.flags = strings(c, "flags")
      if c.hasKey("sources"):
        for source in c["sources"]: result.c.sources.add(source)
    if build.hasKey("link") and build["link"].kind == JObject:
      let link = build["link"]
      result.link.libs = strings(link, "libs")
      result.link.frameworks = strings(link, "frameworks")
      result.link.cpp = link.getOrDefault("cpp").getBool()
      result.link.soname = link.getOrDefault("soname").getStr()
      result.link.version = link.getOrDefault("version").getStr()
      result.link.script = link.getOrDefault("script").getStr()
      result.link.exports = link.getOrDefault("exports").getStr()
      result.link.rpath = strings(link, "rpath")
  if result.backend.len > 0 and result.backend != "qbe":
    raise newException(ValueError, "Unknown backend '" & result.backend & "'")
  if result.substrate.len > 0 and result.substrate notin ["auto", "c"]:
    raise newException(ValueError, "build.substrate must be auto or c")
  if result.native.substrate.len > 0 and result.native.substrate notin ["c", "asm"]:
    raise newException(ValueError, "build.native.substrate must be c or asm")

proc compiler*(project: Project): Compiler =
  if project.frontend != nil: return project.frontend
  let config = project.config()
  let backend = if project.options.backend.len > 0: project.options.backend else: (if config.backend.len > 0: config.backend else: "qbe")
  if backend != "qbe": raise newException(ValueError, "Unknown backend '" & backend & "'")
  let mode = project.mode(config)
  let architecture = if project.options.target.len > 0:
      targets.stable(project.options.target, host)
    else: targets.choose(config.target, host)
  let processor = if project.options.cpu.len > 0: project.options.cpu else: config.cpu
  let tuning = if config.profile.len == 0: ""
    elif isAbsolute(config.profile): config.profile else: project.root / config.profile
  var includes: seq[string]
  for path in config.c.`include`:
    includes.add(if isAbsolute(path): path else: project.root / path)
  let sysroot = if config.c.sysroot.len == 0: ""
    elif isAbsolute(config.c.sysroot): config.c.sysroot
    else: project.root / config.c.sysroot
  project.frontend = compiler(project.root, backend, includes, mode,
    mode == "release" or config.semantic, triple(architecture), processor,
    tuning, config.runtime, sysroot)
  project.frontend

proc tasks(config: Build): Table[string, tasks.Task] =
  result = initTable[string, tasks.Task]()
  if config.tasks != nil and config.tasks.kind == JObject:
    for name, value in config.tasks:
      var task = tasks.Task(kind: value.getOrDefault("kind").getStr(),
        output: value.getOrDefault("output").getStr(), text: value.getOrDefault("text").getStr(),
        needs: strings(value, "needs"), inputs: strings(value, "inputs"), values: initTable[string, JsonNode]())
      if value.hasKey("values") and value["values"].kind == JObject:
        for key, item in value["values"]: task.values[key] = item
      result[name] = task
  if config.resources.len > 0:
    if result.hasKey("resources"): raise newException(ValueError, "build.resources reserves the task name 'resources'")
    result["resources"] = tasks.Task(kind: "embed", output: "resources", inputs: config.resources)

proc destination(project: Project; config: Build): string =
  let source = if project.manifest().source.len > 0:
      project.manifest().source else: "src"
  var protected = @["src", "test", "benchmark"]
  if source notin [".", "src"]: protected.add(source)
  discovery.destination(project.root, config.output, protected)

proc prepare(project: Project; config: Build) =
  let definitions = tasks(config)
  if definitions.len > 0:
    discard tasks.tasks(project.root, definitions,
      excluded = @[project.destination(config), project.root / ".foo"])

proc task*(project: Project; selected: seq[string] = @[]): seq[string] =
  let config = project.config()
  tasks.tasks(project.root, tasks(config), selected,
    @[project.destination(config), project.root / ".foo"])

var stamp = ""

proc identity*(): string =
  if stamp.len == 0:
    let executable = getAppFilename()
    stamp = if fileExists(executable):
      checksum(executable)
    else:
      digest(executable)
  stamp

proc identity*(checksum, translator, backend, target, entry,
    mode, native: string; semantic: bool): string =
  digest($(%*{
    "project": checksum,
    "compiler": translator,
    "backend": backend,
    "target": target,
    "entry": entry,
    "mode": mode,
    "semantic": semantic,
    "native": native
  }))

proc graph*(project: Project): JsonNode = project.compiler().graph(project.files())

proc runnable(file: string; target = ""): bool =
  let source = readFile(file)
  let diagnostics = engine()
  diagnostics.source(source, file)
  let parsed = parser(lexer(source, diagnostics).lex(), diagnostics).parse()
  if diagnostics.failed: return false
  evaluation.expand(parsed, target)
  prepare(parsed)
  for unit in parsed.units:
    for statement in unit.body.stmts:
      if statement.tag == "function" and syntax.Function(statement).name.text == "start":
        return true

proc inferredKind*(target: string; runnable: bool): string =
  if target == "spirv-vulkan1.3": return "shader"
  if runnable: return "exe"
  if target == "uefi-x64":
    raise newException(ValueError, "UEFI requires a start entry; no library output is supported for this target")
  if target.startsWith("wasm") or target.startsWith("wasi"):
    return "object"
  "static"

proc inferredKind*(target, file: string): string =
  inferredKind(target, runnable(file, triple(target)))

proc entry*(project: Project; entry = ""): string =
  var selected = ""
  if entry.len > 0:
    let manifest = project.manifest()
    if manifest.entries.hasKey(entry):
      selected = confined(project.root, manifest.entries[entry])
    else:
      selected = if isAbsolute(entry): entry else: confined(project.root, entry)
  elif project.manifest().entry.len > 0:
    selected = confined(project.root, project.manifest().entry)
  else:
    let directory = project.manifest().source
    let conventional = if directory.len > 0:
      project.root / directory / "main.iv" else: project.root / "main.iv"
    if fileExists(conventional): selected = absolutePath(conventional)
    for file in project.files():
      if runnable(file, project.compiler().target):
        if selected.len > 0 and selected != file:
          raise newException(ValueError, "Multiple application entries found")
        selected = file
    if selected.len == 0 and project.files().len == 1: selected = project.files()[0]
  if selected.len == 0:
    raise newException(ValueError,
      "No unique source entry found; set 'entry' in " &
        configuration.manifestPath(project.root).lastPathPart & " or add main.iv")
  if not fileExists(selected):
    raise newException(ValueError, "Application entry not found: " & selected)
  selected

proc ir*(project: Project; entry = ""): Module =
  project.compiler().ir(project.entry(entry))

proc check*(project: Project; entry = "") =
  project.prepare(project.config())
  let selected = if entry.len > 0:
      @[project.entry(entry)]
    else: project.files()
  for file in selected:
    let name = relativePath(file, project.root).replace('\\', '/')
    if project.options.progress != nil:
      project.options.progress("check", name, file, false)
    discard project.compiler().check(file)
    if project.options.progress != nil:
      project.options.progress("checked", name, "", false)

proc hook(project: Project; config: Build; name: string) =
  if config.hooks == nil or config.hooks.kind != JObject or not config.hooks.hasKey(name): return
  let response = execCmdEx(config.hooks[name].getStr(), workingDir = project.root)
  if response.output.len > 0: stderr.write(response.output)
  if response.exitCode != 0:
    raise newException(OSError, "Build hook '" & name & "' failed")

proc reusable(config: Build; product: schema.Product; explicitEntry: bool): bool =
  product.kind in ["", "exe"] and product.needs.len == 0 and
    (config.hooks == nil or config.hooks.kind == JNull) and
    (config.tasks == nil or config.tasks.kind == JNull) and
    config.resources.len == 0 and config.products.len == 0 and
    config.c.sources.len == 0 and config.c.`include`.len == 0 and
    config.c.flags.len == 0 and config.c.sysroot.len == 0 and
    config.link.libs.len == 0 and config.link.frameworks.len == 0 and
    config.link.script.len == 0 and config.link.exports.len == 0 and
    config.link.rpath.len == 0 and not config.link.cpp and
    config.icon.len == 0 and config.profile.len == 0 and
    explicitEntry

proc inventory(project: Project): string =
  var paths = project.files()
  paths.sort()
  for path in paths: result.add(path.replace('\\', '/') & "\n")

proc reused(route, key, sources, artifact, published: string): bool =
  try:
    if not fileExists(route): return false
    let data = parseFile(route)
    if data["version"].getInt() != 1 or data["key"].getStr() != key or
        data["sources"].getStr() != sources or
        data["artifact"].getStr() != artifact or
        data["published"].getStr() != published: return false
    for input in data["inputs"]:
      let path = input["path"].getStr()
      let expected = input["sha256"].getStr()
      if (if fileExists(path): checksum(path) else: "absent") != expected:
        return false
    for output in data["outputs"]:
      let path = output["path"].getStr()
      if not fileExists(path) or checksum(path) != output["sha256"].getStr():
        return false
    result = true
  except CatchableError:
    result = false

proc persist(route, key, fingerprint, sources, artifact, published: string;
    inputs: seq[tuple[path: string, sha256: string]]) =
  var listed = newJArray()
  for input in inputs:
    listed.add(%*{"path": input.path, "sha256": input.sha256})
  var outputs = newJArray()
  for path in [artifact, artifact & ".qbe.json", published,
      published & ".qbe.json", parentDir(artifact) / "optimization.json"]:
    if not fileExists(path):
      write(route, $(%*{"fingerprint": fingerprint, "artifact": artifact}))
      return
    outputs.add(%*{"path": path, "sha256": checksum(path)})
  write(route, $(%*{"version": 1, "key": key,
    "fingerprint": fingerprint, "sources": sources,
    "artifact": artifact, "published": published, "inputs": listed,
    "outputs": outputs}))

proc build*(project: Project; entry = ""; executable = false): Table[string, string] =
  let profiling = getEnv("FOO_BUILD_PROFILE") == "1"
  var clock = epochTime()
  proc mark(stage: string) =
    if profiling:
      let now = epochTime()
      stderr.writeLine("build-profile project " & stage & " " &
        $(int((now - clock) * 1000 + 0.5)) & " ms")
      clock = now
  let config = project.config()
  project.hook(config, "prebuild")
  let units = project.files()
  if entry.len == 0 and units.len > 1: project.check(entry)
  let artifacts = new(Table[string, string])
  artifacts[] = initTable[string, string]()
  let internals = new(Table[string, string])
  internals[] = initTable[string, string]()
  var products = project.config().products
  let catalog = products.len > 0 and entry.len == 0
  if products.len == 0:
    products["app"] = schema.Product(entry: entry, kind: if project.options.kind.len > 0:
      project.options.kind else: config.`type`)
  elif project.options.kind.len > 0:
    raise newException(ValueError,
      "--kind applies only to a project without named build.products")
  let backend = if project.options.backend.len > 0: project.options.backend else: (if config.backend.len > 0: config.backend else: "qbe")
  if backend != "qbe": raise newException(ValueError, "Unknown backend '" & backend & "'")
  project.prepare(config)
  let directory = project.destination(config)
  let translator = identity()
  mark("setup")
  proc publish(artifact, target: string) =
    copyFileWithPermissions(artifact, target)
    for suffix in [".dependencies.json", ".qbe.json"]:
      if fileExists(artifact & suffix):
        copyFile(artifact & suffix, target & suffix)
      elif fileExists(target & suffix):
        removeFile(target & suffix)
    if artifact.endsWith(".spv") and fileExists(artifact & ".json"):
      copyFile(artifact & ".json", target & ".json")
    let metadata = artifact & ".qbe.json"
    if fileExists(metadata):
      let descriptor = parseFile(metadata)
      if descriptor.hasKey("sharedAliases"):
        for entry in descriptor["sharedAliases"]:
          let name = entry.getStr()
          if name != name.lastPathPart or name in ["", ".", ".."]:
            raise newException(ValueError, "Unsafe shared-library alias: " & name)
          copyFileWithPermissions(artifact.parentDir / name, target.parentDir / name)
    let pdb = false
    for extension in ["pdb", "lib"]:
      let sidecar = changeFileExt(artifact, extension)
      if sidecar == artifact: continue
      let published = changeFileExt(target, extension)
      if fileExists(sidecar) and (extension != "pdb" or pdb):
        copyFileWithPermissions(sidecar, published)
      elif fileExists(published):
        removeFile(published)
    let shared = artifact.parentDir / "libcurl.so.4"
    if fileExists(shared):
      copyFileWithPermissions(shared, target.parentDir / shared.lastPathPart)
  var active = initTable[string, bool]()
  var kinds = initTable[string, string]()
  proc visit(name: string) =
    if artifacts[].hasKey(name): return
    if active.getOrDefault(name): raise newException(ValueError, "Product dependency cycle at '" & name & "'")
    if not products.hasKey(name): raise newException(ValueError, "Unknown product '" & name & "'")
    active[name] = true
    let product = products[name]
    for dependency in product.needs:
      if not products.hasKey(dependency): raise newException(ValueError, "Unknown product '" & dependency & "'")
      visit(dependency)
      if kinds[dependency] == "exe":
        raise newException(ValueError, "Product '" & name & "' cannot link executable '" & dependency & "'")
    let selected = project.entry(if product.entry.len > 0: product.entry else: entry)
    let platform = if project.options.target.len > 0:
        targets.stable(project.options.target, host)
      else: targets.choose(config.target, host)
    # Keep the named preset for QBE target selection and artifact identity.
    let target = if product.kind == "shader" and
        project.options.target.len == 0 and config.target.len == 0:
        "spirv-vulkan1.3"
      else: platform
    let kind = if product.kind.len > 0: product.kind
      else: inferredKind(target, selected)
    if executable and products.len == 1 and kind != "exe":
      raise newException(ValueError,
        "Cannot run a " & kind & " product; select an executable entry or use --kind exe")
    if kind == "static" and product.needs.len > 0:
      raise newException(ValueError, "Static archives cannot contain dependent libraries")
    kinds[name] = kind
    let output = if catalog:
      project.root / ".artifacts" / "build" / name
    else:
      project.root / ".artifacts" / "build"
    createDir(output)
    var paths: seq[string]
    for source in config.c.sources:
      let relative = if source.kind == JString: source.getStr() else: source.getOrDefault("path").getStr()
      if relative.len > 0: paths.add(if isAbsolute(relative): relative else: project.root / relative)
    var objects: seq[string]
    for dependency in product.needs: objects.add(internals[][dependency])
    var includes: seq[string]
    for path in config.c.`include`: includes.add(if isAbsolute(path): path else: project.root / path)
    let settings = if config.profile.len == 0: ""
      elif isAbsolute(config.profile): config.profile else: project.root / config.profile
    let frontend = config.compiler
    proc path(value: string): string =
      if value.len == 0 or isAbsolute(value): value else: project.root / value
    var libraries: seq[string]
    for library in config.link.libs:
      let local = project.root / library
      libraries.add(if isAbsolute(library) or
          (not library.contains('/') and not library.contains('\\') and
            not fileExists(local)):
          library else: path(library))
    let facilities = options.Native(name: name, kind: kind, target: target,
      compile: true, compiler: frontend, runtime: config.runtime, sources: paths,
      icon: path(config.icon),
      includes: includes, flags: config.c.flags, libs: libraries, frameworks: config.link.frameworks,
      objects: objects, cpp: config.link.cpp, soname: if product.soname.len > 0: product.soname else: config.link.soname,
      version: if product.version.len > 0: product.version else: config.link.version,
      script: path(if product.script.len > 0: product.script else: config.link.script),
      exports: path(if product.exports.len > 0: product.exports else: config.link.exports),
      rpath: if product.rpath.len > 0: product.rpath else: config.link.rpath,
      level: if project.manifest().requires.len > 0:
        project.manifest().requires else: "base",
      native: Boundary(substrate: config.native.substrate,
        clobbers: config.native.clobbers), substrate: config.substrate,
      cpu: if project.options.cpu.len > 0: project.options.cpu else: config.cpu,
      coverage: config.coverage,
      profile: if settings.len > 0 and fileExists(settings):
        digest(readFile(settings)) else: "",
      sanitize: config.sanitize, docs: config.docs, debug: config.debug,
      benchmark: project.options.benchmark,
      threads: target == "wasi-threads" or (target.startsWith("wasm32") and target.contains("threads")))
    let published = directory / artifact(facilities)
    let mode = project.mode(config)
    let route = output / "build.json"
    if project.options.progress != nil:
      project.options.progress("build", name, "", false)
    var success = false
    var location, failure, fingerprint: string
    var inputs: seq[tuple[path: string, sha256: string]]
    let policy = qbe.identity(mode, facilities)
    mark("tool-identity")
    let fast = reusable(config, product, entry.len > 0 or units.len == 1) and
      not project.options.benchmark and
      not dirExists(project.root / ".foo" / "packages")
    var sources, fastKey: string
    if fast:
      sources = project.inventory()
      fastKey = digest(translator & policy & "\n" &
        $facilities & "\n" & selected & "\n" & $config.semantic & "\n" &
        getEnv("FOO_LIB") & "\n" &
        (if configuration.manifestExists(project.root):
          configuration.fingerprint(project.root) else: "absent"))
      let existing = output / artifact(facilities)
      if reused(route, fastKey, sources, existing, published):
        mark("validated-hit")
        if project.options.progress != nil:
          project.options.progress("checked", name, "", true)
        internals[][name] = existing
        artifacts[][name] = published
        if project.options.progress != nil:
          project.options.progress("done", name, published, true)
        active.del(name)
        return
    try:
      let compiled = project.compiler().ir(selected)
      mark("frontend")
      if project.options.progress != nil:
        project.options.progress("checked", name, "", false)
      inputs = compiled.inputs
      var content = ""
      for input in compiled.inputs:
        content.add(input.path & "\0" & input.sha256 & "\n")
      fingerprint = identity(digest(content), translator & policy,
        backend, target, selected, mode, $facilities, config.semantic)
      writeFile(output / "optimization.json", pretty(%*{
        "genericSpecializations": compiled.optimization.generics,
        "expressionsEliminated": compiled.optimization.expressions,
        "functionsMerged": compiled.optimization.functions,
        "deadInstructionsEliminated": compiled.optimization.dead,
        "callsInlined": compiled.optimization.inlined,
        "callbacksSpecialized": compiled.optimization.callbacks,
        "boundariesEliminated": compiled.optimization.boundaries,
        "allocationsEliminated": compiled.optimization.allocations,
        "pipelinesFused": compiled.optimization.pipelines,
        "continuationsSpecialized": compiled.optimization.continuations,
        "serializationsSpecialized": compiled.optimization.serializations,
        "boundsChecksEliminated": compiled.optimization.bounds
      }) & "\n")
      let built = qbe.build(compiled, mode, output, facilities, selected,
        project.options.progress, policy)
      mark("backend")
      success = built.success; location = built.artifact; failure = built.error
    except CatchableError:
      if project.options.progress != nil: project.options.progress("failed", name, "", false)
      raise
    if not success:
      if project.options.progress != nil: project.options.progress("failed", name, "", false)
      raise newException(OSError, if failure.len > 0: failure else: "Build failed")
    internals[][name] = location
    if project.options.benchmark:
      artifacts[][name] = location
    else:
      createDir(directory)
      publish(location, published)
      mark("publish")
      artifacts[][name] = published
    if fast:
      persist(route, fastKey, fingerprint, sources, location, published,
        inputs)
    else:
      write(route, $(%*{"fingerprint": fingerprint, "artifact": location}))
    if project.options.progress != nil:
      project.options.progress("done", name, artifacts[][name], false)
    active.del(name)
  for name in products.keys: visit(name)
  project.hook(config, "postbuild")
  result = artifacts[]
