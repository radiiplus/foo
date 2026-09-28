import std/[json, os, sets, tables]

proc load*(path: string): Table[string, uint64] =
  result = initTable[string, uint64]()
  if path.len == 0: return
  if not fileExists(path):
    raise newException(ValueError, "Optimization profile not found: " & path)
  let document = try:
      parseFile(path)
    except JsonParsingError as error:
      raise newException(ValueError,
        "Invalid optimization profile '" & path & "': " & error.msg)
  if document.kind != JObject or not document.hasKey("version") or
      document["version"].kind != JInt or document["version"].getInt() != 1 or
      not document.hasKey("kind") or document["kind"].kind != JString or
      document["kind"].getStr() != "function" or
      not document.hasKey("entries") or document["entries"].kind != JArray:
    raise newException(ValueError,
      "Optimization profile must be a version 1 function profile: " & path)
  for entry in document["entries"]:
    if entry.kind != JObject or entry.getOrDefault("function").kind != JString or
        entry.getOrDefault("hits").kind != JInt:
      raise newException(ValueError, "Invalid function entry in optimization profile: " & path)
    let name = entry["function"].getStr()
    let hits = entry["hits"].getBiggestInt()
    if name.len == 0 or hits < 0:
      raise newException(ValueError, "Invalid function entry in optimization profile: " & path)
    let previous = result.getOrDefault(name)
    let count = uint64(hits)
    if count > high(uint64) - previous:
      raise newException(ValueError,
        "Function counter overflow in optimization profile: " & path)
    result[name] = previous + count

proc hot*(counts: Table[string, uint64]): HashSet[string] =
  result = initHashSet[string]()
  var peak: uint64
  for hits in counts.values: peak = max(peak, hits)
  if peak == 0: return
  let threshold = max(1'u64, (peak + 4) div 5)
  for name, hits in counts:
    if hits >= threshold: result.incl(name)
