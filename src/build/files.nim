import std/[os, sequtils, strutils, algorithm, sets]

proc inside(root, path: string): string =
  let base = absolutePath(root)
  let target = absolutePath(path, base)
  let rel = relativePath(target, base)
  if rel.len == 0 or rel == ".." or rel.startsWith(".." & DirSep) or isAbsolute(rel):
    raise newException(ValueError, "Path must be inside " & base & ": " & path)
  target

proc confined*(root, path: string): string =
  ## Resolve a task path while rejecting symlinks and hard-linked files.
  let base = absolutePath(root)
  let target = inside(base, path)
  var current = base
  let rel = relativePath(target, base)
  if dirExists(base):
    let info = getFileInfo(base, followSymlink = false)
    if info.kind in {pcLinkToDir, pcLinkToFile}:
      raise newException(ValueError, "Symlink roots are not allowed: " & base)
  for part in rel.split(DirSep):
    current = current / part
    if fileExists(current) or dirExists(current):
      let info = getFileInfo(current, followSymlink = false)
      if info.kind in {pcLinkToDir, pcLinkToFile}:
        raise newException(ValueError, "Symlinks are not allowed in build tasks: " & path)
      if info.kind == pcFile and info.linkCount > 1:
        raise newException(ValueError, "Hard links are not allowed in build tasks: " & path)
  target

proc globMatch(pattern, value: string; pi = 0; vi = 0): bool =
  if pi == pattern.len:
    return vi == value.len
  if pattern[pi] == '*':
    if pi + 1 < pattern.len and pattern[pi + 1] == '*':
      var next = pi + 2
      if next < pattern.len and pattern[next] == '/':
        if globMatch(pattern, value, next + 1, vi): return true
        next.inc
      for index in vi .. value.len:
        if globMatch(pattern, value, next, index): return true
      return false
    var index = vi
    while true:
      if globMatch(pattern, value, pi + 1, index): return true
      if index == value.len or value[index] == '/': break
      index.inc
    return false
  if vi == value.len or (pattern[pi] != '?' and pattern[pi] != value[vi]): return false
  if pattern[pi] == '?' and value[vi] == '/': return false
  globMatch(pattern, value, pi + 1, vi + 1)

proc glob*(root, pattern: string): seq[string] =
  if isAbsolute(pattern) or pattern.contains('\\') or pattern.split('/').anyIt(it == ".."): 
    raise newException(ValueError, "Resource glob must be relative: " & pattern)
  let base = absolutePath(root)
  if not dirExists(base): return @[]
  proc visit(dir: string; found: var seq[string]) =
    for kind, path in walkDir(dir):
      let name = splitFile(path).name
      if name in [".git", "node_modules", ".artifacts"]: continue
      if kind in {pcLinkToDir, pcLinkToFile}: continue
      if kind == pcDir:
        visit(path, found)
      else:
        let rel = relativePath(path, base).replace(DirSep, '/')
        if globMatch(pattern, rel): found.add(rel)
  visit(base, result)
  result.sort()

proc write*(path, data: string) =
  if fileExists(path) and readFile(path) == data: return
  let parent = parentDir(path)
  if parent.len > 0: createDir(parent)
  writeFile(path, data)

proc discover*(root: string; source = ""): seq[string] =
  let base = absolutePath(root)
  let selected = if source.len > 0: source else: (if dirExists(base / "src"): "src" else: ".")
  let directory = absolutePath(selected, base)
  discard inside(base, directory)
  if not dirExists(directory):
    raise newException(IOError, "Source root not found: " & directory)
  var seen = initHashSet[string]()
  for relative in glob(directory, "**/*.iv"):
    let lower = relative.toLowerAscii()
    if lower in seen:
      raise newException(ValueError, "Source paths differ only by case: " & relative)
    seen.incl(lower)
    result.add(directory / relative.replace('/', DirSep))
