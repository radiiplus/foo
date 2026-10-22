import std/[tables, strutils]
import ../../ir/[node, kind]

type Layout* = object
  size*, alignment*: int
  offsets*: seq[int]

proc rounded(size, alignment: int): int =
  size + (alignment - size mod alignment) mod alignment

proc storageWidth*(t: node.Type): int =
  let width = if t.width > 0: t.width else: 32
  if width notin 1..128:
    raise newException(ValueError, "QBE integer width outside 1..128")
  if width <= 8: 8
  elif width <= 16: 16
  elif width <= 32: 32
  elif width <= 64: 64
  else: 128

proc packedBits*(t: node.Type): int =
  case t.kind
  of Shape.PackedStruct:
    for field in t.fields.values: result += packedBits(field)
  of Shape.Bool: result = 1
  of Shape.Int, Shape.Uint:
    result = if t.width > 0: t.width else: 32
    if result notin 1..128:
      raise newException(ValueError, "QBE packed integer width outside 1..128")
  else: raise newException(ValueError, "Non-bit field in QBE packed layout")

proc measure*(t: node.Type): Layout =
  if t == nil: raise newException(ValueError, "QBE layout requires a type")
  case t.kind
  of Shape.Void: result = Layout(size: 0, alignment: 1)
  of Shape.Bool: result = Layout(size: 1, alignment: 1)
  of Shape.Int, Shape.Uint:
    let width = storageWidth(t)
    result = Layout(size: width div 8, alignment: width div 8)
  of Shape.Float:
    if t.width notin [32, 64]:
      raise newException(ValueError, "QBE floating layout requires 32 or 64 bits")
    result = Layout(size: t.width div 8, alignment: t.width div 8)
  of Shape.Ptr, Shape.Function, Shape.Error:
    result = Layout(size: 8, alignment: 8)
  of Shape.Slice:
    result = Layout(size: 16, alignment: 8, offsets: @[0, 8])
  of Shape.Optional, Shape.Failable:
    let member = if t.elem == nil or t.elem.kind == Shape.Void:
        Layout(size: 1, alignment: 1)
      else: measure(t.elem)
    let tag = if t.kind == Shape.Optional: 1 else: 8
    result.alignment = max(tag, member.alignment)
    result.offsets = @[0, rounded(tag, member.alignment)]
    result.size = result.offsets[1] + member.size
  of Shape.Struct, Shape.ExternStruct:
    result.alignment = 1
    for field in t.fields.values:
      let member = measure(field)
      result.size = rounded(result.size, member.alignment)
      result.offsets.add(result.size)
      result.size += member.size
      result.alignment = max(result.alignment, member.alignment)
    result.size = max(1, result.size)
  of Shape.TaggedUnion, Shape.ExternUnion:
    var payload = Layout(size: 1, alignment: 1)
    let fields = if t.kind == Shape.TaggedUnion: t.variants else: t.fields
    for field in fields.values:
      let member = if field == nil: Layout(size: 1, alignment: 1)
        else: measure(field)
      payload.size = max(payload.size, member.size)
      payload.alignment = max(payload.alignment, member.alignment)
    result.alignment = max(if t.kind == Shape.TaggedUnion: 4 else: 1,
      payload.alignment)
    if t.kind == Shape.ExternUnion:
      for field in t.fields.values: result.offsets.add(0)
      result.size = rounded(payload.size, payload.alignment)
    else:
      result.offsets = @[0, rounded(4, payload.alignment)]
      result.size = result.offsets[1] + rounded(payload.size, payload.alignment)
  of Shape.PackedStruct:
    result = Layout(size: max(1, (packedBits(t) + 7) div 8), alignment: 1)
    var bit = 0
    for field in t.fields.values:
      result.offsets.add(bit)
      bit += packedBits(field)
  of Shape.Array, Shape.Vector:
    if t.elem == nil or t.width < 0:
      raise newException(ValueError, "Invalid QBE sequence layout")
    let member = measure(t.elem)
    if member.size > 0 and t.width > high(int) div member.size:
      raise newException(ValueError, "QBE sequence layout overflows")
    result = Layout(size: member.size * t.width, alignment: member.alignment)
  else:
    raise newException(ValueError, "Unsupported QBE layout: " & t.label)
  for attribute in t.attributes:
    if attribute.startsWith("align(") and attribute.endsWith(")"):
      let alignment = try: parseInt(attribute[6 .. ^2])
        except ValueError: raise newException(ValueError, "Invalid QBE alignment")
      if alignment < 1 or (alignment and (alignment - 1)) != 0:
        raise newException(ValueError, "QBE alignment must be a power of two")
      result.alignment = max(result.alignment, alignment)
  result.size = rounded(result.size, result.alignment)

proc position*(t: node.Type; name: string): int =
  for field in t.fields.keys:
    if field == name: return result
    inc result
  raise newException(ValueError, "Unknown field " & name)
