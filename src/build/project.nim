import std/[json, os, strutils, tables]
import ./[compiler, config, files, options]
import ../targets/presets as targetPresets
import ../ir/node
import ../backend/zig/driver as zigDriver
import ../backend/c/driver as cDriver
import ../toolchain/manager
import ../pkg/hash
import ./tasks as buildTasks

type
  ProjectOptions* = object
    backend*: string
    target*: string
    cpu*: string
    progress*: proc(phase, name, file: string; cached: bool) {.closure.}
  Project* = ref object
    root*: string
    options*: ProjectOptions
    cachedCompiler: Compiler

let host* = when defined(windows): "windows-x64" elif defined(macosx): "macos-arm64" elif defined(arm64): "linux-arm64" else: "linux-x64"

proc triple*(name: string): string =
  if targetPresets.presets.hasKey(name):
    let target = targetPresets.presets[name]
    result = target.arch & "-" & target.os
    if target.abi != "none" or target.os == "freestanding": result.add("-" & target.abi)
    return
  case name
  of "linux": "x86_64-linux-gnu"
  of "darwin": "aarch64-macos"
  of "windows": "x86_64-windows-msvc"
  else: name

proc field(node: JsonNode; key, fallback: string): JsonNode =
  if node.hasKey(key): node[key] else: newJString(fallback)

proc strings(node: JsonNode; key: string): seq[string] =
  if node.hasKey(key) and node[key].kind == JArray:
    for value in node[key]: result.add(value.getStr())

proc boolean(node: JsonNode; key: string): bool =
  node.hasKey(key) and node[key].kind == JBool and node[key].getBool()

proc newProject*(root = getCurrentDir(); options = ProjectOptions()): Project =
  Project(root: absolutePath(root), options: options)

proc manifest*(project: Project): Manifest =
  let file = project.root / "project.json"
  if not fileExists(file): return defaultManifest()
  let node = parseJson(readFile(file))
  result = defaultManifest()
  result.name = field(node, "name", result.name).getStr()
  result.version = field(node, "version", result.version).getStr()
  result.license = field(node, "license", "").getStr()
  result.language = field(node, "language", result.language).getStr()
  result.source = field(node, "source", "").getStr()
  result.entry = field(node, "entry", "").getStr()
  result.requires = field(node, "requires", "").getStr()
  result.dependencies = initTable[string, string]()
  if node.hasKey("dependencies") and node["dependencies"].kind == JObject:
    for name, source in node["dependencies"]: result.dependencies[name] = source.getStr()

proc files*(project: Project): seq[string] =
  discover(project.root, project.manifest().source)

proc config*(project: Project): BuildConfig =
  let file = project.root / "project.json"
  let node = parseJson(if fileExists(file): readFile(file) else: "{}")
  result.products = initTable[string, ProductConfig]()
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
    result.cpu = field(build, "cpu", "").getStr()
    result.sanitize = field(build, "sanitize", "").getStr()
    result.semantic = boolean(build, "semantic")
    result.docs = boolean(build, "docs")
    if build.hasKey("target"):
      if build["target"].kind == JArray:
        for target in build["target"]: result.target.add(target.getStr())
      elif build["target"].kind == JString:
        result.target.add(build["target"].getStr())
    if build.hasKey("products") and build["products"].kind == JObject:
      for name, product in build["products"]:
        result.products[name] = ProductConfig(entry: product.getOrDefault("entry").getStr(), kind: field(product, "kind", "exe").getStr(),
          needs: strings(product, "needs"), soname: product.getOrDefault("soname").getStr(), version: product.getOrDefault("version").getStr(),
          script: product.getOrDefault("script").getStr(), exports: product.getOrDefault("exports").getStr(), rpath: strings(product, "rpath"))
    result.tasks = build.getOrDefault("tasks")
    result.resources = strings(build, "resources")
    if build.hasKey("native") and build["native"].kind == JObject:
      result.native.substrate = field(build["native"], "substrate", "").getStr()
      result.native.clobbers = strings(build["native"], "clobbers")
    if build.hasKey("c") and build["c"].kind == JObject:
      let c = build["c"]
      result.c.`include` = strings(c, "include")
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
  if result.backend.len > 0 and result.backend notin ["zig", "c"]:
    raise newException(ValueError, "Unknown backend '" & result.backend & "'")
  if result.substrate.len > 0 and result.substrate notin ["auto", "c"]:
    raise newException(ValueError, "build.substrate must be auto or c")
  if result.native.substrate.len > 0 and result.native.substrate notin ["c", "asm"]:
    raise newException(ValueError, "build.native.substrate must be c or asm")

