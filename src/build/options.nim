import std/[os, osproc, strutils]

type
  Observer* = proc(phase, name, detail: string; cached: bool) {.closure.}
  Boundary* = object
    substrate*: string
    clobbers*: seq[string]
  Product* = object
    entry*: string
    kind*: string
    needs*: seq[string]
    soname*: string
    version*: string
    script*: string
    exports*: string
    rpath*: seq[string]
  Native* = object
    level*: string
    native*: Boundary
    substrate*: string
    name*: string
    kind*: string
    soname*: string
    version*: string
    exports*: string
    script*: string
    rpath*: seq[string]
    target*: string
    cpu*: string
    coverage*: string
    profile*: string
    sanitize*: string
    runtime*: string
    docs*: bool
    benchmark*: bool
    threads*: bool
    jobs*: int
    debug*: bool
    run*: bool
    compile*: bool
    compiler*: string
    icon*: string
    sources*: seq[string]
    includes*: seq[string]
    flags*: seq[string]
    libs*: seq[string]
    frameworks*: seq[string]
    objects*: seq[string]
    cpp*: bool

proc jobs*(intensive = false): int =
  let processors = max(1, countProcessors())
  let configured = getEnv("FOO_BUILD_JOBS")
  if configured.len > 0:
    try:
      return min(processors, max(1, parseInt(configured)))
    except ValueError:
      raise newException(ValueError, "FOO_BUILD_JOBS must be a positive integer")
  let reserved = if intensive: 1 else: max(1, (processors + 3) div 4)
  max(1, processors - reserved)

proc artifact*(options: Native): string =
  let label = if options.name.len > 0: options.name else: "app"
  let kind = if options.kind.len > 0: options.kind else: "exe"
  for character in label:
    if not (character.isAlphaNumeric or character in {'_', '-'}): raise newException(ValueError, "Invalid product name '" & label & "'")
  let windows = if options.target.len > 0: options.target.contains("windows") else: defined(windows)
  let mac = if options.target.len > 0: options.target.contains("macos") or options.target.contains("darwin") else: defined(macosx)
  if kind == "static": return if windows: label & ".lib" else: "lib" & label & ".a"
  if kind == "shared": return if windows: label & ".dll" elif mac: "lib" & label & ".dylib" else: "lib" & label & ".so" & (if options.version.len > 0: "." & options.version else: "")
  if kind == "object": return label & (if windows: ".obj" else: ".o")
  if kind == "shader": return label & ".spv"
  if options.target == "uefi-x64": return label & ".efi"
  if options.target.startsWith("wasm") or options.target.startsWith("wasi"):
    label & ".wasm"
  elif windows: label & ".exe"
  else: label

proc validate*(options: Native) =
  discard artifact(options)
  if options.kind.len > 0 and options.kind notin ["exe", "static", "shared", "object", "shader"]: raise newException(ValueError, "Unknown product kind '" & options.kind & "'")
  if options.kind == "shader" and options.target != "spirv-vulkan1.3":
    raise newException(ValueError, "Shader products require target spirv-vulkan1.3")
  if options.version.len > 0 and options.version.split('.').len != 3: raise newException(ValueError, "Library version must be major.minor.patch")
  if (options.soname.len > 0 or options.version.len > 0) and options.kind != "shared": raise newException(ValueError, "soname and version require a shared library")
  if options.kind == "static" and (options.rpath.len > 0 or options.script.len > 0 or options.exports.len > 0): raise newException(ValueError, "Static archives do not accept runtime paths or linker scripts")
