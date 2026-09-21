import std/[json, os, sequtils]

type
  LockedPackage* = object
    name*: string
    source*: string
    hash*: string
  Lockfile* = object
    version*: int
    packages*: seq[LockedPackage]

proc readLock*(path: string): ref Lockfile =
  if not fileExists(path): return nil
  try:
    let node = parseJson(readFile(path))
    new(result)
    result.version = node["version"].getInt()
    for item in node["packages"].items:
      result.packages.add(LockedPackage(name: item["name"].getStr(), source: item["source"].getStr(), hash: item["hash"].getStr()))
  except CatchableError:
    return nil

proc writeLock*(path: string; lock: Lockfile) =
  let packages = lock.packages.mapIt(%*{"name": it.name, "source": it.source, "hash": it.hash})
  let node = %*{"version": lock.version, "packages": packages}
  let parent = parentDir(path)
  if parent.len > 0: createDir(parent)
  writeFile(path, pretty(node) & "\n")
