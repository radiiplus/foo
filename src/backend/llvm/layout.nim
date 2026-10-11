## Addressable storage for the qualified little-endian Windows x64 target.
import std/[strutils, tables]
import ../../ir/[node, kind]
type Layout* = object
  size*, alignment*: int
  offsets*: seq[int]
proc width*(t: node.Type): int = (if t.width > 0: t.width else: 32)
proc storageWidth*(t: node.Type): int =
  let n = width(t)
  if n <= 8: 8 elif n <= 16: 16 elif n <= 32: 32 elif n <= 64: 64 else: 128
proc rounded*(size, alignment: int): int = size + (alignment - size mod alignment) mod alignment
proc packedBits*(t: node.Type): int =
  if t.kind == TypeKind.PackedStruct:
    for field in t.fields.values: result += packedBits(field)
  elif t.kind == TypeKind.Bool: result = 1
  elif t.kind in {TypeKind.Int,TypeKind.Uint}: result = width(t)
  else: raise newException(ValueError,"non-bit field in packed layout")
proc aggregate*(t: node.Type): bool = t != nil and t.kind in {
  TypeKind.Struct, TypeKind.ExternStruct, TypeKind.ExternUnion, TypeKind.PackedStruct,
  TypeKind.TaggedUnion, TypeKind.Optional, TypeKind.Failable, TypeKind.Slice, TypeKind.Array, TypeKind.Vector}
proc measure*(t: node.Type): Layout =
  if t == nil: return Layout(size: 0, alignment: 1)
  case t.kind
  of TypeKind.Void: result = Layout(size: 0, alignment: 1)
  of TypeKind.Bool: result = Layout(size: 1, alignment: 1)
  of TypeKind.Int, TypeKind.Uint:
    if width(t) notin 1..128: raise newException(ValueError, "integer width outside 1..128")
    result = Layout(size: storageWidth(t) div 8, alignment: storageWidth(t) div 8)
  of TypeKind.Float:
    let bits = if t.width == 0: 64 else: t.width
    if bits notin [32,64]: raise newException(ValueError, "unsupported decimal width")
    result = Layout(size: bits div 8, alignment: bits div 8)
  of TypeKind.Ptr, TypeKind.Function, TypeKind.Error: result = Layout(size: 8, alignment: 8)
  of TypeKind.Slice: result = Layout(size: 16, alignment: 8, offsets: @[0,8])
  of TypeKind.Optional, TypeKind.Failable:
    let member = if t.elem == nil or t.elem.kind == TypeKind.Void: Layout(size: 1, alignment: 1) else: measure(t.elem)
    let tag = if t.kind == TypeKind.Optional: 1 else: 8
    result.alignment = max(tag, member.alignment)
    result.offsets = @[0, rounded(tag, member.alignment)]
    result.size = result.offsets[1] + member.size
  of TypeKind.Struct, TypeKind.ExternStruct:
    result.alignment = 1
    for field in t.fields.values:
      let member = measure(field)
      result.size = rounded(result.size, member.alignment); result.offsets.add(result.size)
      result.size += member.size; result.alignment = max(result.alignment, member.alignment)
    result.size = max(1,result.size)
  of TypeKind.TaggedUnion, TypeKind.ExternUnion:
    var payload = Layout(size: 1, alignment: 1)
    let fields = if t.kind == TypeKind.TaggedUnion: t.variants else: t.fields
    for member in fields.values:
      let measured = measure(member)
      payload.size = max(payload.size, measured.size); payload.alignment = max(payload.alignment, measured.alignment)
    result.alignment = max(if t.kind == TypeKind.TaggedUnion: 4 else: 1, payload.alignment)
    if t.kind == TypeKind.ExternUnion:
      for field in t.fields.values: result.offsets.add(0)
      result.size = rounded(payload.size, payload.alignment)
    else:
      result.offsets = @[0, rounded(4, payload.alignment)]
      result.size = result.offsets[1] + rounded(payload.size, payload.alignment)
  of TypeKind.Array, TypeKind.Vector:
    let member = measure(t.elem)
    result = Layout(size: member.size * t.width, alignment: member.alignment)
  of TypeKind.PackedStruct:
    result = Layout(size:max(1,(packedBits(t)+7) div 8),alignment:1)
    var bit = 0
    for field in t.fields.values: result.offsets.add(bit); bit += packedBits(field)
  else: raise newException(ValueError, "unqualified LLVM layout: " & t.label)
  for attribute in t.attributes:
    if attribute.startsWith("align(") and attribute.endsWith(")"): result.alignment = max(result.alignment, parseInt(attribute[6..^2]))
  result.size = rounded(result.size,result.alignment)
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
  raise newException(ValueError, "unknown field " & name)
