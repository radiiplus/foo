import std/[algorithm, json, strutils]
import ../pkg/hash

const
  magic = "FCOI"
  version = 1
  capacity = 16 * 1024 * 1024
  nesting = 32

proc append(output: var string; value: uint64; bytes: int) =
  for bit in countup(0, (bytes - 1) * 8, 8):
    output.add(char((value shr bit) and 255))

proc unhex(value: string): string =
  if value.len != 64: raise newException(ValueError, "expected a SHA-256 digest")
  for index in countup(0, 62, 2):
    try: result.add(char(parseHexInt(value[index .. index + 1])))
    except ValueError: raise newException(ValueError, "invalid SHA-256 digest")

proc names(value: JsonNode): seq[string] =
  for key, _ in value: result.add(key)
  result.sort()

proc encode(value: JsonNode; output: var string; depth: int) =
  if depth > nesting: raise newException(ValueError, "image nesting exceeds 32 levels")
  case value.kind
  of JNull: output.add(char(0))
  of JBool: output.add(char(if value.getBool(): 2 else: 1))
  of JInt:
    output.add(char(3))
    output.append(cast[uint64](value.getInt().int64), 8)
  of JFloat:
    output.add(char(4))
    output.append(cast[uint64](value.getFloat()), 8)
  of JString:
    let text = value.getStr()
    if text.len > capacity: raise newException(ValueError, "image string too large")
    output.add(char(5))
    output.append(text.len.uint64, 4)
    output.add(text)
  of JArray:
    if value.len > 65535: raise newException(ValueError, "image list too large")
    output.add(char(6))
    output.append(value.len.uint64, 4)
    for item in value: encode(item, output, depth + 1)
  of JObject:
    if value.len > 65535: raise newException(ValueError, "image record too large")
    output.add(char(7))
    output.append(value.len.uint64, 4)
    for key in names(value):
      if key.len > 65535: raise newException(ValueError, "image field name too long")
      output.append(key.len.uint64, 2)
      output.add(key)
      encode(value[key], output, depth + 1)

proc identify(name: string): uint64 =
  let bytes = unhex(digest("foo.config.field/v1\0" & name))
  for index in 0 ..< 8:
    result = result or (uint64(ord(bytes[index])) shl (index * 8))

proc compile*(values: JsonNode; schemaHash: string): string =
  if values.kind != JObject:
    raise newException(ValueError, "image root must be an object")
  if values.len > 65535: raise newException(ValueError, "too many image fields")
  let fields = names(values)
  var payload = ""
  var table = ""
  for name in fields:
    if name.len == 0 or name.len > 65535:
      raise newException(ValueError, "invalid image field name")
    let offset = payload.len
    encode(values[name], payload, 0)
    if payload.len > capacity:
      raise newException(ValueError, "configuration image exceeds 16 MiB")
    table.append(name.len.uint64, 2)
    table.add(name)
    table.append(identify(name), 8)
    table.append(uint64(ord(payload[offset])), 1)
    table.append(offset.uint64, 4)
    table.append((payload.len - offset).uint64, 4)
  result = magic & char(version) & unhex(schemaHash) &
    unhex(digest(payload))
  result.append(fields.len.uint64, 4)
  result.add(table)
  result.add(payload)
  if result.len > capacity:
    raise newException(ValueError, "configuration image exceeds 16 MiB")
