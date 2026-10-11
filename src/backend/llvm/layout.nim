## Storage layout for the qualified little-endian Windows x64 target.
## Semantic integer widths are independent of their addressable storage width.
import std/[strutils, tables]
import ../../ir/[node, kind]

type Layout* = object
  size*, alignment*: int
  offsets*: seq[int]

proc width*(t: node.Type): int =
  if t.width > 0: t.width else: 32

proc storageWidth*(t: node.Type): int =
  let n = width(t)
  if n <= 8: 8 elif n <= 16: 16 elif n <= 32: 32 elif n <= 64: 64 else: 128

proc rounded*(size, alignment: int): int =
  size + (alignment - size mod alignment) mod alignment

proc aggregate*(t: node.Type): bool =
  t != nil and t.kind in {TypeKind.Struct, TypeKind.ExternStruct,
    TypeKind.ExternUnion, TypeKind.PackedStruct, TypeKind.TaggedUnion,
    TypeKind.Optional, TypeKind.Failable, TypeKind.Slice, TypeKind.Array,
    TypeKind.Vector}

proc measure*(t: node.Type): Layout =
  if t == nil: return Layout(size: 0, alignment: 1)
  case t.kind
  of TypeKind.Void: result = Layout(size: 0, alignment: 1)
  of TypeKind.Bool: result = Layout(size: 1, alignment: 1)
  of TypeKind.Int, TypeKind.Uint:
    if width(t) notin 1..128: raise newException(ValueError, "integer width outside 1..128")
    let bytes = storageWidth(t) div 8
    result = Layout(size: bytes, alignment: bytes)
  of TypeKind.Float:
    if t.width notin [32, 64]: raise newException(ValueError, "unsupported decimal width")
    result = Layout(size: t.width div 8, alignment: t.width div 8)
  of TypeKind.Ptr, TypeKind.Function, TypeKind.Error:
    result = Layout(size: 8, alignment: 8)
  of TypeKind.Slice: result = Layout(size: 16, alignment: 8, offsets: @[0, 8])
  of TypeKind.Optional, TypeKind.Failable:
    let element = if t.elem == nil or t.elem.kind == TypeKind.Void:
        Layout(size: 1, alignment: 1) else: measure(t.elem)
    let tag = if t.kind == TypeKind.Optional: 1 else: 8
    result.alignment = max(tag, element.alignment)
    result.offsets = @[0, rounded(tag, element.alignment)]
    result.size = rounded(result.offsets[1] + element.size, result.alignment)
  of TypeKind.Struct, TypeKind.ExternStruct:
    result.alignment = 1
    for field in t.fields.values:
      let item = measure(field)
      result.size = rounded(result.size, item.alignment)
      result.offsets.add(result.size)
      result.size += item.size
      result.alignment = max(result.alignment, item.alignment)
    result.size = max(1, result.size)
  of TypeKind.ExternUnion, TypeKind.TaggedUnion:
    var payload = Layout(size: 1, alignment: 1)
    if t.kind == TypeKind.ExternUnion:
      for field in t.fields.values:
        let item = measure(field)
        payload.size = max(payload.size, item.size)
        payload.alignment = max(payload.alignment, item.alignment)
    else:
      for field in t.variants.values:
        let item = measure(field)
        payload.size = max(payload.size, item.size)
        payload.alignment = max(payload.alignment, item.alignment)
    result.alignment = max(if t.kind == TypeKind.TaggedUnion: 4 else: 1, payload.alignment)
    result.offsets = @[0, if t.kind == TypeKind.TaggedUnion: rounded(4, payload.alignment) else: 0]
    result.size = result.offsets[1] + rounded(payload.size, payload.alignment)
  of TypeKind.Array, TypeKind.Vector:
    let element = measure(t.elem)
    if t.width < 1: raise newException(ValueError, "array/vector requires a positive width")
    result = Layout(size: element.size * t.width, alignment: element.alignment)
  of TypeKind.PackedStruct:
    raise newException(ValueError, "packed records need a separately qualified bit-layout runtime adapter")
  else: raise newException(ValueError, "no addressable LLVM layout for " & t.label)
  for attribute in t.attributes:
    if attribute.startsWith("align(") and attribute.endsWith(")"):
      result.alignment = max(result.alignment, parseInt(attribute[6..^2]))
  result.size = rounded(result.size, result.alignment)

proc llvmType*(t: node.Type): string =
  if t == nil or t.kind == TypeKind.Void: return "void"
  if aggregate(t): return "[" & $measure(t).size & " x i8]"
  case t.kind
  of TypeKind.Int, TypeKind.Uint: "i" & $storageWidth(t)
  of TypeKind.Bool: "i8"
  of TypeKind.Float: (if t.width == 32: "float" else: "double")
  of TypeKind.Ptr, TypeKind.Function, TypeKind.Error: "ptr"
  else: raise newException(ValueError, "unsupported LLVM type " & t.label)

proc fieldIndex*(t: node.Type; name: string): int =
  for field in t.fields.keys:
    if field == name: return result
    inc result
  raise newException(ValueError, "unknown field " & name & " in " & t.label)
