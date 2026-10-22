import std/[algorithm, json, os, sequtils, strutils, tables]
import ../pkg/hash

type
  Entry = ref object of RootObj
    value: RootRef
    files: Table[string, string]
  Box[T] = ref object of Entry
    payload: T
  Queries* = ref object
    values: Table[string, Entry]
    stack: seq[Table[string, string]]
    observed: seq[string]
    reads: Table[string, tuple[value: string, present: bool, digest: string]]
    batching: bool
    hits*: int
    misses*: int
    loads*: int

proc queries*(): Queries =
  Queries(values: initTable[string, Entry](),
    reads: initTable[string, tuple[value: string, present: bool, digest: string]]())

export hash.digest

proc input*(queries: Queries; path: string): string =
  let absolute = absolutePath(path)
  if absolute notin queries.observed: queries.observed.add(absolute)
  var read: tuple[value: string, present: bool, digest: string]
  if queries.batching and queries.reads.hasKey(absolute):
    read = queries.reads[absolute]
  else:
    inc queries.loads
    read.present = fileExists(absolute) and getFileInfo(absolute).kind == pcFile
    read.value = if read.present: readFile(absolute) else: ""
    read.digest = if read.present: digest(read.value) else: "absent"
    if queries.batching: queries.reads[absolute] = read
  if queries.stack.len > 0: queries.stack[^1][absolute] = read.digest
  if read.present: read.value else: ""

proc batch*[T](queries: Queries; compute: proc(): T {.closure.}): T =
  if queries.batching: return compute()
  queries.batching = true
  queries.reads.clear()
  try: result = compute()
  finally: queries.batching = false; queries.reads.clear()

proc present*(queries: Queries; path: string): bool =
  let absolute = absolutePath(path)
  queries.batch(proc(): bool =
    discard queries.input(absolute)
    queries.reads[absolute].present)

proc valid*(queries: Queries; files: openArray[tuple[path: string, digest: string]]): bool =
  var copied: seq[tuple[path: string, digest: string]]
  for file in files: copied.add(file)
  queries.batch(proc(): bool =
    for file in copied:
      discard queries.input(file.path)
      let absolute = absolutePath(file.path)
      if not queries.reads.hasKey(absolute) or queries.reads[absolute].digest != file.digest: return false
    true)

proc get*[T](queries: Queries; key: string; compute: proc(): T {.closure.}): T =
  if queries.values.hasKey(key):
    let old = queries.values[key]
    var files: seq[tuple[path: string, digest: string]]
    for path, digest in old.files.pairs: files.add((path: path, digest: digest))
    if queries.valid(files):
      inc queries.hits
      if queries.stack.len > 0:
        for path, digest in old.files.pairs:
          queries.stack[^1][path] = digest
      return Box[T](old).payload
  inc queries.misses
  var dependencies = initTable[string, string]()
  queries.stack.add(dependencies)
  try:
    let value = compute()
    queries.values[key] = Box[T](payload: value, value: nil,
      files: queries.stack[^1])
    result = value
  finally:
    dependencies = queries.stack.pop()
    if queries.stack.len > 0:
      for path, digest in dependencies.pairs:
        queries.stack[^1][path] = digest

proc dependencies*(queries: Queries; key: string): seq[tuple[path: string, digest: string]] =
  if not queries.values.hasKey(key): return
  for path, digest in queries.values[key].files.pairs: result.add((path: path, digest: digest))

proc forget*(queries: Queries; key: string) = queries.values.del(key)
proc sources*(queries: Queries): seq[string] = queries.observed

proc inputs*(root: string; accept: proc(path: string): bool {.closure.} = nil): seq[tuple[path: string, digest: string]] =
  var files: seq[string]
  for path in walkDirRec(root):
    let lower = path.toLowerAscii
    if fileExists(path) and [".nim", ".js", ".mjs", ".zig", ".h", ".c", ".iv", ".json"].anyIt(lower.endsWith(it)):
      if accept == nil or accept(path): files.add(path)
  files.sort()
  for path in files: result.add((path: path, digest: digest(readFile(path))))

proc fingerprint*(root: string): string =
  var joined = ""
  for file in inputs(root): joined.add(file.path & "\0" & file.digest & "\0")
  digest(joined)
