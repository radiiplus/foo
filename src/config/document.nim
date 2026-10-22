import std/[algorithm, json, os, strutils, tables]
import ./[capability, image, source]
import ../pkg/hash

proc check*(path: string; generate = true): Document =
  if not path.endsWith(".ivc"):
    raise newException(ValueError, "Configuration source must have an .ivc extension")
  result = source.load(path)
  let selected = result.values.getOrDefault("capabilities")
  if selected == nil or selected.kind != JArray or selected.len == 0:
    raise newException(ValueError, path & ": select at least one capability")
  let root = parentDir(absolutePath(path))
  let definitions = capability.resolve(root, result)
  for key, _ in result.values:
    if key in ["format", "capabilities"]: continue
    var claimed = false
    for definition in definitions:
      if definition.namespace == key:
        claimed = true
        break
    if not claimed:
      let location = result.origins.getOrDefault(key)
      raise newException(ValueError, location.file & ":" & $location.line &
        ":" & $location.column & ": no selected capability defines '" & key & "'")
  if generate: discard capability.resolve(root, result, true)

proc emit*(path: string): string =
  let document = check(path)
  let root = parentDir(absolutePath(path))
  let definitions = capability.resolve(root, document, true)
  var identities: seq[string]
  for definition in definitions:
    identities.add(definition.namespace & ":" & $definition.version & ":" &
      checksum(definition.path))
  identities.sort()
  let schema = digest("foo.config.schema/v1\n" & identities.join("\n"))
  let bytes = image.compile(document.values, schema)
  result = root / ".artifacts" / "config" /
    (splitFile(path).name & ".cimg")
  createDir(parentDir(result))
  if not fileExists(result) or readFile(result) != bytes:
    writeFile(result, bytes)
