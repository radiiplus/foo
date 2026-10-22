## Typed IR to WAT. The driver uses WABT for modules and relocatable objects.
import std/[sequtils, strutils, tables]
import ../../ir/[kind, node]

type Footprint = object
  size, alignment: int
  offsets: seq[int]

proc unsupported(detail: string): ref ValueError =
  newException(ValueError, "WebAssembly lowering cannot handle " & detail)

proc scalar(t: node.Type): string =
  if t == nil: raise unsupported("an untyped value")
  case t.kind
  of Shape.Bool: "i32"
  of Shape.Ptr: "i32"
  of Shape.Array, Shape.Struct, Shape.ExternStruct: "i32"
  of Shape.Int, Shape.Uint:
    case t.width
    of 8, 16, 32: "i32"
    of 64: "i64"
    else: raise unsupported(t.label)
  of Shape.Float:
    case t.width
    of 32: "f32"
    of 64: "f64"
    else: raise unsupported(t.label)
  else: raise unsupported(t.label)

proc aggregate(t: node.Type): bool =
  t != nil and t.kind in {Shape.Array, Shape.Struct, Shape.ExternStruct}

proc equivalent(left, right: node.Type; depth = 0): bool =
  if left == right: return true
  if left == nil or right == nil or depth > 32 or
      left.kind != right.kind or left.width != right.width:
    return false
  case left.kind
  of Shape.Ptr, Shape.Array:
    equivalent(left.elem, right.elem, depth + 1)
  of Shape.Struct, Shape.ExternStruct:
    if left.fields.len != right.fields.len: return false
    let counterparts = toSeq(right.fields.pairs)
    var index = 0
    for name, field in left.fields:
      if name != counterparts[index][0] or
          not equivalent(field, counterparts[index][1], depth + 1):
        return false
      inc index
    true
  of Shape.Opaque: left.name == right.name
  else: true

proc rounded(size, alignment: int): int =
  (size + alignment - 1) div alignment * alignment

proc layout(t: node.Type): Footprint =
  if t == nil: raise unsupported("untyped memory")
  case t.kind
  of Shape.Bool: result = Footprint(size: 1, alignment: 1)
  of Shape.Int, Shape.Uint:
    case t.width
    of 8: result = Footprint(size: 1, alignment: 1)
    of 16: result = Footprint(size: 2, alignment: 2)
    of 32: result = Footprint(size: 4, alignment: 4)
    of 64: result = Footprint(size: 8, alignment: 8)
    else: raise unsupported("integer storage width")
  of Shape.Float:
    case t.width
    of 32: result = Footprint(size: 4, alignment: 4)
    of 64: result = Footprint(size: 8, alignment: 8)
    else: raise unsupported("float storage width")
  of Shape.Ptr: result = Footprint(size: 4, alignment: 4)
  of Shape.Array:
    if t.elem == nil or t.width < 0: raise unsupported("array layout")
    let member = layout(t.elem)
    if member.size > 0 and t.width > high(int) div member.size:
      raise unsupported("array layout overflow")
    result = Footprint(size: member.size * t.width,
      alignment: member.alignment)
  of Shape.Struct, Shape.ExternStruct:
    result.alignment = 1
    for field in t.fields.values:
      let member = layout(field)
      result.size = rounded(result.size, member.alignment)
      result.offsets.add(result.size)
      result.size += member.size
      result.alignment = max(result.alignment, member.alignment)
    result.size = max(1, rounded(result.size, result.alignment))
  else: raise unsupported("memory layout for " & t.label)
  if result.alignment > 8: raise unsupported("memory alignment over 8")

proc extent(t: node.Type): int = layout(t).size

proc access(t: node.Type; store: bool): string =
  let typ = scalar(t)
  let width = extent(t)
  if width == 1:
    typ & (if store: ".store8" elif t.kind == Shape.Int: ".load8_s" else: ".load8_u")
  elif width == 2:
    typ & (if store: ".store16" elif t.kind == Shape.Int: ".load16_s" else: ".load16_u")
  else: typ & (if store: ".store" else: ".load")

proc symbol(name: string): string

