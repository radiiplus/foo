import std/[json, tables]

type
  Bindings* = object
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
  Sources* = object
    sources*: seq[JsonNode]
    `include`*: seq[string]
    sysroot*: string
    flags*: seq[string]
  Link* = object
    libs*: seq[string]
    frameworks*: seq[string]
    cpp*: bool
    soname*: string
    version*: string
    exports*: string
    script*: string
    rpath*: seq[string]
  Build* = object
    native*: Bindings
    substrate*: string
    backend*: string
    compiler*: string
    products*: Table[string, Product]
    tasks*: JsonNode
    hooks*: JsonNode
    resources*: seq[string]
    `type`*: string
    target*: seq[string]
    optimize*: string
    semantic*: bool
    runtime*: string
    coverage*: string
    profile*: string
    cpu*: string
    sanitize*: string
    docs*: bool
    debug*: bool
    output*: string
    icon*: string
    c*: Sources
    link*: Link
  Publication* = object
    files*: seq[string]
  Registry* = object
    url*: string
    mirrors*: seq[string]
    keys*: Table[string, Table[string, string]]
  Signing* = object
    provider*: string
    timestamp*: string
  Deployment* = object
    directory*: string
    icon*: string
    license*: string
    readme*: string
    files*: seq[string]
    signing*: Signing
  Manifest* = object
    name*: string
    version*: string
    license*: string
    language*: string
    schema*: int
    requires*: string
    source*: string
    entry*: string
    entries*: Table[string, string]
    build*: Build
    dependencies*: Table[string, string]
    registry*: Registry
    publish*: Publication
    deployment*: Deployment

proc manifest*(): Manifest =
  result.name = "app"
  result.version = "0.1.0"
  result.language = "1"
  result.entries = initTable[string, string]()

proc configured*(manifest: Manifest): bool =
  manifest.build.backend.len > 0 or manifest.build.compiler.len > 0 or
    manifest.build.output.len > 0 or manifest.build.icon.len > 0 or
    manifest.build.products.len > 0 or manifest.build.resources.len > 0 or
    manifest.build.tasks != nil or manifest.build.hooks != nil
