import std/[json, os, sequtils, strutils, tables]
import ./hash

proc removeTree(path: string) =
  if not dirExists(path): return
  for entry in walkDir(path):
    if entry.kind == pcDir: removeTree(entry.path)
    else: removeFile(entry.path)
  removeDir(path)

proc getCacheDir*(root = getCurrentDir()): string =
  result = root / ".artifacts" / "cache" / "packages"
  createDir(result)

proc clearCache*() =
  let directory = getCacheDir()
  if dirExists(directory): removeTree(directory)

type Cache* = ref object
  artifact*: string
  key*: string
  receipt: string

proc newCache*(artifact, key: string): Cache =
  Cache(artifact: artifact, key: key, receipt: artifact & ".cache.json")

proc valid*(cache: Cache): bool =
  try:
    if not fileExists(cache.receipt): return false
    let data = parseJson(readFile(cache.receipt))
    if data["key"].getStr != cache.key or data["outputs"].kind != JArray or data["outputs"].len == 0: return false
    for output in data["outputs"]:
      if output.kind != JArray or output.len != 2 or not fileExists(output[0].getStr): return false
      if hashFile(output[0].getStr) != output[1].getStr: return false
    true
  except CatchableError:
    false

proc save*(cache: Cache; outputs: seq[string] = @[]) =
  let selected = if outputs.len > 0: outputs else: @[cache.artifact]
  var entries = newJArray()
  for path in selected:
    var entry = newJArray()
    entry.add(%path); entry.add(%hashFile(path)); entries.add(entry)
  let parent = parentDir(cache.receipt)
  if parent.len > 0: createDir(parent)
  writeFile(cache.receipt, $(%* {"key": cache.key, "outputs": entries}))

proc executable*(command: string): string =
  var extensions = @[""]
  when defined(windows):
    extensions = @[""]
    for extension in getEnv("PATHEXT", ".EXE;.CMD;.BAT").split(';'):
      extensions.add(extension)
  var bases: seq[string]
  if isAbsolute(command) or command.contains({'/', '\\'}): bases = @[absolutePath(command)]
  else:
    for directory in getEnv("PATH").split(PathSep):
      if directory.len > 0: bases.add(directory / command)
  for base in bases:
    for extension in extensions:
      let candidate = base & extension
      if fileExists(candidate): return absolutePath(candidate)
  raise newException(ValueError, "Compiler not found: " & command)

proc digest*(path: string): string = hashFile(path)

var toolDigests = initTable[string, string]()

proc tool*(path, directory: string): string =
  let info = getFileInfo(path)
  let key = path & "|" & $info.size & "|" & $info.lastWriteTime
  if toolDigests.hasKey(key): result = toolDigests[key]
  else:
    let receipt = directory / "tool.json"
    if fileExists(receipt):
      try:
        let data = parseJson(readFile(receipt))
        let digestValue = data["digest"].getStr
        if data["key"].getStr == key and digestValue.len == 64 and digestValue.allIt(it in HexDigits): result = digestValue
      except CatchableError: discard
    if result.len == 0: result = hashFile(path)
    toolDigests[key] = result
  createDir(directory)
  writeFile(directory / "tool.json", $(%* {"key": key, "digest": result}))
