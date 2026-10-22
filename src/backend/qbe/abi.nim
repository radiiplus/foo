import std/[strutils, tables]
import ../../ir/[kind, node]
import ./layout as targetLayout

const foreignAbis* = ["system", "stdcall", "fastcall", "vectorcall", "thiscall"]

proc bridgeName*(name: string): string = "foo_qbe_bridge_" & name
proc internalName*(name: string): string = "foo_qbe_internal_" & name

proc convention(abi, target: string): string =
  if abi == "system": return ""
  if target != "windows-x64":
    raise newException(ValueError, "QBE " & abi & " ABI needs windows-x64")
  case abi
  of "stdcall": "__stdcall "
  of "fastcall": "__fastcall "
  of "vectorcall": "__vectorcall "
  of "thiscall": "__thiscall "
  else: raise newException(ValueError, "Unsupported QBE foreign ABI " & abi)

proc scalarCtype(t: node.Type): string =
  if t == nil or t.kind == Shape.Void: return "void"
  case t.kind
  of Shape.Int, Shape.Uint:
    if t.width notin [8, 16, 32, 64]:
      raise newException(ValueError, "QBE ABI bridge integer width")
    (if t.kind == Shape.Int: "int" else: "uint") & $t.width & "_t"
  of Shape.Bool: "_Bool"
  of Shape.Float:
    case t.width
    of 32: "float"
    of 64: "double"
    else: raise newException(ValueError, "QBE ABI bridge decimal width")
  of Shape.Ptr, Shape.Function: "void *"
  of Shape.Error: "const char *"
  else: raise newException(ValueError,
    "QBE ABI bridge requires scalar arguments and result: " & t.label)

proc callbacks*(module: Module): OrderedTable[pointer, tuple[name: string,
    signature: node.Type]] =
  result = initOrderedTable[pointer, tuple[name: string,
    signature: node.Type]]()
  for fn in module.funcs:
    for section in fn.blocks:
      for instruction in section.instrs:
        if instruction.kind notin {Opcode.Call, Opcode.Thread}: continue
        let t = instruction.callee.type
        if t != nil and t.kind == Shape.Function and t.abi in foreignAbis:
          let identity = cast[pointer](t)
          if identity notin result:
            result[identity] = ("foo_qbe_callback_" & $result.len, t)

