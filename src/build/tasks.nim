import std/[algorithm, json, os, sequtils, strutils, tables]
import ./files

type Task* = object
  needs*: seq[string]
  kind*: string
  inputs*: seq[string]
  output*: string
  text*: string
  values*: Table[string, JsonNode]

proc jsonText(value: JsonNode): string =
  case value.kind
  of JString: value.getStr()
  of JBool, JInt, JFloat: $value
  else: $value

proc substitute(text: string; values: Table[string, JsonNode]; name: string): string =
  var index = 0
  while index < text.len:
    if index + 1 < text.len and text[index] == '{' and text[index + 1] == '{':
      let close = text.find("}}", index + 2)
      if close < 0: result.add(text[index]); index.inc; continue
      let key = text[(index + 2) ..< close]
      if key.len == 0 or key[0] < 'A' or (key[0] > 'Z' and key[0] < 'a') or key[0] > 'z' or
          key.anyIt(not (it.isAlphaNumeric)):
        result.add(text[index .. close + 1]); index = close + 2; continue
      if key notin values: raise newException(ValueError, "Task '" & name & "' has no value '" & key & "'")
      result.add(jsonText(values[key])); index = close + 2
    else:
      result.add(text[index]); index.inc

proc appendU32(output: var string; value: int) =
  for shift in [0, 8, 16, 24]: output.add(char((value shr shift) and 0xff))

proc tasks*(root: string; definitions: Table[string, Task]; selected: seq[string] = @[]): seq[string] =
  let generated = root / ".artifacts" / "build" / "generated"
  discard confined(root, ".artifacts/build/generated")
  var done, active, outputs: Table[string, bool]
  var produced: Table[string, string]
  var files: seq[string] = @[]
  var selectedNames = selected
  if selectedNames.len == 0:
    for name in definitions.keys: selectedNames.add(name)
  proc run(name: string) =
    if done.getOrDefault(name): return
    if active.getOrDefault(name): raise newException(ValueError, "Build task cycle at '" & name & "'")
    if name notin definitions: raise newException(ValueError, "Unknown build task '" & name & "'")
    if name.len == 0 or name[0] < 'a' or name[0] > 'z' or name.anyIt(not (it.isAlphaNumeric or it == '-')):
      raise newException(ValueError, "Invalid build task name '" & name & "'")
    active[name] = true
    let task = definitions[name]
    for dependency in task.needs: run(dependency)
    let destination = confined(generated, task.output)
    let identity = destination.toLowerAscii()
    if outputs.getOrDefault(identity): raise newException(ValueError, "Build tasks share an output: " & task.output)
    outputs[identity] = true
    var inputs: seq[string] = @[]
    for pattern in task.inputs:
      if pattern.startsWith("@"):
        let dependency = pattern[1 .. ^1]
        if dependency notin task.needs or dependency notin produced:
          raise newException(ValueError, "Task '" & name & "' needs '" & dependency & "' before reading its output")
        inputs.add(relativePath(produced[dependency], root).replace(DirSep, '/'))
      else:
        let matches = glob(root, pattern)
        if matches.len == 0: raise newException(ValueError, "Task '" & name & "' input matched no files: " & pattern)
        inputs.add(matches)
    inputs = inputs.deduplicate()
    inputs.sort()
    var content = ""
    case task.kind
    of "copy":
      if inputs.len != 1: raise newException(ValueError, "Copy task '" & name & "' needs exactly one input")
      content = readFile(confined(root, inputs[0]))
    of "text": content = substitute(task.text, task.values, name)
    of "embed":
      content = "FOO\0\1"
      for path in inputs:
        let bytes = readFile(confined(root, path))
        appendU32(content, path.len); appendU32(content, bytes.len); content.add(path); content.add(bytes)
    else: raise newException(ValueError, "Unsupported task kind '" & task.kind & "'")
    write(destination, content)
    files.add(destination)
    produced[name] = destination; done[name] = true; active[name] = false
  for name in selectedNames: run(name)
  result = files
