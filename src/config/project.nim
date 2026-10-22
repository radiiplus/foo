import std/[json, os, strutils]
import ./[capability, document, source]
import ../pkg/hash

const sourceName* = "project.ivc"

proc manifestPath*(root: string): string = root / sourceName

proc manifestExists*(root: string): bool = fileExists(manifestPath(root))

proc readManifestFile*(path: string): JsonNode =
  let parsed = document.check(path, false)
  let selected = parsed.values["capabilities"]
  var projectSelected = false
  for name in selected:
    if name.getStr() == "project": projectSelected = true
  if not projectSelected:
    raise newException(ValueError, path & ": select capability \"project\"")
  result = parsed.values["project"]

proc readProject*(root: string): JsonNode =
  let path = manifestPath(root)
  if fileExists(path): readManifestFile(path) else: newJObject()

proc authored(values: JsonNode): JsonNode =
  result = values.copy()
  for pair in [("schema", %1), ("language", %"1"),
      ("requires", %"base"), ("dependencies", newJObject())]:
    if result.hasKey(pair[0]) and result[pair[0]] == pair[1]:
      result.delete(pair[0])

proc writeProject*(root: string; values: JsonNode) =
  let path = manifestPath(root)
  let explicit = authored(values)
  if fileExists(path):
    let original = source.load(path)
    if original.files.len > 1:
      let existing = original.values.getOrDefault("project")
      var additions = ""
      for key, value in explicit:
        if existing == nil or not existing.hasKey(key):
          additions.add("  " & key & " is " & source.renderValue(value) & "\n")
        elif existing[key] != value:
          additions.add("  " & key & " is " &
            source.renderValue(value) & "\n")
      if additions.len > 0:
        let content = readFile(path)
        writeFile(path, content & (if content.endsWith("\n"): "" else: "\n") &
          "project {\n" & additions & "}\n")
      return
    let merged = newJObject()
    for key, value in original.values:
      if key notin ["format", "project"]: merged[key] = value
    merged["project"] = explicit
    writeFile(path, source.render(merged, "project"))
  else:
    writeFile(path, source.render(%*{"project": explicit}, "project"))

proc manifestFiles*(root: string): seq[string] =
  let path = manifestPath(root)
  if not fileExists(path): return @[]
  let parsed = document.check(path)
  result = parsed.files
  for definition in capability.resolve(root, parsed, true):
    result.add(definition.path)

proc fingerprint*(root: string): string =
  var content = ""
  for path in manifestFiles(root):
    content.add(absolutePath(path).replace('\\', '/') & "\0" &
      checksum(path) & "\n")
  digest(content)

proc emitImage*(root: string): string =
  let path = manifestPath(root)
  if not fileExists(path):
    raise newException(ValueError, "config emit needs project.ivc")
  discard readManifestFile(path)
  document.emit(path)
