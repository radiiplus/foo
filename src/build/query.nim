import std/[algorithm, json, os, sequtils, strutils, tables]
import ../pkg/hash

type
  QueryEntry = ref object of RootObj
    value: RootRef
    files: Table[string, string]
  QueryBox[T] = ref object of QueryEntry
    typedValue: T
  Queries* = ref object
    values: Table[string, QueryEntry]
    stack: seq[Table[string, string]]
    observed: seq[string]
    reads: Table[string, tuple[value: string, present: bool, digest: string]]
    active: Table[string, string]
    batching: bool
    hits*: int
    misses*: int
    loads*: int

proc newQueries*(): Queries =
  Queries(values: initTable[string, QueryEntry](), reads: initTable[string, tuple[value: string, present: bool, digest: string]](), active: initTable[string, string]())

proc hashHex*(value: string): string = sha256Hex(value)

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
    read.digest = if read.present: sha256Hex(read.value) else: "absent"
    if queries.batching: queries.reads[absolute] = read
  if queries.stack.len > 0: queries.active[absolute] = read.digest
  if read.present: read.value else: ""

proc present*(queries: Queries; path: string): bool =
  let absolute = absolutePath(path)
  discard queries.input(absolute)
  queries.batching and queries.reads.hasKey(absolute) and queries.reads[absolute].present

proc batch*[T](queries: Queries; compute: proc(): T {.closure.}): T =
  if queries.batching: return compute()
  queries.batching = true
  queries.reads.clear()
  try: result = compute()
  finally: queries.batching = false; queries.reads.clear()

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
      return QueryBox[T](old).typedValue
  inc queries.misses
  var dependencies = initTable[string, string]()
  queries.active.clear()
  queries.stack.add(dependencies)
  try:
    let value = compute()
    dependencies = queries.active
    queries.values[key] = QueryBox[T](typedValue: value, value: nil, files: dependencies)
    result = value
  finally: discard queries.stack.pop()

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
  for path in files: result.add((path: path, digest: sha256Hex(readFile(path))))

proc fingerprint*(root: string): string =
  var joined = ""
  for file in inputs(root): joined.add(file.path & "\0" & file.digest & "\0")
  hashHex(joined)