proc compiler*(project: Project): Compiler =
  if project.cachedCompiler != nil: return project.cachedCompiler
  let config = project.config()
  let backend = if project.options.backend.len > 0: project.options.backend else: (if config.backend.len > 0: config.backend else: "zig")
  let mode = if config.optimize.len > 0: config.optimize else: "dev"
  let selectedTarget = if project.options.target.len > 0: project.options.target
    elif config.target.len > 0: config.target[0] else: host
  let selectedCpu = if project.options.cpu.len > 0: project.options.cpu else: config.cpu
  var includes: seq[string]
  for path in config.c.`include`:
    includes.add(if isAbsolute(path): path else: project.root / path)
  project.cachedCompiler = newCompiler(project.root, backend, includes, mode,
    mode == "release" or config.semantic, triple(selectedTarget), selectedCpu)
  project.cachedCompiler

proc taskDefinitions(config: BuildConfig): Table[string, buildTasks.Task] =
  result = initTable[string, buildTasks.Task]()
  if config.tasks != nil and config.tasks.kind == JObject:
    for name, value in config.tasks:
      var task = buildTasks.Task(kind: value.getOrDefault("kind").getStr(),
        output: value.getOrDefault("output").getStr(), text: value.getOrDefault("text").getStr(),
        needs: strings(value, "needs"), inputs: strings(value, "inputs"), values: initTable[string, JsonNode]())
      if value.hasKey("values") and value["values"].kind == JObject:
        for key, item in value["values"]: task.values[key] = item
      result[name] = task
  if config.resources.len > 0:
    if result.hasKey("resources"): raise newException(ValueError, "build.resources reserves the task name 'resources'")
    result["resources"] = buildTasks.Task(kind: "embed", output: "resources", inputs: config.resources)

proc prepare(project: Project; config: BuildConfig) =
  let definitions = taskDefinitions(config)
  if definitions.len > 0: discard buildTasks.tasks(project.root, definitions)

proc task*(project: Project; selected: seq[string] = @[]): seq[string] =
  buildTasks.tasks(project.root, taskDefinitions(project.config()), selected)

proc graph*(project: Project): JsonNode = project.compiler().graph(project.files())

proc entryPath(project: Project; entry = ""): string =
  var selected = ""
  if entry.len > 0:
    selected = if isAbsolute(entry): entry else: absolutePath(project.root / entry)
  elif project.manifest().entry.len > 0:
    selected = absolutePath(project.root / project.manifest().entry)
  else:
    for file in project.files():
      if readFile(file).contains("start("):
        if selected.len > 0: raise newException(ValueError, "Multiple start() entries found")
        selected = file
  if selected.len == 0: raise newException(ValueError, "No start() entry found in project sources")
  selected

proc ir*(project: Project; entry = ""): Module =
  project.compiler().ir(project.entryPath(entry))

proc check*(project: Project; entry = "") =
  project.prepare(project.config())
  if project.options.progress != nil: project.options.progress("check", "project", entry, false)
  if entry.len > 0:
    discard project.compiler().check(if isAbsolute(entry): entry else: absolutePath(project.root / entry))
  else:
    for file in project.files(): discard project.compiler().check(file)

