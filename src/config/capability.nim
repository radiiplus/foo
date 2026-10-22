import std/[json, os, sets, strutils, tables]
import ./source
import ../build/files

const projectSchema = staticRead("project.cap")

type
  Field* = object
    name*: string
    kind*: string
    required*: bool
    default*: JsonNode
    minimum*: JsonNode
    maximum*: JsonNode
    choices*: JsonNode
    minLength*: int
    aliases*: seq[string]
  Capability* = object
    namespace*: string
    version*: int
    requires*: seq[string]
    fields*: seq[Field]
    path*: string

proc valid(value: string): bool =
  if value.len == 0 or value[0] notin {'a'..'z', 'A'..'Z'}: return false
  for character in value:
    if character notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}: return false
  true

proc lookup(node: JsonNode; key: string): JsonNode =
  if node.hasKey(key): node[key] else: nil

proc require(node: JsonNode; kind: JsonNodeKind; label: string) =
  if node == nil or node.kind != kind:
    raise newException(ValueError, label & " must be " & $kind)

proc matches(value: JsonNode; kind: string): bool =
  if value == nil: return false
  case kind
  of "string": value.kind == JString
  of "integer", "size", "duration": value.kind == JInt
  of "float": value.kind in {JInt, JFloat}
  of "boolean": value.kind == JBool
  of "list": value.kind == JArray
  of "object": value.kind == JObject
  else: false

proc length(value: JsonNode): int =
  if value.kind == JString: value.getStr().len else: value.len

proc less(left, right: JsonNode; kind: string): bool =
  if kind == "float": left.getFloat() < right.getFloat()
  else: left.getInt() < right.getInt()

proc greater(left, right: JsonNode; kind: string): bool =
  if kind == "float": left.getFloat() > right.getFloat()
  else: left.getInt() > right.getInt()

proc parse(name: string; node: JsonNode): Field =
  require(node, JObject, "field '" & name & "'")
  let kind = lookup(node, "type")
  require(kind, JString, "field '" & name & "'.type")
  result = Field(name: name, kind: kind.getStr(),
    default: lookup(node, "default"), minimum: lookup(node, "min"),
    maximum: lookup(node, "max"), choices: lookup(node, "allowed"),
    minLength: -1)
  if result.kind notin ["string", "integer", "size", "duration", "float",
      "boolean", "list", "object"]:
    raise newException(ValueError, "unsupported type for '" & name & "': " & result.kind)
  for key, value in node:
    case key
    of "type", "default", "min", "max", "allowed": discard
    of "required":
      require(value, JBool, "field '" & name & "'.required")
      result.required = value.getBool()
    of "minLength":
      require(value, JInt, "field '" & name & "'.minLength")
      if result.kind notin ["string", "list"] or value.getInt() < 0:
        raise newException(ValueError, "field '" & name & "'.minLength needs a nonnegative string or list length")
      result.minLength = value.getInt()
    of "aliases":
      require(value, JArray, "field '" & name & "'.aliases")
      for alias in value:
        require(alias, JString, "field '" & name & "'.aliases item")
        if not valid(alias.getStr()):
          raise newException(ValueError, "invalid alias '" & alias.getStr() & "'")
        result.aliases.add(alias.getStr())
    else: raise newException(ValueError, "unknown field rule '" & key & "'")
  if result.default != nil and not matches(result.default, result.kind):
    raise newException(ValueError, "default for '" & name & "' has wrong type")
  if result.default != nil and result.minLength >= 0 and
      length(result.default) < result.minLength:
    raise newException(ValueError, "default for '" & name & "' is too short")
  if result.minimum != nil or result.maximum != nil:
    if result.kind notin ["integer", "size", "duration", "float"]:
      raise newException(ValueError, "range for '" & name & "' needs a numeric type")
    for bound in [result.minimum, result.maximum]:
      if bound != nil and not matches(bound, result.kind):
        raise newException(ValueError, "range for '" & name & "' has wrong type")
    if result.minimum != nil and result.maximum != nil and
        greater(result.minimum, result.maximum, result.kind):
      raise newException(ValueError, "range for '" & name & "' is inverted")
  if result.choices != nil:
    require(result.choices, JArray, "field '" & name & "'.allowed")
    if result.choices.len == 0:
      raise newException(ValueError, "allowed values for '" & name & "' are empty")
    for choice in result.choices:
      if not matches(choice, result.kind):
        raise newException(ValueError, "allowed value for '" & name & "' has wrong type")
  if result.default != nil:
    if result.minimum != nil and less(result.default, result.minimum, result.kind) or
        result.maximum != nil and greater(result.default, result.maximum, result.kind):
      raise newException(ValueError, "default for '" & name & "' is outside its range")
    if result.choices != nil:
      var permitted = false
      for choice in result.choices:
        if choice == result.default: permitted = true
      if not permitted:
        raise newException(ValueError, "default for '" & name & "' is not allowed")

