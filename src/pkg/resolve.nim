import std/[json, os, sequtils, strutils, tables]
import ../diag/[code, engine, span]
import ./[fetch, lock]

type
  Manifest* = object
    name*: string
    version*: string
    dependencies*: Table[string, string]
  ResolvedDep* = object
    name*: string
    source*: string
    hash*: string
    path*: string
    requiredBy*: string
  ResolveError* = object of CatchableError

proc resolveError(message: string): ref ResolveError =
  new(result)
  result.msg = message

proc resolveDeps*(root: string; manifest: Manifest; lock: ref Lockfile; diag: Engine): seq[ResolvedDep] =
  var queue: seq[tuple[name, source, requiredBy: string]]
  for name, source in manifest.dependencies: queue.add((name: name, source: source, requiredBy: "root"))
  var resolved = initTable[string, ResolvedDep]()
  var position = 0
  while position < queue.len:
    let item = queue[position]; position.inc
    if item.name in resolved:
      let existing = resolved[item.name]
      if existing.source != item.source:
        diag.emit(PkgConflict, Span(), "Conflict: '" & item.name & "' required as '" & item.source & "' by '" & item.requiredBy & "', but already resolved as '" & existing.source & "' by '" & existing.requiredBy & "'")
        raise resolveError("Dependency conflict")
      continue
    let fetched = fetchDep(item.name, item.source, root)
    if lock != nil:
      for locked in lock.packages:
        if locked.name == item.name and locked.source == item.source and locked.hash != fetched.hash:
          diag.emit(PkgHashMismatch, Span(), "Hash mismatch for '" & item.name & "': expected " & locked.hash & ", found " & fetched.hash & ".")
          raise resolveError("Hash mismatch")
    let dependency = ResolvedDep(name: item.name, source: item.source, hash: fetched.hash, path: fetched.path, requiredBy: item.requiredBy)
    resolved[item.name] = dependency
    result.add(dependency)
    let depManifest = fetched.path / "project.json"
    if fileExists(depManifest):
      let node = parseJson(readFile(depManifest))
      if node.hasKey("dependencies") and node["dependencies"].kind == JObject:
        for name, source in node["dependencies"]: queue.add((name: name, source: source.getStr(), requiredBy: item.name))
