import std/[algorithm, json, os, strutils, sequtils, times]
import ../pkg/hash
import ./files

type
  Step* = object
    name*: string
    reused*: bool
    elapsed*: float
  Planner* = ref object
    directory*: string
    revision*: string
    steps*: seq[Step]

proc canonical(node: JsonNode): string =
  case node.kind
  of JNull: "null"
  of JBool:
    if node.getBool(): "true" else: "false"
  of JInt, JFloat: $node
  of JString: escapeJson(node.getStr())
  of JArray:
    "[" & node.elems.mapIt(canonical(it)).join(",") & "]"
  of JObject:
    var keys = node.keys.toSeq
    keys.sort()
    "{" & keys.mapIt(escapeJson(it) & ":" & canonical(node[it])).join(",") & "}"

proc signature*(input: JsonNode): string =
  sha256Hex(canonical(input))

proc newPlanner*(directory, revision: string): Planner =
  Planner(directory: directory, revision: revision, steps: @[])

proc validName(name: string): bool =
  if name.len == 0: return false
  for character in name:
    if character < 'a' or character > 'z': return false
  true

proc run*(planner: Planner; name: string; input: JsonNode; compute: proc(): JsonNode {.closure.}): JsonNode =
  if not validName(name): raise newException(ValueError, "Invalid compilation stage")
  let started = cpuTime()
  let key = signature(%*[planner.revision, input])
  let file = planner.directory / (name & ".plan")
  if fileExists(file):
    try:
      let stored = parseJson(readFile(file))
      let payload = stored["payload"]
      if stored["key"].getStr() == key and stored["digest"].getStr() == sha256Hex($payload):
        planner.steps.add(Step(name: name, reused: true, elapsed: cpuTime() - started))
        return payload
    except CatchableError:
      discard
  let value = compute()
  let serialized = $value
  let record = %*{"key": key, "payload": value, "digest": sha256Hex(serialized)}
  write(file, $record)
  planner.steps.add(Step(name: name, reused: false, elapsed: cpuTime() - started))
  value