proc build*(project: Project; entry = ""): Table[string, string] =
  project.check(entry)
  let artifacts = new(Table[string, string])
  artifacts[] = initTable[string, string]()
  var products = project.config().products
  let namedProducts = products.len > 0 and entry.len == 0
  if products.len == 0:
    products["app"] = ProductConfig(entry: entry,
      kind: if project.config().`type`.len > 0:
        project.config().`type` else: "exe")
  let config = project.config()
  let backend = if project.options.backend.len > 0: project.options.backend else: (if config.backend.len > 0: config.backend else: "zig")
  project.prepare(config)
  let tool = if backend == "zig": install(pin(project.root)).path else: ""
  var active = initTable[string, bool]()
  proc visit(name: string) =
    if artifacts[].hasKey(name): return
    if active.getOrDefault(name): raise newException(ValueError, "Product dependency cycle at '" & name & "'")
    if not products.hasKey(name): raise newException(ValueError, "Unknown product '" & name & "'")
    active[name] = true
    let product = products[name]
    for dependency in product.needs:
      if not products.hasKey(dependency): raise newException(ValueError, "Unknown product '" & dependency & "'")
      if products[dependency].kind.len == 0 or products[dependency].kind == "exe":
        raise newException(ValueError, "Product '" & name & "' cannot link executable '" & dependency & "'")
      visit(dependency)
    if product.kind == "static" and product.needs.len > 0:
      raise newException(ValueError, "Static archives cannot contain dependent libraries")
    let selected = project.entryPath(if product.entry.len > 0: product.entry else: entry)
    if project.options.progress != nil: project.options.progress("build", name, selected, false)
    discard project.ir(selected)
    let target = triple(if project.options.target.len > 0: project.options.target elif config.target.len > 0: config.target[0] else: host)
    let output = if namedProducts:
      project.root / ".artifacts" / "build" / name
    else:
      project.root / ".artifacts" / "build"
    createDir(output)
    var sourcePaths: seq[string]
    for source in config.c.sources:
      let relative = if source.kind == JString: source.getStr() else: source.getOrDefault("path").getStr()
      if relative.len > 0: sourcePaths.add(if isAbsolute(relative): relative else: project.root / relative)
    var objects: seq[string]
    for dependency in product.needs: objects.add(artifacts[][dependency])
    var includes: seq[string]
    for path in config.c.`include`: includes.add(if isAbsolute(path): path else: project.root / path)
    let nativeOptions = Native(name: name, kind: if product.kind.len > 0: product.kind else: "exe", target: target,
      compile: true, compiler: config.compiler, runtime: config.runtime, sources: sourcePaths,
      includePaths: includes, flags: config.c.flags, libs: config.link.libs, frameworks: config.link.frameworks,
      objects: objects, cpp: config.link.cpp, soname: if product.soname.len > 0: product.soname else: config.link.soname,
      version: if product.version.len > 0: product.version else: config.link.version,
      script: if product.script.len > 0: product.script else: config.link.script,
      exports: if product.exports.len > 0: product.exports else: config.link.exports,
      rpath: if product.rpath.len > 0: product.rpath else: config.link.rpath,
      level: if project.manifest().requires.len > 0:
        project.manifest().requires else: "base",
      native: NativeBinding(substrate: config.native.substrate,
        clobbers: config.native.clobbers), substrate: config.substrate,
      cpu: if project.options.cpu.len > 0: project.options.cpu else: config.cpu,
      coverage: config.coverage, sanitize: config.sanitize, docs: config.docs,
      threads: target.startsWith("wasm32") and target.contains("threads"))
    let artifactPathExpected = output / artifact(nativeOptions)
    let fingerprint = sha256Hex(hashDirectory(project.root) & backend & target & $nativeOptions)
    let cachePath = output / "build.json"
    if fileExists(cachePath) and fileExists(artifactPathExpected):
      let cache = parseJson(readFile(cachePath))
      if cache.getOrDefault("fingerprint").getStr() == fingerprint:
        artifacts[][name] = artifactPathExpected
        active.del(name)
        if project.options.progress != nil: project.options.progress("reuse", name, artifactPathExpected, true)
        return
    var success = false
    var artifactPath, buildError: string
    if backend == "c":
      let built = cDriver.build(project.compiler().ir(selected),
        if config.optimize.len > 0: config.optimize else: "dev", output,
        nativeOptions, selected)
      success = built.success; artifactPath = built.artifact; buildError = built.error
    else:
      let built = zigDriver.build(project.compiler().ir(selected), if config.optimize.len > 0: config.optimize else: "dev", output, tool, selected, nativeOptions)
      success = built.success; artifactPath = built.artifact; buildError = built.error
    if not success: raise newException(OSError, if buildError.len > 0: buildError else: "Build failed")
    artifacts[][name] = artifactPath
    write(cachePath, $(%*{"fingerprint": fingerprint, "artifact": artifactPath}))
    if project.options.progress != nil: project.options.progress("done", name, artifactPath, false)
    active.del(name)
  for name in products.keys: visit(name)
  result = artifacts[]