proc value(v: Value; locals: Table[string, string]): string =
  case v.kind
  of Flavor.Reg:
    if v.name notin locals: raise unsupported("undefined register '" & v.name & "'")
    "(local.get " & locals[v.name] & ")"
  of Flavor.Const:
    if v.type == nil: raise unsupported("untyped constant")
    let typ = scalar(v.type)
    if v.type.kind == Shape.Bool:
      if v.name notin ["true", "false"]: raise unsupported("boolean constant")
      "(i32.const " & (if v.name == "true": "1" else: "0") & ")"
    elif v.type.kind == Shape.Ptr and v.name == "null":
      "(i32.const 0)"
    else:
      "(" & typ & ".const " & v.name & ")"
  of Flavor.Global:
    "(global.get $" & symbol(v.name) & ")"

proc symbol(name: string): string =
  if name.len == 0 or not (name[0].isAlphaAscii or name[0] == '_'):
    raise unsupported("symbol '" & name & "'")
  for character in name:
    if not (character.isAlphaNumeric or character == '_'):
      raise unsupported("symbol '" & name & "'")
  name

proc octets(v: Value): string =
  if v.kind != Flavor.Const or v.type == nil:
    raise unsupported("static initializer")
  let size = extent(v.type)
  var raw: uint64
  case v.type.kind
  of Shape.Bool:
    if v.name notin ["true", "false"]: raise unsupported("boolean initializer")
    raw = if v.name == "true": 1'u64 else: 0'u64
  of Shape.Int: raw = cast[uint64](parseBiggestInt(v.name))
  of Shape.Uint: raw = parseBiggestUInt(v.name)
  of Shape.Ptr:
    if v.name != "null": raise unsupported("pointer initializer")
  of Shape.Float:
    if v.type.width == 32:
      raw = uint64(cast[uint32](float32(parseFloat(v.name))))
    else: raw = cast[uint64](parseFloat(v.name))
  else: raise unsupported("static initializer type")
  for index in 0..<size:
    result.add("\\" & toHex(int((raw shr (index * 8)) and 255'u64), 2))

proc emit*(module: Module; entry: bool; shared = false): string =
  if module == nil or module.native.len > 0:
    raise unsupported("native contracts")
  var functions = initTable[string, node.Function]()
  var externs = initTable[string, Extern]()
  for ext in module.externs:
    discard symbol(ext.name)
    discard symbol(ext.symbol)
    if ext.name in externs or ext.abi notin ["", "c", "wasi"]:
      raise unsupported("external ABI or duplicate external function")
    for parameter in ext.params:
      discard scalar(parameter)
    if ext.ret != nil and ext.ret.kind != Shape.Void:
      discard scalar(ext.ret)
    externs[ext.name] = ext
  for fn in module.funcs:
    discard symbol(fn.name)
    if fn.name in functions: raise unsupported("duplicate function '" & fn.name & "'")
    if fn.abi notin ["", "c"] or fn.generics.len > 0 or
        fn.attributes.len > 0 or fn.blocks.len == 0:
      raise unsupported("function ABI, attributes or body")
    if fn.ret != nil and fn.ret.kind == Shape.Ptr:
      raise unsupported("pointer result lifetime")
    functions[fn.name] = fn
  var completion: node.Type
  if entry:
    if "main" notin functions or functions["main"].params.len > 0:
      raise unsupported("application entry signature")
    completion = functions["main"].ret
    if completion != nil and completion.kind != Shape.Void:
      if completion.kind notin {Shape.Int, Shape.Uint} or
          completion.width notin [32, 64]:
        raise unsupported("application entry result")
  let threaded = shared and entry
  if threaded:
    if "thread_main" notin functions or
        functions["thread_main"].params.len != 2 or
        functions["thread_main"].ret == nil or
        functions["thread_main"].ret.kind != Shape.Void or
        functions["thread_main"].params.anyIt(it.type == nil or
          it.type.kind notin {Shape.Int, Shape.Uint} or it.type.width != 32):
      raise unsupported("wasi-threads executable needs thread_main(tid: i32, arg: i32): void")
  result = "(module\n"
  for ext in module.externs:
    if ext.name in functions: raise unsupported("duplicate function '" & ext.name & "'")
    let spawn = shared and ext.abi == "wasi" and
      ext.symbol == "wasi_thread_spawn"
    let provider = if spawn: "wasi"
      elif ext.abi == "wasi": "wasi_snapshot_preview1" else: "env"
    result.add("  (import \"" & provider & "\" \"" &
      (if spawn: "thread-spawn" else: ext.symbol) &
      "\" (func $" & ext.name)
    if aggregate(ext.ret): result.add(" (param i32)")
    for parameter in ext.params: result.add(" (param " & scalar(parameter) & ")")
    if ext.ret != nil and ext.ret.kind != Shape.Void and not aggregate(ext.ret):
      result.add(" (result " & scalar(ext.ret) & ")")
    result.add("))\n")
  if completion != nil and completion.kind != Shape.Void:
    result.add("  (import \"wasi_snapshot_preview1\" \"proc_exit\" " &
      "(func $wasi_proc_exit (param i32)))\n")
  result.add(if threaded:
      "  (import \"env\" \"memory\" (memory 256 1024 shared))\n"
    elif shared:
      "  (memory (export \"memory\") 1 1024 shared)\n"
    else: "  (memory (export \"memory\") 1)\n")
  var cursor = 1024
  var names = initTable[string, bool]()
  for item in module.storage:
    discard symbol(item.name)
    if item.name in names or item.name in functions or item.name in externs:
      raise unsupported("duplicate storage '" & item.name & "'")
    if item.thread: raise unsupported("thread-local storage")
    if shared and not threaded:
      raise unsupported("static storage in a shared-memory object")
    names[item.name] = true
    let size = layout(item.value.type)
    cursor = rounded(cursor, size.alignment)
    if cursor + size.size >= 65536:
      raise unsupported("static data exceeds initial memory")
    result.add("  (global $" & item.name &
      (if item.public: " (export \"" & item.name & "\")" else: "") &
      " i32 (i32.const " & $cursor & "))\n")
    let bytes = octets(item.value)
    if threaded:
      if bytes != "\\00".repeat(size.size):
        raise unsupported("nonzero threaded static initializer")
    else:
      result.add("  (data (i32.const " & $cursor & ") \"" &
        bytes & "\")\n")
    cursor += size.size
  let boundary = rounded(cursor, 16)
  result.add("  (global $stack (mut i32) (i32.const " &
    (if threaded: "0" else: "65536") & "))\n")
  for functionIndex in 0..<module.funcs.len:
    let fn = module.funcs[functionIndex]
    var locals = initTable[string, string]()
    var types = initTable[string, string]()
    var parameters: seq[string]
    var usage = 0
    var slots = initTable[string, int]()
    proc reserve(name: string; t: node.Type) =
      if name in slots: raise unsupported("duplicate stack slot")
      let size = layout(t)
      usage = rounded(usage, size.alignment)
      slots[name] = usage
      usage += size.size
    proc register(v: Value; parameter = false) =
      if v.type == nil or v.type.kind in {Shape.Void, Shape.Memory}: return
      let typ = scalar(v.type)
      if v.name.len == 0: raise unsupported("unnamed register")
      if v.name in locals:
        if types[v.name] != typ: raise unsupported("register type mismatch")
        return
      let label = "$v" & $locals.len
      locals[v.name] = label
      types[v.name] = typ
      if parameter: parameters.add(" (param " & label & " " & typ & ")")
    for parameter in fn.params:
      register(parameter, true)
      if aggregate(parameter.type): reserve(parameter.name, parameter.type)
    var blocks = initTable[string, int]()
    for index, section in fn.blocks:
      if section == nil or section.term == nil or section.label in blocks:
        raise unsupported("missing or duplicate block")
      blocks[section.label] = index
      for parameter in section.params: register(parameter)
      for instructionIndex, instruction in section.instrs:
        if instruction == nil: raise unsupported("missing instruction")
        register(instruction.dest)
        if instruction.kind == Opcode.Alloc:
          if instruction.op != "slot" or instruction.dest.type == nil or
              instruction.dest.type.kind != Shape.Ptr or
              instruction.dest.type.elem == nil:
            raise unsupported("non-stack allocation")
          reserve(instruction.dest.name, instruction.dest.type.elem)
        elif aggregate(instruction.dest.type):
          if instruction.dest.kind != Flavor.Reg:
            raise unsupported("aggregate destination")
          reserve(instruction.dest.name, instruction.dest.type)
        if instruction.kind == Opcode.Call and instruction.func in externs:
          let ext = externs[instruction.func]
          for argIndex, parameter in ext.params:
            if aggregate(parameter):
              reserve("call." & section.label & "." & $instructionIndex &
                "." & $argIndex, parameter)
    usage = rounded(usage, 16)
    if shared and not threaded and usage > 0:
      raise unsupported("threaded stack frames without per-thread storage")
    result.add("  (func $" & fn.name)
    if fn.public: result.add(" (export \"" & fn.name & "\")")
    if aggregate(fn.ret): result.add(" (param $result i32)")
    for parameter in parameters: result.add(parameter)
    if fn.ret != nil and fn.ret.kind != Shape.Void and not aggregate(fn.ret):
      result.add(" (result " & scalar(fn.ret) & ")")
    for name, label in locals:
      if fn.params.anyIt(it.name == name): continue
      result.add("\n    (local " & label & " " & types[name] & ")")
    if usage > 0:
      result.add("\n    (local $frame i32)")
    result.add("\n    (local $wide i64)")
    result.add("\n    (local $pc i32)\n")
    if threaded:
      result.add("    (if (i32.eqz (global.get $stack)) (then\n" &
        "      (drop (i32.atomic.rmw.cmpxchg (i32.const 0) " &
        "(i32.const 0) (i32.const 65536)))\n" &
        "      (global.set $stack (i32.add (i32.atomic.rmw.add " &
        "(i32.const 0) (i32.const 65536)) (i32.const 65536)))\n" &
        "      (if (i32.gt_u (global.get $stack) " &
        "(i32.mul (memory.size) (i32.const 65536))) " &
        "(then unreachable))\n    ))\n")
    if usage > 0:
      result.add("    (local.set $frame (i32.sub (global.get $stack) (i32.const " &
        $usage & ")))\n")
      result.add("    (if (i32.lt_u (local.get $frame) " &
        (if threaded:
          "(i32.sub (global.get $stack) (i32.const 65536))"
         else: "(i32.const " & $boundary & ")") & ") " &
        "(then unreachable))\n")
      result.add("    (global.set $stack (local.get $frame))\n")
      for parameter in fn.params:
        if not aggregate(parameter.type): continue
        let destination = "(i32.add (local.get $frame) (i32.const " &
          $slots[parameter.name] & "))"
        result.add("    (memory.copy " & destination & " " &
          value(parameter, locals) & " (i32.const " &
          $extent(parameter.type) & "))\n")
        result.add("    (local.set " & locals[parameter.name] & " " &
          destination & ")\n")
    result.add("    (loop $dispatch\n")
    for index, section in fn.blocks:
      result.add("      (if (i32.eq (local.get $pc) (i32.const " & $index & ")) (then\n")
      for instructionIndex, i in section.instrs:
        if i.attributes.len > 0: raise unsupported("instruction attributes")
        if aggregate(i.dest.type):
          result.add("        (local.set " & locals[i.dest.name] &
            " (i32.add (local.get $frame) (i32.const " &
            $slots[i.dest.name] & ")))\n")
        case i.kind
        of Opcode.Alloc:
          result.add("        (local.set " & locals[i.dest.name] &
            " (i32.add (local.get $frame) (i32.const " &
            $slots[i.dest.name] & ")))\n")
        of Opcode.Load:
          if i.ptr.type == nil or i.ptr.type.kind != Shape.Ptr or
              i.ptr.type.elem == nil or i.dest.type == nil or
              scalar(i.dest.type) != scalar(i.ptr.type.elem) or
              i.ptr.type.volatile or i.dest.type.volatile:
            raise unsupported("load type or volatile access")
          if aggregate(i.dest.type):
            result.add("        (memory.copy " & value(i.dest, locals) & " " &
              value(i.ptr, locals) & " (i32.const " &
              $extent(i.dest.type) & "))\n")
          else:
            result.add("        (local.set " & locals[i.dest.name] & " (" &
              access(i.dest.type, false) & " " & value(i.ptr, locals) & "))\n")
        of Opcode.Store:
          if i.ptr.type == nil or i.ptr.type.kind != Shape.Ptr or
              i.ptr.type.elem == nil or i.val.type == nil or
              scalar(i.val.type) != scalar(i.ptr.type.elem) or
              i.ptr.type.volatile or i.val.type.volatile:
            raise unsupported("store type or volatile access")
          if aggregate(i.val.type):
            result.add("        (memory.copy " & value(i.ptr, locals) & " " &
              value(i.val, locals) & " (i32.const " &
              $extent(i.val.type) & "))\n")
          else:
            result.add("        (" & access(i.val.type, true) & " " &
              value(i.ptr, locals) & " " & value(i.val, locals) & ")\n")
        of Opcode.Atomic:
          if not shared: raise unsupported("atomics require wasi-threads")
          if i.field notin ["relaxed", "acquire", "release", "acq_rel",
              "seq_cst"]:
            raise unsupported("atomic ordering")
          if i.op == "fence":
            if i.field == "relaxed": raise unsupported("relaxed fence")
            result.add("        (atomic.fence)\n")
          else:
            if i.ptr.type == nil or i.ptr.type.kind != Shape.Ptr or
                i.ptr.type.elem == nil or
                i.ptr.type.elem.kind notin {Shape.Int, Shape.Uint} or
                i.ptr.type.elem.width notin [32, 64] or
                "atomic" notin i.ptr.type.elem.attributes or
                i.op notin ["load", "store", "add", "sub", "swap"] or
                (i.op == "load" and i.field in ["release", "acq_rel"]) or
                (i.op == "store" and i.field in ["acquire", "acq_rel"]):
              raise unsupported("atomic operation type or ordering")
            let typ = scalar(i.ptr.type.elem)
            let address = value(i.ptr, locals)
            if i.op == "store":
              result.add("        (" & typ & ".atomic.store " & address &
                " " & value(i.val, locals) & ")\n")
            else:
              let operation = case i.op
                of "load": "load"
                of "add": "rmw.add"
                of "sub": "rmw.sub"
                of "swap": "rmw.xchg"
                else: ""
              result.add("        (local.set " & locals[i.dest.name] & " (" &
                typ & ".atomic." & operation & " " & address &
                (if i.op == "load": "" else: " " & value(i.val, locals)) &
                "))\n")
        of Opcode.Construct:
          let t = i.dest.type
          if not aggregate(t): raise unsupported("construction type")
          let count = if t.kind == Shape.Array: t.width else: t.fields.len
          if i.args.len != count: raise unsupported("construction arity")
          let positions = layout(t).offsets
          for index, fieldValue in i.args:
            let field = if t.kind == Shape.Array: t.elem
              else: t.fields.values.toSeq[index]
            if fieldValue.type == nil or fieldValue.type.kind != field.kind or
                (field.kind in {Shape.Int, Shape.Uint, Shape.Float} and
                  fieldValue.type.width != field.width):
              raise unsupported("construction field type")
            let offset = if t.kind == Shape.Array: index * extent(field)
              else: positions[index]
            let cell = "(i32.add " & value(i.dest, locals) &
              " (i32.const " & $offset & "))"
            if aggregate(field):
              result.add("        (memory.copy " & cell & " " &
                value(fieldValue, locals) & " (i32.const " &
                $extent(field) & "))\n")
            else:
              result.add("        (" & access(field, true) & " " & cell &
                " " & value(fieldValue, locals) & ")\n")
        of Opcode.Extract:
          let source = if i.val.type != nil: i.val else: i.ptr
          if source.type == nil: raise unsupported("projection source")
          let t = if source.type.kind == Shape.Ptr: source.type.elem
            else: source.type
          if t == nil or t.kind notin {Shape.Struct, Shape.ExternStruct} or
              i.field notin t.fields:
            raise unsupported("record field")
          var index = 0
          for name in t.fields.keys:
            if name == i.field: break
            inc index
          let field = t.fields[i.field]
          let cell = "(i32.add " & value(source, locals) &
            " (i32.const " & $layout(t).offsets[index] & "))"
          if i.op == "address":
            if i.dest.type == nil or i.dest.type.kind != Shape.Ptr or
                i.dest.type.elem != field:
              raise unsupported("record field address")
            result.add("        (local.set " & locals[i.dest.name] & " " & cell & ")\n")
          elif aggregate(field):
            result.add("        (memory.copy " & value(i.dest, locals) & " " &
              cell & " (i32.const " & $extent(field) & "))\n")
          else:
            result.add("        (local.set " & locals[i.dest.name] & " (" &
              access(field, false) & " " & cell & "))\n")
        of Opcode.Index:
          let sequence = i.val.type
          if sequence == nil or sequence.kind notin {Shape.Array, Shape.Ptr} or
              sequence.elem == nil or i.val2.type == nil or
              i.val2.type.kind notin {Shape.Int, Shape.Uint} or
              i.val2.type.width notin [8, 16, 32]:
            raise unsupported("index operand types")
          let offset = "(i32.mul " & value(i.val2, locals) &
            " (i32.const " & $extent(sequence.elem) & "))"
          let cell = "(i32.add " & value(i.val, locals) & " " & offset & ")"
          if sequence.kind == Shape.Array:
            result.add("        (if (i32.ge_u " & value(i.val2, locals) &
              " (i32.const " & $sequence.width & ")) (then unreachable))\n")
          if i.op == "address":
            if i.dest.type == nil or i.dest.type.kind != Shape.Ptr or
                i.dest.type.elem != sequence.elem:
              raise unsupported("index address")
            result.add("        (local.set " & locals[i.dest.name] & " " & cell & ")\n")
          elif aggregate(sequence.elem):
            result.add("        (memory.copy " & value(i.dest, locals) & " " &
              cell & " (i32.const " & $extent(sequence.elem) & "))\n")
          else:
            result.add("        (local.set " & locals[i.dest.name] & " (" &
              access(sequence.elem, false) & " " & cell & "))\n")
        of Opcode.Length:
          if i.val.type == nil or i.val.type.kind != Shape.Array or
              i.dest.type == nil or i.dest.type.kind notin {Shape.Int, Shape.Uint}:
            raise unsupported("length type")
          result.add("        (local.set " & locals[i.dest.name] & " (" &
            scalar(i.dest.type) & ".const " & $i.val.type.width & "))\n")
        of Opcode.Add, Opcode.Sub:
          if i.dest.type == nil or i.val.type == nil or i.val2.type == nil or
              i.dest.type.kind notin {Shape.Int, Shape.Uint, Shape.Float} or
              i.dest.type.kind != i.val.type.kind or
              i.dest.type.kind != i.val2.type.kind or
              i.dest.type.width != i.val.type.width or
              i.dest.type.width != i.val2.type.width:
            raise unsupported("arithmetic operand types")
          let typ = scalar(i.dest.type)
          let op = if i.kind == Opcode.Add: "add" else: "sub"
          result.add("        (local.set " & locals[i.dest.name] & " (" & typ & "." & op &
            " " & value(i.val, locals) & " " & value(i.val2, locals) & "))\n")
          if i.dest.type.kind in {Shape.Int, Shape.Uint}:
            let output = "(local.get " & locals[i.dest.name] & ")"
            let left = value(i.val, locals)
            let right = value(i.val2, locals)
            let bad = if i.dest.type.kind == Shape.Uint:
                if i.kind == Opcode.Add:
                  "(" & typ & ".lt_u " & output & " " & left & ")"
                else: "(" & typ & ".gt_u " & output & " " & left & ")"
              elif i.kind == Opcode.Add:
                "(" & typ & ".lt_s (" & typ & ".and (" & typ & ".xor " &
                  left & " " & output & ") (" & typ & ".xor " & right &
                  " " & output & ")) (" & typ & ".const 0))"
              else:
                "(" & typ & ".lt_s (" & typ & ".and (" & typ & ".xor " &
                  left & " " & right & ") (" & typ & ".xor " & left &
                  " " & output & ")) (" & typ & ".const 0))"
            result.add("        (if " & bad & " (then unreachable))\n")
            if i.dest.type.width in [8, 16]:
              let limit = if i.dest.type.kind == Shape.Uint:
                  (1 shl i.dest.type.width) - 1
                else: (1 shl (i.dest.type.width - 1)) - 1
              if i.dest.type.kind == Shape.Int:
                result.add("        (if (i32.lt_s " & output & " (i32.const " &
                  $(-limit - 1) & ")) (then unreachable))\n")
              result.add("        (if (i32.gt_" &
                (if i.dest.type.kind == Shape.Int: "s" else: "u") &
                " " & output & " (i32.const " & $limit &
                ")) (then unreachable))\n")
        of Opcode.Compare:
          if i.dest.type == nil or i.dest.type.kind != Shape.Bool or
              i.val.type == nil or i.val2.type == nil or
              i.val.type.kind != i.val2.type.kind or
              i.val.type.width != i.val2.type.width:
            raise unsupported("comparison operand types")
          let typ = scalar(i.val.type)
          let op = case i.op
            of "equals": "eq"
            of "does not equal": "ne"
            of "is less than": "lt"
            of "is at most": "le"
            of "is greater than": "gt"
            of "is at least": "ge"
            else: raise unsupported("comparison '" & i.op & "'")
          let signed = if i.val.type.kind == Shape.Int: "_s"
            elif i.val.type.kind in {Shape.Uint, Shape.Bool, Shape.Ptr}: "_u"
            else: ""
          result.add("        (local.set " & locals[i.dest.name] & " (" & typ & "." &
            op & (if op in ["eq", "ne"]: "" else: signed) & " " &
            value(i.val, locals) & " " & value(i.val2, locals) & "))\n")
        of Opcode.Not:
          if i.dest.type == nil or i.dest.type.kind != Shape.Bool or
              i.val.type == nil or i.val.type.kind != Shape.Bool:
            raise unsupported("non-boolean not")
          result.add("        (local.set " & locals[i.dest.name] &
            " (i32.eqz " & value(i.val, locals) & "))\n")
        of Opcode.Bit:
          if i.dest.type == nil or i.val.type == nil or
              i.dest.type.kind notin {Shape.Int, Shape.Uint} or
              i.dest.type.width notin [32, 64] or
              i.dest.type.width != i.val.type.width:
            raise unsupported("bitwise operand types")
          let op = case i.op
            of "and", "or", "xor", "shl": i.op
            of "lshr": "shr_u"
            of "ashr": "shr_s"
            of "not": "xor"
            else: raise unsupported("bitwise operation '" & i.op & "'")
          if i.op == "ashr" and i.dest.type.kind != Shape.Int:
            raise unsupported("arithmetic shift of unsigned integer")
          if i.op != "not" and (i.val2.type == nil or
              i.val2.type.width != i.dest.type.width):
            raise unsupported("bitwise right operand")
          if i.op in ["shl", "lshr", "ashr"]:
            result.add("        (if (" & scalar(i.dest.type) & ".ge_u " &
              value(i.val2, locals) & " (" & scalar(i.dest.type) &
              ".const " & $i.dest.type.width & ")) (then unreachable))\n")
          result.add("        (local.set " & locals[i.dest.name] & " (" &
            scalar(i.dest.type) & "." & op & " " & value(i.val, locals) &
            " " & (if i.op == "not": "(" & scalar(i.dest.type) & ".const -1)"
              else: value(i.val2, locals)) & "))\n")
        of Opcode.Mul, Opcode.Div, Opcode.Remainder:
          if i.dest.type == nil or i.val.type == nil or i.val2.type == nil or
              i.dest.type.kind notin {Shape.Int, Shape.Uint, Shape.Float} or
              i.dest.type.kind != i.val.type.kind or
              i.dest.type.kind != i.val2.type.kind or
              i.dest.type.width != i.val.type.width or
              i.dest.type.width != i.val2.type.width:
            raise unsupported("arithmetic operand types")
          let typ = scalar(i.dest.type)
          if i.dest.type.kind == Shape.Float and i.kind == Opcode.Remainder:
            raise unsupported("floating remainder")
          if i.dest.type.kind in {Shape.Int, Shape.Uint} and
              i.dest.type.width notin [32, 64]:
            raise unsupported("narrow checked arithmetic")
          let left = value(i.val, locals)
          let right = value(i.val2, locals)
          if i.kind == Opcode.Mul and typ == "i32":
            let extension = if i.dest.type.kind == Shape.Int:
                "i64.extend_i32_s" else: "i64.extend_i32_u"
            result.add("        (local.set $wide (i64.mul (" & extension & " " &
              left & ") (" & extension & " " & right & ")))\n")
            result.add("        (local.set " & locals[i.dest.name] &
              " (i32.wrap_i64 (local.get $wide)))\n")
            result.add("        (if (i64.ne (local.get $wide) (" & extension &
              " (local.get " & locals[i.dest.name] & "))) (then unreachable))\n")
            continue
          let op = case i.kind
            of Opcode.Mul: "mul"
            of Opcode.Div: (if i.dest.type.kind == Shape.Float: "div"
              elif i.dest.type.kind == Shape.Int: "div_s" else: "div_u")
            of Opcode.Remainder: (if i.dest.type.kind == Shape.Int: "rem_s"
              else: "rem_u")
            else: ""
          result.add("        (local.set " & locals[i.dest.name] & " (" & typ &
            "." & op & " " & left & " " & right & "))\n")
          if i.kind == Opcode.Mul and typ == "i64":
            result.add("        (if (i64.ne " & right & " (i64.const 0)) (then\n")
            result.add("          (if (i64.ne (i64.div_" &
              (if i.dest.type.kind == Shape.Int: "s" else: "u") &
              " (local.get " & locals[i.dest.name] & ") " & right &
              ") " & left & ") (then unreachable))\n")
            result.add("        ))\n")
        of Opcode.Call:
          if i.func notin functions and i.func notin externs:
            raise unsupported("external or mismatched call '" & i.func & "'")
          let returned = if i.func in functions: functions[i.func].ret
            else: externs[i.func].ret
          let arity = if i.func in functions: functions[i.func].params.len
            else: externs[i.func].params.len
          if i.args.len != arity:
            raise unsupported("mismatched call '" & i.func & "'")
          for argIndex, arg in i.args:
            let expected = if i.func in functions:
                functions[i.func].params[argIndex].type
              else: externs[i.func].params[argIndex]
            if not equivalent(arg.type, expected):
              raise unsupported("call argument type '" & i.func & "'")
          var call = "(call $" & i.func
          if aggregate(returned):
            if i.dest.name notin locals or
                not equivalent(i.dest.type, returned):
              raise unsupported("aggregate call result")
            call.add(" " & value(i.dest, locals))
          for argIndex, arg in i.args:
            if i.func in externs and aggregate(externs[i.func].params[argIndex]):
              let offset = slots["call." & section.label & "." &
                $instructionIndex & "." & $argIndex]
              let copy = "(i32.add (local.get $frame) (i32.const " &
                $offset & "))"
              result.add("        (memory.copy " & copy & " " &
                value(arg, locals) & " (i32.const " &
                $extent(arg.type) & "))\n")
              call.add(" " & copy)
            else:
              call.add(" " & value(arg, locals))
          call.add(")")
          if returned == nil or returned.kind == Shape.Void or
              aggregate(returned):
            result.add("        " & call & "\n")
          else:
            if i.dest.name notin locals or
                scalar(i.dest.type) != scalar(returned):
              raise unsupported("call result type")
            result.add("        (local.set " & locals[i.dest.name] & " " & call & ")\n")
        else: raise unsupported("instruction " & $i.kind)
      let term = section.term
      case term.kind
      of Opcode.Return:
        if aggregate(fn.ret):
          result.add("        (memory.copy (local.get $result) " &
            value(term.value, locals) & " (i32.const " &
            $extent(fn.ret) & "))\n")
        if usage > 0:
          result.add("        (global.set $stack (i32.add (local.get $frame) " &
            "(i32.const " & $usage & ")))\n")
        if fn.ret == nil or fn.ret.kind == Shape.Void or aggregate(fn.ret):
          result.add("        (return)\n")
        else:
          result.add("        (return " & value(term.value, locals) & ")\n")
      of Opcode.Panic:
        result.add("        unreachable\n")
      of Opcode.Jump, Opcode.Cjump:
        proc edge(label: string; args: seq[Value]): string =
          if label notin blocks: raise unsupported("unknown block '" & label & "'")
          let destination = fn.blocks[blocks[label]]
          var live: seq[Value]
          for item in args:
            if item.type != nil and item.type.kind != Shape.Memory: live.add(item)
          var params: seq[Value]
          for item in destination.params:
            if item.type != nil and item.type.kind != Shape.Memory: params.add(item)
          if live.len != params.len: raise unsupported("block argument count")
          for position, item in params:
            result.add("          (local.set " & locals[item.name] & " " &
              value(live[position], locals) & ")\n")
          result.add("          (local.set $pc (i32.const " & $blocks[label] & "))\n")
          result.add("          (br $dispatch)\n")
        if term.kind == Opcode.Jump:
          result.add(edge(term.label, term.args))
        else:
          if term.cond.type == nil or term.cond.type.kind != Shape.Bool:
            raise unsupported("branch condition")
          result.add("        (if " & value(term.cond, locals) & " (then\n")
          result.add(edge(term.yes, term.positive))
          result.add("        ) (else\n")
          result.add(edge(term.no, term.negative))
          result.add("        ))\n")
      else: raise unsupported("terminator " & $term.kind)
      result.add("      ))\n")
    result.add("      unreachable\n    )\n    unreachable\n  )\n")
  if entry:
    result.add("  (func $_start (export \"_start\")\n")
    if completion == nil or completion.kind == Shape.Void:
      result.add("    (call $main)")
    elif completion.width == 32:
      result.add("    (call $wasi_proc_exit (call $main))")
    else:
      result.add("    (call $wasi_proc_exit (i32.wrap_i64 (call $main)))")
    result.add("\n  )\n")
  if threaded:
    result.add("  (func (export \"wasi_thread_start\") " &
      "(param i32) (param i32)\n" &
      "    (call $thread_main (local.get 0) (local.get 1))\n  )\n")
  result.add(")\n")