proc bridgeSource*(module: Module; target: string): string =
  var definitions: seq[string]
  var names = initTable[pointer, string]()
  proc ctype(t: node.Type): string =
    if t == nil or t.kind == Shape.Void: return "void"
    if (t.kind in {Shape.Int, Shape.Uint} and t.width > 64) or
        t.kind in {Shape.Struct, Shape.ExternStruct, Shape.ExternUnion,
          Shape.Array, Shape.Vector}:
      let identity = cast[pointer](t)
      if identity in names: return names[identity]
      let layout = targetLayout.measure(t)
      if layout.size == 0 or layout.alignment > 16:
        raise newException(ValueError, "QBE ABI bridge aggregate layout")
      let name = "foo_qbe_abi_type_" & $names.len
      names[identity] = name
      var fields: seq[string]
      case t.kind
      of Shape.Int, Shape.Uint:
        if t.width notin 65..128:
          raise newException(ValueError, "QBE ABI bridge integer width")
        fields = @["uint64_t low;", "uint64_t high;"]
      of Shape.Array, Shape.Vector:
        if t.elem == nil or t.width < 1:
          raise newException(ValueError, "QBE ABI bridge array layout")
        fields = @[ctype(t.elem) & " values[" & $t.width & "];"]
      of Shape.Struct, Shape.ExternStruct, Shape.ExternUnion:
        var index = 0
        for field in t.fields.values:
          fields.add(ctype(field) & " field" & $index & ";")
          inc index
        if fields.len == 0:
          raise newException(ValueError, "QBE ABI bridge empty aggregate")
      else: discard
      let aggregate = if t.kind == Shape.ExternUnion: "union" else: "struct"
      definitions.add("typedef " & aggregate & " { " & fields.join(" ") &
        " } " & name & " __attribute__((aligned(" & $layout.alignment &
        ")));\n" & "typedef char foo_qbe_abi_size_" & name &
        "[(sizeof(" & name & ") == " & $layout.size & ") ? 1 : -1];\n")
      if t.kind in {Shape.Struct, Shape.ExternStruct}:
        for index, offset in layout.offsets:
          definitions.add("typedef char foo_qbe_abi_offset_" & name &
            "_" & $index & "[(offsetof(" & name & ", field" & $index &
            ") == " & $offset & ") ? 1 : -1];\n")
      return name
    scalarCtype(t)
  proc foreignCtype(t: node.Type; abi: string): string =
    if abi == "vectorcall" and t != nil and
        ((t.kind in {Shape.Int, Shape.Uint} and t.width > 64) or
        t.kind in {Shape.Struct, Shape.ExternStruct, Shape.ExternUnion,
          Shape.Array, Shape.Vector}):
      raise newException(ValueError,
        "QBE vectorcall aggregate or wide result/argument is unsupported by TinyCC")
    ctype(t)
  var body = ""
  for ext in module.externs:
    if ext.abi notin foreignAbis: continue
    let cc = convention(ext.abi, target)
    let returned = foreignCtype(ext.ret, ext.abi)
    var types, parameters, arguments: seq[string]
    for index, parameter in ext.params:
      let spelling = foreignCtype(parameter, ext.abi)
      types.add(spelling)
      parameters.add(spelling & " a" & $index)
      arguments.add("a" & $index)
    let signature = if types.len == 0: "void" else: types.join(", ")
    body.add("extern " & returned & " " & cc & ext.symbol &
      "(" & signature & ");\n")
    body.add(returned & " " & bridgeName(ext.name) & "(" &
      (if parameters.len == 0: "void" else: parameters.join(", ") ) &
      ") { " & (if returned == "void": "" else: "return ") &
      ext.symbol & "(" & arguments.join(", ") & "); }\n")
  for item in callbacks(module).values:
    let t = item.signature
    let cc = convention(t.abi, target)
    let returned = foreignCtype(t.ret, t.abi)
    var types, parameters, arguments: seq[string]
    for index, parameter in t.params:
      let spelling = foreignCtype(parameter, t.abi)
      types.add(spelling)
      parameters.add(spelling & " a" & $index)
      arguments.add("a" & $index)
    body.add("typedef " & returned & " (" & cc & "*foo_qbe_callback_type_" &
      item.name & ")(" & (if types.len == 0: "void" else: types.join(", ")) &
      ");\n")
    body.add(returned & " " & item.name & "(void *callee" &
      (if parameters.len == 0: "" else: ", " & parameters.join(", ")) &
      ") { " & (if returned == "void": "" else: "return ") &
      "((foo_qbe_callback_type_" & item.name & ")callee)(" &
      arguments.join(", ") & "); }\n")
  for fn in module.funcs:
    if fn.abi notin foreignAbis: continue
    let cc = convention(fn.abi, target)
    let returned = foreignCtype(fn.ret, fn.abi)
    var types, parameters, arguments: seq[string]
    for index, parameter in fn.params:
      let spelling = foreignCtype(parameter.type, fn.abi)
      types.add(spelling)
      parameters.add(spelling & " a" & $index)
      arguments.add("a" & $index)
    body.add("extern " & returned & " " & internalName(fn.name) & "(" &
      (if types.len == 0: "void" else: types.join(", ")) & ");\n")
    body.add(returned & " " & cc & fn.name & "(" &
      (if parameters.len == 0: "void" else: parameters.join(", ")) &
      ") { " & (if returned == "void": "" else: "return ") &
      internalName(fn.name) & "(" & arguments.join(", ") & "); }\n")
  result = "#include <stdint.h>\n#include <stdbool.h>\n#include <stddef.h>\n" &
    definitions.join("") & body
