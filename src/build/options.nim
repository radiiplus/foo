import std/strutils

type
  NativeBinding* = object
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
    native*: NativeBinding
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
    sanitize*: string
    runtime*: string
    docs*: bool
    threads*: bool
    debug*: bool
    run*: bool
    compile*: bool
    compiler*: string
    sources*: seq[string]
    includePaths*: seq[string]
    flags*: seq[string]
    libs*: seq[string]
    frameworks*: seq[string]
    objects*: seq[string]
    cpp*: bool

proc artifact*(options: Native): string =
  let productName = if options.name.len > 0: options.name else: "app"
  let kind = if options.kind.len > 0: options.kind else: "exe"
  for character in productName:
    if not (character.isAlphaNumeric or character in {'_', '-'}): raise newException(ValueError, "Invalid product name '" & productName & "'")
  let windows = if options.target.len > 0: options.target.contains("windows") else: defined(windows)
  let mac = if options.target.len > 0: options.target.contains("macos") or options.target.contains("darwin") else: defined(macosx)
  if kind == "static": return if windows: productName & ".lib" else: "lib" & productName & ".a"
  if kind == "shared": return if windows: productName & ".dll" elif mac: "lib" & productName & ".dylib" else: "lib" & productName & ".so" & (if options.version.len > 0: "." & options.version else: "")
  if options.target.startsWith("wasm"): productName & ".wasm" elif windows: productName & ".exe" else: productName

proc validate*(options: Native) =
  discard artifact(options)
  if options.kind.len > 0 and options.kind notin ["exe", "static", "shared"]: raise newException(ValueError, "Unknown product kind '" & options.kind & "'")
  if options.version.len > 0 and options.version.split('.').len != 3: raise newException(ValueError, "Library version must be major.minor.patch")
  if (options.soname.len > 0 or options.version.len > 0) and options.kind != "shared": raise newException(ValueError, "soname and version require a shared library")
  if options.kind == "static" and (options.rpath.len > 0 or options.script.len > 0 or options.exports.len > 0): raise newException(ValueError, "Static archives do not accept runtime paths or linker scripts")
