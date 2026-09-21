import std/[json, os, strutils, tables]
import ../build/files
import ../diag/engine
import ./[lock, resolve]

proc removeTree(path: string) =
  if not dirExists(path): return
  for kind, child in walkDir(path):
    if kind == pcDir: removeTree(child)
    else: removeFile(child)
  removeDir(path)

proc copyTree(source, destination: string) =
  createDir(destination)
  for kind, child in walkDir(source):
    let name = child.lastPathPart
    if name in [".git", "node_modules", ".artifacts"]: continue
    let target = destination / name
    if kind == pcDir: copyTree(child, target)
    elif kind == pcFile: write(target, readFile(child))

proc manifestAt(path: string): Manifest =
  let node = parseJson(readFile(path))
  result.name = node.getOrDefault("name").getStr()
  result.version = node.getOrDefault("version").getStr()
  result.dependencies = initTable[string, string]()
  if node.hasKey("dependencies") and node["dependencies"].kind == JObject:
    for name, source in node["dependencies"]: result.dependencies[name] = source.getStr()

proc vendor*(root = getCurrentDir(); diag = newEngine()) =
  let manifestPath = root / "project.json"
  if not fileExists(manifestPath): raise newException(IOError, "No project.json found in current directory")
  let manifest = manifestAt(manifestPath)
  let lockPath = root / "project.lock"
  let dependencies = resolveDeps(root, manifest, readLock(lockPath), diag)
  let vendorDir = confined(root, ".artifacts/packages")
  if dirExists(vendorDir): removeTree(vendorDir)
  createDir(vendorDir)
  var newLock = Lockfile(version: 1)
  for dependency in dependencies:
    let destination = confined(vendorDir, dependency.name)
    copyTree(dependency.path, destination)
    newLock.packages.add(LockedPackage(name: dependency.name, source: dependency.source, hash: dependency.hash))
  writeLock(lockPath, newLock)