proc decode(document: Document; path: string): Capability =
  if document.files.len != 1:
    raise newException(ValueError, ".cap files cannot import configuration files")
  let root = document.values
  let namespace = lookup(root, "namespace")
  let version = lookup(root, "version")
  let fields = lookup(root, "fields")
  require(namespace, JString, "capability namespace")
  require(version, JInt, "capability version")
  require(fields, JObject, "capability fields")
  if not valid(namespace.getStr()) or version.getInt() != 1:
    raise newException(ValueError, "capability needs a valid namespace and version 1")
  result = Capability(namespace: namespace.getStr(), version: 1, path: path)
  let dependencies = lookup(root, "requires")
  if dependencies != nil:
    require(dependencies, JArray, "capability requires")
    for item in dependencies:
      require(item, JString, "capability requires item")
      if not valid(item.getStr()) or item.getStr() == result.namespace:
        raise newException(ValueError, "invalid capability dependency")
      result.requires.add(item.getStr())
  for key, value in root:
    if key notin ["format", "namespace", "version", "fields", "requires"]:
      raise newException(ValueError, "unknown capability property '" & key & "'")
  var names = initHashSet[string]()
  for name, definition in fields:
    if not valid(name): raise newException(ValueError, "invalid field '" & name & "'")
    let field = parse(name, definition)
    for spelling in @[name] & field.aliases:
      if spelling in names:
        raise newException(ValueError, "conflicting field or alias '" & spelling & "'")
      names.incl(spelling)
    result.fields.add(field)

proc read*(path: string): Capability =
  if not path.endsWith(".cap"):
    raise newException(ValueError, "Capability definition must have a .cap extension")
  decode(source.load(path), path)

proc readText*(content, path: string): Capability =
  decode(source.loadText(content, path), path)

proc generatedPath*(root, name: string): string =
  confined(root, ".artifacts/.cap/" & name & ".cap")

proc materialize*(root, name, content: string): string =
  result = generatedPath(root, name)
  createDir(parentDir(result))
  if not fileExists(result) or readFile(result) != content:
    writeFile(result, content)

proc discover*(root, name: string; generate = false): Capability =
  if not valid(name):
    raise newException(ValueError, "invalid external capability '" & name & "'")
  var content: string
  var input: string
  if name == "project":
    content = "# Generated built-in project capability\n" & projectSchema
    input = generatedPath(root, name)
    result = readText(content, input)
  else:
    input = confined(root, ".cap/" & name & ".cap")
    if not fileExists(input):
      raise newException(ValueError, "capability '" & name &
        "' has no definition in .cap/")
    result = read(input)
    content = "# Generated from .cap/" & input.lastPathPart & "\n" &
      readFile(input)
  if result.namespace != name:
    raise newException(ValueError, "capability '" & name & "' declares namespace '" &
      result.namespace & "'")
  if generate:
    result.path = materialize(root, name, content)
    discard read(result.path)

proc validate*(capability: Capability; config: JsonNode) =
  require(config, JObject, "configuration namespace '" & capability.namespace & "'")
  var accepted = initHashSet[string]()
  for field in capability.fields:
    accepted.incl(field.name)
    for alias in field.aliases: accepted.incl(alias)
    var selected = ""
    for spelling in @[field.name] & field.aliases:
      if config.hasKey(spelling):
        if selected.len > 0:
          raise newException(ValueError, "both '" & selected & "' and '" & spelling &
            "' set " & capability.namespace & "." & field.name)
        selected = spelling
    if selected.len == 0:
      if field.default != nil: config[field.name] = field.default
      elif field.required:
        raise newException(ValueError, "missing '" & capability.namespace & "." & field.name & "'")
      continue
    let value = config[selected]
    if not matches(value, field.kind):
      raise newException(ValueError, "wrong type for '" & capability.namespace & "." & field.name & "'")
    if field.minLength >= 0 and length(value) < field.minLength:
      raise newException(ValueError, "'" & capability.namespace & "." & field.name &
        "' is too short")
    if field.minimum != nil and less(value, field.minimum, field.kind) or
        field.maximum != nil and greater(value, field.maximum, field.kind):
      raise newException(ValueError, "'" & capability.namespace & "." & field.name &
        "' is outside its permitted range")
    if field.choices != nil:
      var permitted = false
      for choice in field.choices:
        if choice == value: permitted = true
      if not permitted:
        raise newException(ValueError, "'" & capability.namespace & "." & field.name &
          "' is not an allowed value")
    if selected != field.name:
      config[field.name] = value
      config.delete(selected)
  for key, _ in config:
    if key notin accepted:
      raise newException(ValueError, "unknown field '" & capability.namespace & "." & key & "'")

proc resolve*(root: string; document: Document; generate = false): seq[Capability] =
  let selected = document.values.getOrDefault("capabilities")
  if selected == nil: return @[]
  require(selected, JArray, "capabilities")
  var names = initHashSet[string]()
  for item in selected:
    require(item, JString, "capability name")
    let name = item.getStr()
    if name in names: raise newException(ValueError, "duplicate capability '" & name & "'")
    names.incl(name)
    result.add(discover(root, name, generate))
  for capability in result:
    for required in capability.requires:
      if required notin names:
        raise newException(ValueError, "capability '" & capability.namespace &
          "' requires explicit capability '" & required & "'")
  var states = initTable[string, int]()
  let definitions = result
  proc visit(name: string) =
    if states.getOrDefault(name) == 1:
      raise newException(ValueError, "capability dependency cycle at '" & name & "'")
    if states.getOrDefault(name) == 2: return
    states[name] = 1
    for cap in definitions:
      if cap.namespace == name:
        for required in cap.requires: visit(required)
    states[name] = 2
  for cap in result: visit(cap.namespace)
  for capability in result:
    let namespace = document.values.getOrDefault(capability.namespace)
    if namespace == nil:
      raise newException(ValueError, "missing namespace '" & capability.namespace & "'")
    capability.validate(namespace)
