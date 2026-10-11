## Typed IR -> LLVM. Integer checks operate at semantic width, never storage width.
import std/[strutils, tables, sequtils, os, json]
import ../../ir/[node, kind, monomorph]
import ./[layout, runtime]
import ./abi
import ../../opt/arch as targetArch

proc llvmString(value: string): string =
  result = "\""
  for character in value:
    if character < ' ' or character > '~' or character in {'\"', '\\'}:
      result.add("\\" & toHex(ord(character), 2))
    else: result.add(character)
  result.add('"')

proc quotedName(name: string): string = "\"" & name.replace("\\", "\\5C").replace("\"", "\\22") & "\""
proc functionName(name: string): string = "@" & quotedName("foo." & name)

proc emit*(module: Module; triple, dataLayout: string; support: Support; sourceFile = "main.iv"; hosted = true; cpu = ""; modernMemory = true): string =
  let profile = targetArch.profile(triple,cpu)
  var startup = false
  var contracts = initTable[string,NativeContract]()
  for contract in module.native:
    if contract.stage == "@asm": contracts[contract.id] = contract
  var globals, definitions: seq[string]
  var declarations = initOrderedTable[string,string]()
  var functions = initTable[string,node.Function]()
  var externs = initTable[string,Extern]()
  for fn in module.funcs: functions[fn.name] = fn
  for external in module.externs: externs[external.name] = external
  proc stringPointer(data: seq[byte]; terminated = false): string =
    let symbol = "@foo.bytes." & $globals.len
    var literal = ""
    for b in data: literal.add("\\" & toHex(b,2))
    if terminated: literal.add("\\00")
    globals.add(symbol & " = private constant [" & $(data.len + ord(terminated)) & " x i8] c\"" & literal & "\"")
    symbol
  proc cstring(text: string): string =
    var data: seq[byte]
    for c in text: data.add(byte(c))
    stringPointer(data,true)
  proc scalar(v: Value): string =
    if v.type == nil: raise newException(ValueError,"untyped LLVM constant")
    case v.type.kind
    of TypeKind.Bool: (if v.name == "true": "1" else: "0")
    of TypeKind.Int, TypeKind.Uint: v.name.replace("_", "")
    of TypeKind.Float:
      var number: float64
      if v.bits.len > 0:
        if v.type.width == 32: number = float64(cast[float32](uint32(parseHexInt(v.bits))))
        else: number = cast[float64](parseHexInt(v.bits).uint64)
      else: number = parseFloat(v.name)
      if v.type.width == 32: number = float64(float32(number))
      "0x" & toHex(cast[uint64](number),16)
    of TypeKind.Ptr, TypeKind.Function: (if v.name == "null": "null" else: raise newException(ValueError,"non-null pointer literal"))
    of TypeKind.Error: cstring(v.name)
    else: raise newException(ValueError,"non-scalar constant " & v.type.label)
  proc initializer(v: Value): tuple[typ, literal: string] =
    # Storage is addressed through opaque pointers. A constant's physical LLVM
    # struct can therefore retain relocations while ordinary loads use the FOO
    # byte-array representation. Padding is explicit and checked by layout tests.
    if v.name == "undefined" or (v.type.kind == TypeKind.Optional and v.name == "null") or
        (v.type.kind == TypeKind.Void and v.name in ["void", "{}"]):
      return (llvmType(v.type), "zeroinitializer")
    if v.type.kind == TypeKind.Slice:
      let data = bytes(v.name)
      return ("{ ptr, i64 }", "{ ptr " & stringPointer(data) & ", i64 " & $data.len & " }")
    if v.type.kind in {TypeKind.Optional, TypeKind.Failable}:
      let layout = measure(v.type)
      let tagType = if v.type.kind == TypeKind.Optional: "i8" else: "ptr"
      let tag = if v.type.kind == TypeKind.Optional: "1" else: "null"
      let tagSize = if v.type.kind == TypeKind.Optional: 1 else: 8
      var inner = v; inner.type = v.type.elem
      let payload = if inner.type.kind == TypeKind.Void: (typ: "i8", literal: "0") else: initializer(inner)
      let payloadSize = if inner.type.kind == TypeKind.Void: 1 else: measure(inner.type).size
      var types = @[tagType]; var values = @[tagType & " " & tag]
      proc padding(count: int) =
        if count > 0:
          let typ = "[" & $count & " x i8]"
          types.add(typ); values.add(typ & " zeroinitializer")
      padding(layout.offsets[1] - tagSize)
      types.add(payload.typ); values.add(payload.typ & " " & payload.literal)
      padding(layout.size - layout.offsets[1] - payloadSize)
      return ("{ " & types.join(", ") & " }", "{ " & values.join(", ") & " }")
    if aggregate(v.type): raise newException(ValueError,"LLVM global initializer is not representable by the frontend constant: " & v.type.label)
    (llvmType(v.type), scalar(v))
  for item in module.storage:
    let constant = initializer(item.value)
    globals.add("@" & quotedName("storage." & item.name) & " = global " & constant.typ & " " & constant.literal & ", align " & $measure(item.value.type).alignment)
  for functionIndex in 0 ..< module.funcs.len:
    let fn = module.funcs[functionIndex]
    if fn.blocks.len == 0: raise newException(ValueError,"function has no blocks: " & fn.name)
    if fn.abi notin ["", "foo", "foo:1", "c", "system", "stdcall", "fastcall", "vectorcall", "thiscall"] or fn.attributes.anyIt(it notin ["noinline", "naked", "interrupt", "start"] and not it.startsWith("target_feature(") and not it.startsWith("borrows(") and not it.startsWith("releases(")):
      raise newException(ValueError,"LLVM function ABI/attribute needs qualification: " & fn.name)
    var featureAttributes: seq[string]
    for attribute in fn.attributes:
      if attribute.startsWith("target_feature(\"") and attribute.endsWith("\")"):
        let feature = attribute[16 ..< attribute.len - 2]
        if feature.len == 0 or feature.anyIt(not (it.isLowerAscii or it.isDigit or it == '_')):
          raise newException(ValueError, "invalid target feature on " & fn.name)
        let normalized = feature.replace('_', '.')
        if normalized notin profile.features:
          raise newException(ValueError, "CPU feature " & feature & " is not enabled for " & profile.cpu & " in " & fn.name)
        if "interrupt" in fn.attributes:
          raise newException(ValueError, "x64 interrupt feature clauses need a separately verified register-preservation contract: " & fn.name)
        featureAttributes.add("+" & normalized)
    let featureClause = if featureAttributes.len > 0: " \"target-features\"=" & llvmString(featureAttributes.join(",")) else: ""
    if "start" in fn.attributes:
      startup = true
      if hosted: raise newException(ValueError, "startup requires runtime none: " & fn.name)
      globals.add("@_start = alias " & llvmType(fn.ret) & " (" & fn.params.mapIt(llvmType(it.type)).join(", ") & "), ptr " & functionName(fn.name))
    if "naked" in fn.attributes:
      if fn.params.len > 0 or fn.ret.kind != TypeKind.Void or fn.blocks.len != 1:
        raise newException(ValueError, "setup-free bodies require a parameterless unit function and one native block: " & fn.name)
      var lines: seq[string]
      for instruction in fn.blocks[0].instrs:
        if instruction.kind != InstrKind.Native or instruction.args.len > 0 or not contracts.hasKey(instruction.symbol):
          raise newException(ValueError, "setup-free body may contain only direct assembly, never helper calls: " & fn.name)
        let contract = contracts[instruction.symbol]
        var assembly = contract.code.strip()
        if assembly.startsWith("\""):
          try: assembly = parseJson(assembly).getStr()
          except CatchableError: raise newException(ValueError, "setup-free assembly cannot contain C constraints or output bindings: " & fn.name)
        assembly = assembly.replace("$", "$$")
        lines.add("  call void asm sideeffect " & llvmString(assembly) & ", \"~{memory}\"()")
      if fn.blocks[0].term.kind != InstrKind.Return:
        raise newException(ValueError, "setup-free control flow must be owned by assembly: " & fn.name)
      lines.add("  unreachable")
      definitions.add("define " & (if "interrupt" in fn.attributes: "x86_intrcc " else: "") & llvmType(fn.ret) & " " & functionName(fn.name) & "() naked noinline" & featureClause & " {\nentry:\n" & lines.join("\n") & "\n}")
      continue
    if "interrupt" in fn.attributes:
      if not triple.startsWith("x86_64-") or fn.ret.kind != TypeKind.Void or fn.params.len > 1 or
          (fn.params.len == 1 and llvmType(fn.params[0].type) != "i64"):
        raise newException(ValueError, "qualified x64 interrupt ABI requires unit result and optional 64-bit error code: " & fn.name)
      globals.add("@" & llvmString(fn.name) & " = alias void (ptr" &
        (if fn.params.len == 1: ", i64" else: "") & "), ptr " & functionName(fn.name))
    var code, allocas, initializers: seq[string]
    var slots = initTable[string,string]()
    var blocks = initTable[string,Block]()
    var counter = 0
    var current: string
    var predecessor: string
    proc temp(): string =
      inc counter; "%t" & $counter
    proc line(text: string) = code.add("  " & text)
    proc blockLabel(prefix: string): string =
      inc counter; prefix & $counter
    proc start(label: string) =
      current = label; code.add(quotedName(label) & ":")
    proc branch(label: string) = line("br label %" & quotedName(label))
    proc stack(t: node.Type; zero = false): string =
      result = temp()
      allocas.add("  " & result & " = alloca " & llvmType(t) & ", align " & $measure(t).alignment)
      if zero: initializers.add("  store " & llvmType(t) & " zeroinitializer, ptr " & result & ", align 1")
    proc register(v: Value) =
      if v.kind == ValueKind.Reg and v.name.len > 0 and v.type != nil and v.type.kind notin {TypeKind.Void,TypeKind.Memory,TypeKind.Region,TypeKind.Trace} and v.name notin slots:
        slots[v.name] = stack(v.type)
    proc collect(i: Instruction) =
      if i == nil: return
      register(i.dest)
      if i.fallback != nil:
        for p in i.fallback.params: register(p)
        for child in i.fallback.instrs: collect(child)
        collect(i.fallback.term)
    for parameter in fn.params: register(parameter)
    for b in fn.blocks:
      blocks[b.label] = b
      for p in b.params: register(p)
      for i in b.instrs: collect(i)
      collect(b.term)
    proc load(t: node.Type; address: string; volatile = false): string =
      if t.kind == TypeKind.Void: return "zeroinitializer"
      result = temp()
      line(result & " = load " & (if volatile: "volatile " else: "") & llvmType(t) & ", ptr " & address & ", align 1")
    proc store(t: node.Type; value, address: string; volatile = false) =
      if t.kind == TypeKind.Void: return
      line("store " & (if volatile: "volatile " else: "") & llvmType(t) & " " & value & ", ptr " & address & ", align 1")
    proc offset(address: string; bytes: string): string =
      result = temp(); line(result & " = getelementptr i8, ptr " & address & ", i64 " & bytes)
    proc value(v: Value): string
    proc box(v: Value): string =
      if v.type != nil and v.type.kind == TypeKind.Void: return "null"
      if v.kind == ValueKind.Reg and v.name in slots: return slots[v.name]
      result = stack(v.type); store(v.type,value(v),result)
    proc value(v: Value): string =
      if v.type != nil and v.type.kind == TypeKind.Void: return "zeroinitializer"
      if v.kind == ValueKind.Const and v.name == "undefined": return "zeroinitializer"
      case v.kind
      of ValueKind.Reg:
        if v.name notin slots: raise newException(ValueError,"undefined typed register " & v.name)
        return load(v.type, slots[v.name])
      of ValueKind.Global:
        if v.name in functions and functions[v.name].attributes.anyIt(it in ["naked", "interrupt", "start"]): return functionName(v.name)
        if v.name in functions or v.name in externs:
          let adapter = callbackName(v.name)
          declarations[adapter] = "declare void @" & adapter & "(...)"
          return "@" & adapter
        for item in module.storage:
          if item.name == v.name: return "@" & quotedName("storage." & v.name)
        raise newException(ValueError,"undefined global " & v.name)
      of ValueKind.Const: discard
      if aggregate(v.type):
        if v.type.kind == TypeKind.Optional and v.name == "null": return "zeroinitializer"
        if v.type.kind in {TypeKind.Optional,TypeKind.Failable}:
          let address = stack(v.type); store(v.type,"zeroinitializer",address)
          if v.type.kind == TypeKind.Optional: store(node.Type(kind:TypeKind.Bool),"1",address)
          if v.type.elem.kind != TypeKind.Void:
            var inner = v; inner.type = v.type.elem
            store(inner.type,value(inner),offset(address,$measure(v.type).offsets[1]))
          return load(v.type,address)
        if v.name in ["void", "{}"]: return "zeroinitializer"
        if v.type.kind == TypeKind.Slice:
          let data = bytes(v.name); let address = stack(v.type)
          store(node.Type(kind: TypeKind.Ptr),stringPointer(data),address)
          store(node.Type(kind: TypeKind.Uint,width:64),$data.len,offset(address,"8"))
          return load(v.type,address)
        raise newException(ValueError,"unsupported aggregate constant")
      scalar(v)
    proc save(v: Value; expression: string) =
      if v.type != nil and v.type.kind != TypeKind.Void: store(v.type,expression,slots[v.name])
    proc bound(t: node.Type; expression: string): Value =
      result = Value(kind:ValueKind.Reg,name:temp(),type:t)
      slots[result.name] = stack(t)
      save(result,expression)
    proc lane(t: node.Type; address: string; index: int): Value =
      bound(t.elem,load(t.elem,offset(address,$(index * measure(t.elem).size))))
    proc castInteger(expression: string; source, target: node.Type): string =
      let a = llvmType(source); let b = llvmType(target)
      if a == b: return expression
      if storageWidth(target) < storageWidth(source): raise newException(ValueError,"narrowing conversion lacks frontend range proof")
      result = temp(); line(result & " = " & (if source.kind == TypeKind.Int: "sext" else: "zext") & " " & a & " " & expression & " to " & b)
    proc assigned(v: Value; target: node.Type): string =
      if v.type == nil:
        if target.kind == TypeKind.Void or (target.kind == TypeKind.Failable and target.elem.kind == TypeKind.Void):
          return "zeroinitializer"
        raise newException(ValueError, "missing value for " & target.label)
      if target.kind in {TypeKind.Optional,TypeKind.Failable} and v.type.kind != target.kind:
        let address = stack(target); store(target,"zeroinitializer",address)
        if target.kind == TypeKind.Optional: store(node.Type(kind: TypeKind.Bool),"1",address)
        if target.elem.kind != TypeKind.Void: store(target.elem,assigned(v,target.elem),offset(address,$measure(target).offsets[1]))
        return load(target,address)
      if target.kind in {TypeKind.Int,TypeKind.Uint} and v.type.kind in {TypeKind.Int,TypeKind.Uint}: return castInteger(value(v),v.type,target)
      return value(v)
    proc trace(i: Instruction) =
      if not hosted: return
      line("call void @foo_llvm_trace(ptr " & cstring(i.trace) & ", ptr " & cstring(i.span.file) & ", i64 " & $i.span.start & ")")
    proc panic(message: string; i: Instruction) =
      if not hosted:
        declarations["llvm.trap"] = "declare void @llvm.trap()"
        line("call void @llvm.trap()"); line("unreachable"); return
      trace(i); line("call void @foo_llvm_panic(ptr " & cstring(message) & ")"); line("unreachable")
    proc guard(predicate, message: string; i: Instruction) =
      let bad = blockLabel("checked.fail."); let good = blockLabel("checked.pass.")
      line("br i1 " & predicate & ", label %" & quotedName(bad) & ", label %" & quotedName(good))
      start(bad); panic(message,i); start(good)
    proc predicate(v: Value): string =
      result = temp(); let input = value(v)
      line(result & " = icmp ne " & llvmType(v.type) & " " & input & ", 0")
    var cleanups: seq[tuple[instruction: Instruction, flag: string]]
    var regions = initOrderedTable[string,string]()
    var allocations = initTable[pointer,string]()
    proc findCleanups(i: Instruction) =
      if i == nil: return
      if i.kind == InstrKind.Defer: cleanups.add((i,stack(node.Type(kind:TypeKind.Bool),true)))
      if i.kind == InstrKind.Alloc and i.op != "slot":
        allocations[cast[pointer](i)] = stack(node.Type(kind:TypeKind.Ptr),true)
      if i.kind in {InstrKind.Region,InstrKind.Allocate} and i.target.type == nil and i.region notin regions:
        regions[i.region] = stack(node.Type(kind:TypeKind.Ptr),true)
      if i.fallback != nil:
        for child in i.fallback.instrs: findCleanups(child)
    for b in fn.blocks:
      for i in b.instrs: findCleanups(i)
    proc instruction(i: Instruction)
    proc cleanup(error: string) =
      for index in countdown(cleanups.high,0):
        let item = cleanups[index]; let active = load(node.Type(kind:TypeKind.Bool),item.flag)
        var pred = temp(); line(pred & " = icmp ne i8 " & active & ", 0")
        if item.instruction.error:
          let combined = temp(); line(combined & " = and i1 " & pred & ", " & error); pred = combined
        let run = blockLabel("cleanup.run."); let done = blockLabel("cleanup.done.")
        line("br i1 " & pred & ", label %" & quotedName(run) & ", label %" & quotedName(done)); start(run)
        store(node.Type(kind:TypeKind.Bool),"0",item.flag)
        for child in item.instruction.fallback.instrs: instruction(child)
        branch(done); start(done)
      for slot in allocations.values:
        line("call void @foo_llvm_free(ptr " & slot & ")")
      for region in regions.values: line("call void @foo_llvm_close(ptr " & region & ")")
    proc returned(v: Value) =
      if fn.ret.kind == TypeKind.Void: cleanup("false"); line("ret void"); return
      let output = assigned(v,fn.ret)
      var failed = "false"
      if fn.ret.kind == TypeKind.Failable:
        let address = stack(fn.ret); store(fn.ret,output,address)
        let error = load(node.Type(kind:TypeKind.Error),address)
        failed = temp(); line(failed & " = icmp ne ptr " & error & ", null")
      cleanup(failed); line("ret " & llvmType(fn.ret) & " " & output)
    proc transfer(label: string; args: seq[Value]) =
      if label notin blocks: raise newException(ValueError,"unknown block " & label)
      let target = blocks[label]
      var pending: seq[tuple[dest:Value, expression:string]]
      var index = 0
      for p in target.params:
        if p.type.kind notin {TypeKind.Memory, TypeKind.Void}:
          while index < args.len and args[index].type.kind == TypeKind.Memory: inc index
          if index >= args.len: raise newException(ValueError,"missing block argument")
          pending.add((p,assigned(args[index],p.type))); inc index
      for i in target.instrs:
        if i.kind == InstrKind.Phi:
          for edge in i.blocks:
            if edge.label == predecessor: pending.add((i.dest,assigned(edge.value,i.dest.type)))
      for pair in pending: save(pair.dest,pair.expression)
      branch(label)
    proc packedComparison(typ: node.Type; left, right, operation: string): string =
      # Logical fields determine order; padding and backing integer order do not.
      let backing = "i" & $max(1,packedBits(typ))
      let a = temp(); let b = temp()
      line(a & " = load " & backing & ", ptr " & left & ", align 1")
      line(b & " = load " & backing & ", ptr " & right & ", align 1")
      var leaves: seq[tuple[typ: node.Type, bit: int]]
      proc fields(t: node.Type; bit: int) =
        if t.kind == TypeKind.PackedStruct:
          var at = bit
          for field in t.fields.values:
            fields(field,at); at += packedBits(field)
        else: leaves.add((t,bit))
      fields(typ,0)
      var order = "0"
      for index in countdown(leaves.high,0):
        let field = leaves[index]
        let fieldType = "i" & $packedBits(field.typ)
        proc extract(input: string): string =
          result = input
          if field.bit > 0:
            result = temp(); line(result & " = lshr " & backing & " " & input & ", " & $field.bit)
          if fieldType != backing:
            let narrowed = temp(); line(narrowed & " = trunc " & backing & " " & result & " to " & fieldType); result = narrowed
        let x = extract(a); let y = extract(b)
        let same = temp(); let less = temp(); let difference = temp(); let next = temp()
        line(same & " = icmp eq " & fieldType & " " & x & ", " & y)
        line(less & " = icmp " & (if field.typ.kind == TypeKind.Int: "slt" else:"ult") & " " & fieldType & " " & x & ", " & y)
        line(difference & " = select i1 " & less & ", i32 -1, i32 1")
        line(next & " = select i1 " & same & ", i32 " & order & ", i32 " & difference)
        order = next
      let predicate = {"equals":"eq", "does-not-equal":"ne", "less-than":"slt",
        "less-or-equal":"sle", "greater-than":"sgt", "greater-or-equal":"sge"}.toTable[operation]
      let comparison = temp(); result = temp()
      line(comparison & " = icmp " & predicate & " i32 " & order & ", 0")
      line(result & " = zext i1 " & comparison & " to i8")
    proc arithmetic(i: Instruction) =
      let t = i.dest.type; let ty = llvmType(t)
      if t.kind == TypeKind.Vector:
        let a = box(i.val); let b = box(i.val2)
        for index in 0..<t.width:
          let left = lane(t,a,index); let right = lane(t,b,index)
          let dest = bound(t.elem,"zeroinitializer")
          arithmetic(Instruction(kind:i.kind,dest:dest,val:left,val2:right,span:i.span,op:i.op))
          store(t.elem,value(dest),offset(slots[i.dest.name],$(index * measure(t.elem).size)))
        return
      if t.kind == TypeKind.Slice and i.kind == InstrKind.Add:
        let a = box(i.val); let b = box(i.val2)
        line("call void @foo_llvm_join(ptr " & slots[i.dest.name] & ", ptr " & a & ", ptr " & b & ")"); return
      let left = value(i.val); let right = value(i.val2)
      let operation = case i.kind
        of InstrKind.Add: "add"
        of InstrKind.Sub: "sub"
        of InstrKind.Mul: "mul"
        of InstrKind.Div: "div"
        else: "rem"
      if t.kind == TypeKind.Float:
        let output = temp(); line(output & " = f" & operation & " " & ty & " " & left & ", " & right); save(i.dest,output); return
      if t.kind notin {TypeKind.Int,TypeKind.Uint}: raise newException(ValueError,"unsupported arithmetic type " & t.label)
      let signed = t.kind == TypeKind.Int; let narrow = "i" & $width(t)
      var a = left; var b = right
      if width(t) != storageWidth(t):
        a = temp(); b = temp(); line(a & " = trunc " & ty & " " & left & " to " & narrow); line(b & " = trunc " & ty & " " & right & " to " & narrow)
      var output = temp()
      if i.kind in {InstrKind.Add,InstrKind.Sub,InstrKind.Mul}:
        let intrinsic = "llvm." & (if signed: "s" else: "u") & operation & ".with.overflow." & narrow
        declarations[intrinsic] = "declare { " & narrow & ", i1 } @" & intrinsic & "(" & narrow & ", " & narrow & ")"
        let pair = temp(); let overflow = temp()
        line(pair & " = call { " & narrow & ", i1 } @" & intrinsic & "(" & narrow & " " & a & ", " & narrow & " " & b & ")")
        line(output & " = extractvalue { " & narrow & ", i1 } " & pair & ", 0")
        line(overflow & " = extractvalue { " & narrow & ", i1 } " & pair & ", 1"); guard(overflow,"IntegerOverflow",i)
      else:
        let zero = temp(); line(zero & " = icmp eq " & narrow & " " & b & ", 0"); guard(zero,"DivisionByZero",i)
        if signed:
          let min = temp(); let negativeOne = temp(); let special = temp(); let minimum = temp()
          line(minimum & " = shl " & narrow & " -1, " & $(width(t)-1))
          line(min & " = icmp eq " & narrow & " " & a & ", " & minimum)
          line(negativeOne & " = icmp eq " & narrow & " " & b & ", -1"); line(special & " = and i1 " & min & ", " & negativeOne)
          if i.kind == InstrKind.Div: guard(special,"IntegerOverflow",i)
          else:
            let safe = temp(); line(safe & " = select i1 " & special & ", " & narrow & " 1, " & narrow & " " & b); b = safe
        line(output & " = " & (if signed: "s" else: "u") & operation & " " & narrow & " " & a & ", " & b)
      if width(t) != storageWidth(t):
        let extended = temp(); line(extended & " = " & (if signed: "sext" else: "zext") & " " & narrow & " " & output & " to " & ty); output = extended
      save(i.dest,output)
    proc instruction(i: Instruction) =
      if i == nil: raise newException(ValueError,"missing terminator")
      line("; " & $i.kind & " " & i.span.file.replace("\n"," ").replace("\r"," ") & ":" & $i.span.start & ".." & $i.span.end)
      try:
        if not hosted and (i.kind in {InstrKind.Region, InstrKind.Allocate, InstrKind.Trace} or (i.kind == InstrKind.Alloc and i.op != "slot") or (i.kind == InstrKind.Add and i.dest.type.kind == TypeKind.Slice)):
          raise newException(ValueError,"runtime none cannot lower hosted allocation/text/issue-trail operation " & $i.kind)
        case i.kind
        of InstrKind.Alloc:
          if i.op == "slot": save(i.dest,stack(i.dest.type.elem))
          else:
            let cell = allocations[cast[pointer](i)]
            let pointer = temp(); let m = measure(i.dest.type.elem)
            line(pointer & " = call ptr @foo_llvm_alloc(ptr " & cell & ", i64 " & $m.size & ", i64 " & $max(8,m.alignment) & ")")
            save(i.dest,pointer)
        of InstrKind.Region:
          if i.op == "open": line("call void @foo_llvm_close(ptr " & regions[i.region] & ")")
          elif i.op == "close": line("call void @foo_llvm_close(ptr " & regions[i.region] & ")")
          else: raise newException(ValueError,"unknown region operation " & i.op)
        of InstrKind.Allocate:
          if i.target.type != nil: raise newException(ValueError,"explicit allocator allocation needs its runtime adapter")
          let address = slots[i.dest.name]; let typ = i.dest.type
          store(typ,"zeroinitializer",address)
          let count = castInteger(value(i.val),i.val.type,node.Type(kind:i.val.type.kind,width:64))
          let invalid = temp(); line(invalid & " = icmp slt i64 " & count & ", 0")
          let bad = blockLabel("allocate.invalid."); let reserve = blockLabel("allocate.reserve."); let done = blockLabel("allocate.done.")
          line("br i1 " & (if i.val.type.kind == TypeKind.Int: invalid else: "false") & ", label %" & quotedName(bad) & ", label %" & quotedName(reserve))
          start(bad); store(node.Type(kind:TypeKind.Error),cstring("InvalidSize"),address); branch(done)
          start(reserve)
          let pointer = temp(); line(pointer & " = call ptr @foo_llvm_reserve(ptr " & regions[i.region] & ", i64 " & count & ")")
          let missing = temp(); line(missing & " = icmp eq ptr " & pointer & ", null")
          let failed = blockLabel("allocate.failed."); let success = blockLabel("allocate.success.")
          line("br i1 " & missing & ", label %" & quotedName(failed) & ", label %" & quotedName(success))
          start(failed); store(node.Type(kind:TypeKind.Error),cstring("OutOfMemory"),address); branch(done)
          start(success)
          let payload = offset(address,$measure(typ).offsets[1]); store(node.Type(kind:TypeKind.Ptr),pointer,payload)
          store(node.Type(kind:TypeKind.Uint,width:64),count,offset(payload,"8")); branch(done); start(done)
        of InstrKind.Load: save(i.dest,load(i.dest.type,value(i.ptr),i.ptr.type.volatile or i.ptr.type.elem.volatile))
        of InstrKind.Store: store(i.ptr.type.elem,assigned(i.val,i.ptr.type.elem),value(i.ptr),i.ptr.type.volatile or i.ptr.type.elem.volatile)
        of InstrKind.Add,InstrKind.Sub,InstrKind.Mul,InstrKind.Div,InstrKind.Remainder: arithmetic(i)
        of InstrKind.Convert:
          let source = i.val.type; let target = i.dest.type
          if source.kind in {TypeKind.Int,TypeKind.Uint} and target.kind == TypeKind.Float:
            let outVal = temp(); let input = value(i.val)
            line(outVal & " = " & (if source.kind == TypeKind.Int: "sitofp" else: "uitofp") & " " & llvmType(source) & " " & input & " to " & llvmType(target)); save(i.dest,outVal)
          elif source.kind == TypeKind.Float and target.kind == TypeKind.Float and source.width < target.width:
            let outVal = temp(); let input = value(i.val)
            line(outVal & " = fpext " & llvmType(source) & " " & input & " to " & llvmType(target)); save(i.dest,outVal)
          else: save(i.dest,assigned(i.val,target))
        of InstrKind.Atomic:
          let order = case i.field
            of "relaxed": "monotonic"
            of "consume": "acquire"
            of "acquire", "release", "acq_rel", "seq_cst": i.field
            else: raise newException(ValueError, "unknown atomic ordering " & i.field)
          if i.op == "fence":
            if order != "monotonic": line("fence " & order)
          else:
            let element = i.ptr.type.elem
            if element.kind notin {TypeKind.Int, TypeKind.Uint, TypeKind.Bool, TypeKind.Ptr} or measure(element).size > 8:
              raise newException(ValueError, "atomic representation not qualified: " & element.label)
            let typ = llvmType(element)
            let alignment = $measure(element).alignment
            let pointer = value(i.ptr)
            if i.op == "store":
              line("store atomic " & typ & " " & assigned(i.val,element) & ", ptr " & pointer & " " & order & ", align " & alignment)
            else:
              let value = temp()
              if i.op == "load": line(value & " = load atomic " & typ & ", ptr " & pointer & " " & order & ", align " & alignment)
              elif i.op in ["add", "swap"]:
                line(value & " = atomicrmw " & (if i.op == "add": "add" else: "xchg") & " ptr " & pointer & ", " & typ & " " & assigned(i.val,element) & " " & order & ", align " & alignment)
              else: raise newException(ValueError, "unsupported atomic operation " & i.op)
              if i.dest.type != nil and i.dest.type.kind != TypeKind.Void: save(i.dest, value)
        of InstrKind.Call, InstrKind.Thread:
          if i.func in externs:
            let external = externs[i.func]; let adapter = bridgeName(external)
            var arguments = @["ptr " & (if i.dest.type == nil or i.dest.type.kind == TypeKind.Void: "null" else: slots[i.dest.name])]
            for arg in i.args: arguments.add("ptr " & box(arg))
            declarations[adapter] = "declare void @" & adapter & "(" & newSeqWith(arguments.len,"ptr").join(", ") & ")"
            line("call void @" & adapter & "(" & arguments.join(", ") & ")")
          elif i.callee.type != nil:
            let adapter = indirectName(i.callee.type)
            var arguments = @["ptr " & (if i.dest.type == nil or i.dest.type.kind == TypeKind.Void: "null" else: slots[i.dest.name]), "ptr " & value(i.callee)]
            for arg in i.args: arguments.add("ptr " & box(arg))
            declarations[adapter] = "declare void @" & adapter & "(" & newSeqWith(arguments.len,"ptr").join(", ") & ")"
            line("call void @" & adapter & "(" & arguments.join(", ") & ")")
          else:
            var parameters: seq[node.Type]
            var ret: node.Type
            var target: string
            if i.callee.type != nil: target = value(i.callee); parameters = i.callee.type.params; ret = i.callee.type.ret
            elif i.func in functions: target = functionName(i.func); parameters = functions[i.func].params.mapIt(it.type); ret = functions[i.func].ret
            else: raise newException(ValueError,"unbound call " & i.func)
            if parameters.len != i.args.len: raise newException(ValueError,"call arity mismatch")
            var args: seq[string]
            for index, arg in i.args:
              if parameters[index].kind != TypeKind.Void:
                args.add(llvmType(parameters[index]) & " " & assigned(arg,parameters[index]))
            let output = if ret.kind == TypeKind.Void: "" else: temp()
            line((if output.len == 0: "" else: output & " = ") & "call " & llvmType(ret) & " " & target & "(" & args.join(", ") & ")")
            if output.len > 0: save(i.dest,output)
        of InstrKind.Splat:
          let typ = i.dest.type; let input = assigned(i.val,typ.elem)
          for index in 0..<typ.width: store(typ.elem,input,offset(slots[i.dest.name],$(index * measure(typ.elem).size)))
        of InstrKind.Shuffle:
          let typ = i.dest.type; let a = box(i.val); let b = box(i.val2)
          for index, selected in i.mask:
            if selected < 0 or selected >= i.val.type.width + i.val2.type.width: raise newException(ValueError,"shuffle lane out of bounds")
            let source = if selected < i.val.type.width: a else: b
            let position = if selected < i.val.type.width: selected else: selected - i.val.type.width
            store(typ.elem,load(typ.elem,offset(source,$(position * measure(typ.elem).size))),offset(slots[i.dest.name],$(index * measure(typ.elem).size)))
        of InstrKind.Select:
          let typ = i.dest.type; let mask = box(i.cond); let a = box(i.val); let b = box(i.val2)
          for index in 0..<typ.width:
            let condition = temp(); let selected = temp()
            let flag = load(i.cond.type.elem,offset(mask,$index))
            line(condition & " = icmp ne i8 " & flag & ", 0")
            let displacement = $(index * measure(typ.elem).size)
            let left = load(typ.elem,offset(a,displacement)); let right = load(typ.elem,offset(b,displacement))
            line(selected & " = select i1 " & condition & ", " & llvmType(typ.elem) & " " & left & ", " & llvmType(typ.elem) & " " & right)
            store(typ.elem,selected,offset(slots[i.dest.name],displacement))
        of InstrKind.Gather,InstrKind.Scatter:
          let typ = i.dest.type; let sourceType = i.val.type
          let source = box(i.val); let indices = box(i.val2); let output = slots[i.dest.name]
          if i.kind == InstrKind.Scatter: store(typ,value(i.val),output)
          let updates = if i.kind == InstrKind.Scatter: box(i.args[0]) else: ""
          for index in 0..<i.val2.type.width:
            let indexType = i.val2.type.elem
            let raw = load(indexType,offset(indices,$(index * measure(indexType).size)))
            let bad = temp(); line(bad & " = icmp uge " & llvmType(indexType) & " " & raw & ", " & $sourceType.width)
            guard(bad,"IndexOutOfBounds",i)
            var selected = raw
            if storageWidth(indexType) > 64:
              selected = temp(); line(selected & " = trunc " & llvmType(indexType) & " " & raw & " to i64")
            else: selected = castInteger(raw,indexType,node.Type(kind:indexType.kind,width:64))
            let displacement = temp(); line(displacement & " = mul i64 " & selected & ", " & $measure(sourceType.elem).size)
            let pointer = offset((if i.kind == InstrKind.Scatter: output else: source),displacement)
            let laneOffset = $(index * measure(typ.elem).size)
            if i.kind == InstrKind.Gather: store(typ.elem,load(typ.elem,pointer),offset(output,laneOffset))
            else: store(typ.elem,load(typ.elem,offset(updates,laneOffset)),pointer)
        of InstrKind.Reduce:
          let typ = i.dest.type; let source = box(i.val)
          var accumulated = lane(i.val.type,source,0)
          let operation = if i.reduceOp.len == 0: "Add" else: i.reduceOp
          for index in 1..<i.val.type.width:
            let next = lane(i.val.type,source,index)
            let dest = bound(typ,"zeroinitializer")
            if operation in ["Add","Mul"]:
              arithmetic(Instruction(kind:(if operation == "Add":InstrKind.Add else:InstrKind.Mul),dest:dest,val:accumulated,val2:next,span:i.span))
            elif operation in ["Min","Max"]:
              let pred = bound(node.Type(kind:TypeKind.Bool),"0")
              instruction(Instruction(kind:InstrKind.Compare,dest:pred,val:accumulated,val2:next,op:(if operation == "Min":"is less than" else:"is greater than"),span:i.span))
              let condition = predicate(pred); let selected = temp()
              let a = value(accumulated); let b = value(next)
              line(selected & " = select i1 " & condition & ", " & llvmType(typ) & " " & a & ", " & llvmType(typ) & " " & b)
              save(dest,selected)
            elif operation in ["And","Or","Xor"]:
              let selected = temp(); let a = value(accumulated); let b = value(next)
              line(selected & " = " & operation.toLowerAscii() & " " & llvmType(typ) & " " & a & ", " & b); save(dest,selected)
            else: raise newException(ValueError,"unknown vector reduction " & operation)
            accumulated = dest
          save(i.dest,value(accumulated))
        of InstrKind.Not:
          let outVal = temp(); let input = value(i.val); line(outVal & " = xor i8 " & input & ", 1"); save(i.dest,outVal)
        of InstrKind.Compare:
          if i.val.type.kind == TypeKind.Vector:
            let typ = i.val.type; let a = box(i.val); let b = box(i.val2)
            for index in 0..<typ.width:
              let left = lane(typ,a,index); let right = lane(typ,b,index)
              let dest = bound(i.dest.type.elem,"0")
              instruction(Instruction(kind:InstrKind.Compare,dest:dest,val:left,val2:right,op:i.op,span:i.span))
              store(i.dest.type.elem,value(dest),offset(slots[i.dest.name],$index))
            return
          let operation = {"equals":"equals", "does not equal":"does-not-equal", "is less than":"less-than", "is at most":"less-or-equal", "is greater than":"greater-than", "is at least":"greater-or-equal"}.toTable[i.op]
          var typ = i.val.type
          if i.val2.type.kind == TypeKind.Optional: typ = i.val2.type
          let output = temp()
          if typ.kind == TypeKind.PackedStruct:
            save(i.dest,packedComparison(typ,box(i.val),box(i.val2),operation))
            return
          if aggregate(typ):
            let helper = support.comparison(typ,operation)
            declarations[helper] = "declare i8 @" & helper & "(ptr, ptr)"
            let a = stack(typ); let b = stack(typ)
            store(typ,assigned(i.val,typ),a); store(typ,assigned(i.val2,typ),b)
            line(output & " = call i8 @" & helper & "(ptr " & a & ", ptr " & b & ")")
          else:
            let predicates = if typ.kind == TypeKind.Float:
                {"equals":"oeq", "does-not-equal":"une", "less-than":"olt", "less-or-equal":"ole", "greater-than":"ogt", "greater-or-equal":"oge"}.toTable
              else:
                {"equals":"eq", "does-not-equal":"ne", "less-than":(if typ.kind == TypeKind.Int:"slt" else:"ult"), "less-or-equal":(if typ.kind == TypeKind.Int:"sle" else:"ule"), "greater-than":(if typ.kind == TypeKind.Int:"sgt" else:"ugt"), "greater-or-equal":(if typ.kind == TypeKind.Int:"sge" else:"uge")}.toTable
            if operation notin predicates: raise newException(ValueError,"unknown comparison " & i.op)
            let pred = temp(); let a = value(i.val); let b = value(i.val2)
            line(pred & " = " & (if typ.kind == TypeKind.Float: "fcmp " else: "icmp ") & predicates[operation] & " " & llvmType(typ) & " " & a & ", " & b)
            line(output & " = zext i1 " & pred & " to i8")
          save(i.dest,output)
        of InstrKind.Construct:
          let typ = i.dest.type; let address = slots[i.dest.name]; let m = measure(typ)
          store(typ,"zeroinitializer",address)
          case typ.kind
          of TypeKind.Failable,TypeKind.Optional:
            if i.op == "error": store(node.Type(kind:TypeKind.Error),value(i.args[0]),address)
            elif i.args.len > 0:
              if typ.kind == TypeKind.Optional: store(node.Type(kind:TypeKind.Bool),"1",address)
              store(typ.elem,assigned(i.args[0],typ.elem),offset(address,$m.offsets[1]))
          of TypeKind.Slice:
            let backing = stack(node.Type(kind:TypeKind.Array,elem:typ.elem,width:max(1,i.args.len)))
            for index, arg in i.args: store(typ.elem,assigned(arg,typ.elem),offset(backing,$(index * measure(typ.elem).size)))
            store(node.Type(kind:TypeKind.Ptr),backing,address); store(node.Type(kind:TypeKind.Uint,width:64),$i.args.len,offset(address,"8"))
          of TypeKind.Struct,TypeKind.ExternStruct:
            var index = 0
            for field in typ.fields.values:
              store(field,assigned(i.args[index],field),offset(address,$m.offsets[index])); inc index
          of TypeKind.TaggedUnion:
            var tag = 0
            for field in typ.variants.keys:
              if field == i.field: break
              inc tag
            store(node.Type(kind:TypeKind.Uint,width:32),$tag,address)
            if i.args.len > 0: store(typ.variants[i.field],assigned(i.args[0],typ.variants[i.field]),offset(address,$m.offsets[1]))
          of TypeKind.Array:
            for index, arg in i.args: store(typ.elem,assigned(arg,typ.elem),offset(address,$(index * measure(typ.elem).size)))
          of TypeKind.PackedStruct:
            let count = max(1,packedBits(typ)); let backing = "i" & $count
            var accumulated = "0"; var index = 0
            for field in typ.fields.values:
              let bits = max(1,packedBits(field)); let fieldTy = "i" & $bits
              var part: string
              if field.kind == TypeKind.PackedStruct:
                let p = box(i.args[index]); part = temp(); line(part & " = load " & fieldTy & ", ptr " & p & ", align 1")
              else:
                part = value(i.args[index])
                if llvmType(field) != fieldTy:
                  let narrowed = temp(); line(narrowed & " = trunc " & llvmType(field) & " " & part & " to " & fieldTy); part = narrowed
              if bits < count:
                let expanded = temp(); line(expanded & " = zext " & fieldTy & " " & part & " to " & backing); part = expanded
              if m.offsets[index] > 0:
                let shifted = temp(); line(shifted & " = shl " & backing & " " & part & ", " & $m.offsets[index]); part = shifted
              let merged = temp(); line(merged & " = or " & backing & " " & accumulated & ", " & part); accumulated = merged; inc index
            line("store " & backing & " " & accumulated & ", ptr " & address & ", align 1")
          else: raise newException(ValueError,"unsupported construction " & typ.label)
        of InstrKind.Extract:
          if i.dest.type == nil or i.dest.type.kind == TypeKind.Void: return
          let input = if i.val.type != nil: i.val else: i.ptr
          let typ = if input.type.kind == TypeKind.Ptr: input.type.elem else: input.type
          let address = if input.type.kind == TypeKind.Ptr: value(input) else: box(input)
          if typ.kind == TypeKind.PackedStruct:
            if i.op == "address": raise newException(ValueError,"an ordinary pointer cannot address a packed bit field")
            let member = typ.fields[i.field]; let bits = max(1,packedBits(member)); let count = max(1,packedBits(typ))
            let backing = "i" & $count; let memberTy = "i" & $bits
            let raw = temp(); line(raw & " = load " & backing & ", ptr " & address & ", align 1")
            let shifted = temp(); line(shifted & " = lshr " & backing & " " & raw & ", " & $measure(typ).offsets[fieldIndex(typ,i.field)])
            var part = shifted
            if bits < count:
              part = temp(); line(part & " = trunc " & backing & " " & shifted & " to " & memberTy)
            if member.kind == TypeKind.PackedStruct:
              store(member,"zeroinitializer",slots[i.dest.name]); line("store " & memberTy & " " & part & ", ptr " & slots[i.dest.name] & ", align 1")
            elif llvmType(member) == memberTy: save(i.dest,part)
            else:
              let expanded = temp(); line(expanded & " = " & (if member.kind == TypeKind.Int: "sext" else:"zext") & " " & memberTy & " " & part & " to " & llvmType(member)); save(i.dest,expanded)
            return
          var displacement = 0
          if typ.kind in {TypeKind.Optional,TypeKind.Failable}:
            if i.field == "failed":
              let err = load(node.Type(kind:TypeKind.Error),address); let pred = temp(); let output = temp()
              line(pred & " = icmp ne ptr " & err & ", null"); line(output & " = zext i1 " & pred & " to i8"); save(i.dest,output); return
            if i.field notin ["error","present"]: displacement = measure(typ).offsets[1]
          elif typ.kind == TypeKind.TaggedUnion:
            if i.field != "tag": displacement = measure(typ).offsets[1]
          else: displacement = measure(typ).offsets[fieldIndex(typ,i.field)]
          let projected = offset(address,$displacement)
          save(i.dest,if i.op == "address": projected else: load(i.dest.type,projected))
        of InstrKind.Length:
          if i.val.type.kind == TypeKind.Slice: save(i.dest,load(i.dest.type,offset(box(i.val),"8")))
          else: save(i.dest,$i.val.type.width)
        of InstrKind.Index:
          let typ = i.val.type; let address = box(i.val)
          let data = if typ.kind == TypeKind.Slice: load(node.Type(kind:TypeKind.Ptr),address) elif typ.kind == TypeKind.Ptr: value(i.val) else: address
          let index = castInteger(value(i.val2),i.val2.type,node.Type(kind:i.val2.type.kind,width:64))
          if typ.kind != TypeKind.Ptr:
            let count = if typ.kind == TypeKind.Slice: load(node.Type(kind:TypeKind.Uint,width:64),offset(address,"8")) else: $typ.width
            let bad = temp(); line(bad & " = icmp uge i64 " & index & ", " & count); guard(bad,"IndexOutOfBounds",i)
          let displacement = temp(); line(displacement & " = mul i64 " & index & ", " & $measure(typ.elem).size)
          let projected = offset(data,displacement)
          save(i.dest,if i.op == "address": projected else: load(i.dest.type,projected))
        of InstrKind.Reflect:
          let typ = i.typeArg; let address = slots[i.dest.name]; let bare = node.Type(kind:typ.kind,elem:typ.elem,width:typ.width)
          for name, field in i.dest.type.fields:
            var data: string
            if name in ["size","alignment"]: data = $(if name == "size": measure(typ).size else: measure(typ).alignment)
            else:
              let label = if name == "name": typ.label else: bare.label
              data = value(Value(kind:ValueKind.Const,type:field,name:quoted(label.toOpenArrayByte(0,label.high))))
            store(field,data,offset(address,$measure(i.dest.type).offsets[fieldIndex(i.dest.type,name)]))
        of InstrKind.Embed:
          let data = readFile(parentDir(sourceFile)/i.path)
          save(i.dest,value(Value(kind:ValueKind.Const,type:i.dest.type,name:quoted(data.toOpenArrayByte(0,data.high)))))
        of InstrKind.Trace: trace(i)
        of InstrKind.Defer:
          for item in cleanups:
            if item.instruction == i: store(node.Type(kind:TypeKind.Bool),"1",item.flag)
        of InstrKind.Try,InstrKind.Catch:
          let v = if i.kind == InstrKind.Try: i.expr else: i.val
          let address = box(v); let error = load(node.Type(kind:TypeKind.Error),address)
          let failed = temp(); line(failed & " = icmp ne ptr " & error & ", null")
          let bad = blockLabel("issue.fail."); let good = blockLabel("issue.pass."); let done = blockLabel("issue.merge.")
          line("br i1 " & failed & ", label %" & quotedName(bad) & ", label %" & quotedName(good)); start(bad)
          if i.kind == InstrKind.Try:
            trace(i)
            if fn.name == "main" and fn.ret.kind == TypeKind.Void:
              cleanup("true"); line("call void @foo_llvm_entry_error(ptr " & error & ")"); line("unreachable")
            else:
              if fn.ret.kind != TypeKind.Failable: raise newException(ValueError,"try requires failable function result")
              let returnedError = stack(fn.ret); store(fn.ret,"zeroinitializer",returnedError); store(node.Type(kind:TypeKind.Error),error,returnedError)
              cleanup("true"); let output = load(fn.ret,returnedError); line("ret " & llvmType(fn.ret) & " " & output)
          else:
            for child in i.fallback.instrs: instruction(child)
            save(i.dest,assigned(i.fallback.term.value,i.dest.type)); branch(done)
          start(good)
          if i.dest.type != nil and i.dest.type.kind != TypeKind.Void: save(i.dest,load(i.dest.type,offset(address,$measure(v.type).offsets[1])))
          branch(done); start(done)
        of InstrKind.Jump: transfer(i.label,i.args)
        of InstrKind.Cjump:
          let a = blockLabel("edge.true."); let b = blockLabel("edge.false."); let origin = current; let cond = predicate(i.cond)
          line("br i1 " & cond & ", label %" & quotedName(a) & ", label %" & quotedName(b))
          start(a); current = origin; transfer(i.trueLabel,i.trueArgs)
          start(b); current = origin; transfer(i.falseLabel,i.falseArgs)
        of InstrKind.Return: returned(i.value)
        of InstrKind.Panic: panic(i.msg,i)
        of InstrKind.Phi: discard
        else: raise newException(ValueError,"unsupported instruction " & $i.kind)
      except ValueError as error:
        raise newException(ValueError,i.span.file & ":" & $i.span.start & " (source offset), " & fn.name & ": LLVM " & error.msg)
    var params: seq[string]
    for index, p in fn.params:
      if p.type.kind == TypeKind.Void: continue
      params.add(llvmType(p.type) & " %arg" & $index)
      initializers.add("  store " & llvmType(p.type) & " %arg" & $index & ", ptr " & slots[p.name] & ", align 1")
    if "interrupt" in fn.attributes: params.insert("ptr byval([5 x i64]) align 8 %interrupt_frame",0)
    for b in fn.blocks:
      predecessor = b.label
      start(b.label)
      for i in b.instrs: instruction(i)
      instruction(b.term)
    definitions.add("define " & (if "interrupt" in fn.attributes: "x86_intrcc " else: "") & llvmType(fn.ret) & " " & functionName(fn.name) & "(" & params.join(", ") & ") noinline" & (if pureFunction(fn) and not code.anyIt(it.contains("call ")): (if modernMemory: " memory(none)" else: " readnone") else: "") & (if "interrupt" in fn.attributes: " \"target-features\"=\"-sse,-sse2,-mmx\"" else: featureClause) & " {\nfoo.prologue:\n" &
      allocas.join("\n") & "\n" & initializers.join("\n") & "\n  br label %" & quotedName(fn.blocks[0].label) & "\n" & code.join("\n") & "\n}")
    if "interrupt" in fn.attributes: continue
    var gateParams = @["ptr %out"]
    var gateBody, gateArgs: seq[string]
    for index, p in fn.params:
      gateParams.add("ptr %p" & $index)
      if p.type.kind == TypeKind.Void: continue
      let argument = "%a" & $index
      gateBody.add("  " & argument & " = load " & llvmType(p.type) & ", ptr %p" & $index & ", align 1")
      gateArgs.add(llvmType(p.type) & " " & argument)
    gateBody.add("  " & (if fn.ret.kind == TypeKind.Void: "" else: "%result = ") & "call " & llvmType(fn.ret) & " " & functionName(fn.name) & "(" & gateArgs.join(", ") & ")")
    if fn.ret.kind != TypeKind.Void: gateBody.add("  store " & llvmType(fn.ret) & " %result, ptr %out, align 1")
    gateBody.add("  ret void")
    definitions.add("define void @" & gateName(fn.name) & "(" & gateParams.join(", ") & ") {\n" & gateBody.join("\n") & "\n}")
  var entrypoint: string
  if "main" notin functions and not startup: raise newException(ValueError,"LLVM executable requires an entry point")
  if "main" in functions:
    let entry = functions["main"]
    if entry.params.len > 0: raise newException(ValueError,"entry point must be parameterless")
    entrypoint = "define i32 @main(i32 %argc, ptr %argv) {\nentry:\n" & (if hosted: "  call void @foo_llvm_init(i32 %argc, ptr %argv)\n" else: "")
    if entry.ret.kind == TypeKind.Void: entrypoint.add("  call void " & functionName("main") & "()\n")
    elif entry.ret.kind == TypeKind.Failable:
      entrypoint.add("  %result = call " & llvmType(entry.ret) & " " & functionName("main") & "()\n  %cell = alloca " & llvmType(entry.ret) & ", align " & $measure(entry.ret).alignment &
        "\n  store " & llvmType(entry.ret) & " %result, ptr %cell, align 1\n  %error = load ptr, ptr %cell, align 1\n  %failed = icmp ne ptr %error, null\n  br i1 %failed, label %failure, label %success\nfailure:\n  call void @foo_llvm_entry_error(ptr %error)\n  unreachable\nsuccess:\n")
    else: entrypoint.add("  %ignored = call " & llvmType(entry.ret) & " " & functionName("main") & "()\n")
    var exitValue = "0"
    if not hosted and entry.ret.kind in {TypeKind.Int, TypeKind.Uint}:
      if storageWidth(entry.ret) == 32: exitValue = "%ignored"
      else:
        entrypoint.add("  %exit = " & (if storageWidth(entry.ret) > 32: "trunc" else: "zext") & " " & llvmType(entry.ret) & " %ignored to i32\n")
        exitValue = "%exit"
    entrypoint.add((if hosted: "  call void @foo_llvm_finish()\n" else: "") & "  ret i32 " & exitValue & "\n}\n")
  result = "; FOO LLVM backend: core typed IR\ntarget triple = " & escape(triple) & "\ntarget datalayout = " & escape(dataLayout) & "\n" & globals.join("\n") &
    "\ndeclare void @foo_llvm_entry_error(ptr)\ndeclare ptr @foo_llvm_alloc(ptr, i64, i64)\ndeclare void @foo_llvm_free(ptr)\ndeclare ptr @foo_llvm_reserve(ptr, i64)\ndeclare void @foo_llvm_close(ptr)\ndeclare void @foo_llvm_panic(ptr)\ndeclare void @foo_llvm_trace(ptr, ptr, i64)\ndeclare void @foo_llvm_init(i32, ptr)\ndeclare void @foo_llvm_finish()\ndeclare void @foo_llvm_join(ptr, ptr, ptr)\n" &
    toSeq(declarations.values).join("\n") & "\n" & definitions.join("\n") & "\n" & entrypoint

proc emit*(module: Module; triple, dataLayout: string): string =
  emit(module,triple,dataLayout,newSupport())

proc emit*(module: Module; triple, dataLayout, sourceFile: string; hosted = true; cpu = ""): string =
  emit(module,triple,dataLayout,newSupport(),sourceFile,hosted,cpu)
