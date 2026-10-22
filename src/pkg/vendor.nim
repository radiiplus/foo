import std/[json, os, tables]
import ../build/files
import ../config/project as configuration
import ../diag/engine
import ./[lock, resolve]

proc copy(source, destination: string) =
  createDir(destination)
  for kind, child in walkDir(source):
    let name = child.lastPathPart
    if name in [".git", "node_modules", ".artifacts"]: continue
    let target = destination / name
    if kind == pcDir: copy(child, target)
    elif kind == pcFile: write(target, readFile(child))

proc manifest(path: string): Manifest =
  let node = configuration.readManifestFile(path)
  result.name = node.getOrDefault("name").getStr()
  result.version = node.getOrDefault("version").getStr()
  result.dependencies = initTable[string, string]()
  if node.hasKey("dependencies") and node["dependencies"].kind == JObject:
    for name, source in node["dependencies"]: result.dependencies[name] = source.getStr()

proc vendor*(root = getCurrentDir(); diag = engine()) =
  let file = configuration.manifestPath(root)
  if not fileExists(file): raise newException(IOError, "No project manifest found in current directory")
  let manifest = manifest(file)
  let location = root / "project.ivl"
  let dependencies = resolve(root, manifest, read(location), diag)
  let dir = confined(root, ".artifacts/packages")
  if dirExists(dir): files.erase(dir)
  createDir(dir)
  var new = Lockfile(version: 1)
  for dependency in dependencies:
    let destination = confined(dir, dependency.name)
    copy(dependency.path, destination)
    new.packages.add(Locked(name: dependency.name, source: dependency.source, hash: dependency.hash))
  write(location, new)
