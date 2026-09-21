import std/[json, tables]

type
  NativeSelection* = object
    substrate*: string
    clobbers*: seq[string]
  ProductConfig* = object
    entry*: string
    kind*: string
    needs*: seq[string]
    soname*: string
    version*: string
    script*: string
    exports*: string
    rpath*: seq[string]
  CConfig* = object
    sources*: seq[JsonNode]
    `include`*: seq[string]
    flags*: seq[string]
  LinkConfig* = object
    libs*: seq[string]
    frameworks*: seq[string]
    cpp*: bool
    soname*: string
    version*: string
    exports*: string
    script*: string
    rpath*: seq[string]
  BuildConfig* = object
    native*: NativeSelection
    substrate*: string
    backend*: string
    compiler*: string
    products*: Table[string, ProductConfig]
    tasks*: JsonNode
    resources*: seq[string]
    `type`*: string
    target*: seq[string]
    optimize*: string
    semantic*: bool
    runtime*: string
    coverage*: string
    cpu*: string
    sanitize*: string
    docs*: bool
    c*: CConfig
    link*: LinkConfig
  PublishConfig* = object
    files*: seq[string]
  RegistryConfig* = object
    url*: string
    mirrors*: seq[string]
    keys*: Table[string, Table[string, string]]
  Manifest* = object
    name*: string
    version*: string
    language*: string
    schema*: int
    requires*: string
    source*: string
    entry*: string
    build*: BuildConfig
    dependencies*: Table[string, string]
    registry*: RegistryConfig
    publish*: PublishConfig

proc defaultManifest*(): Manifest =
  result.name = "app"
  result.version = "0.1.0"
  result.language = "1"

proc hasBuild*(manifest: Manifest): bool =
  manifest.build.backend.len > 0 or manifest.build.compiler.len > 0 or
    manifest.build.products.len > 0 or manifest.build.resources.len > 0 or
    manifest.build.tasks != nil
