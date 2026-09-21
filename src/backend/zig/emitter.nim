import std/[json, sequtils, sets, strutils, tables]
import ../../ir/[kind, monomorph, node]
import ../native/service

type
  EmitResult* = object
    code*: string
    map*: Table[int, int]
  EmitOptions* = object
    library*: bool
    coverage*: string
    runtime*: string
    target*: string

proc quote(value: string): string = $(%value)

proc typeStr*(value: `Type`): string =
  if value == nil: return "void"
  if value.name.len > 0 and value.kind in {TypeKind.Struct, TypeKind.TaggedUnion,
      TypeKind.PackedStruct, TypeKind.ExternStruct, TypeKind.ExternUnion,
      TypeKind.Opaque}: return value.name
  case value.kind
  of TypeKind.Int: "i" & $(if value.width > 0: value.width else: 32)
  of TypeKind.Uint: "u" & $(if value.width > 0: value.width else: 32)
  of TypeKind.Float: "f" & $(if value.width > 0: value.width else: 64)
  of TypeKind.Bool: "bool"
  of TypeKind.Ptr: "*" & (if value.volatile: "volatile " else: "") & typeStr(value.elem)
  of TypeKind.Slice: "[]" & (if value.constant: "const " else: "") & typeStr(value.elem)
  of TypeKind.Optional: "?" & typeStr(value.elem)
  of TypeKind.Fallible: "anyerror!" & typeStr(value.elem)
  of TypeKind.Array: "[" & $value.width & "]" & typeStr(value.elem)
  of TypeKind.Struct: (if value.name.len > 0: value.name else: "struct")
  of TypeKind.Void: "void"
  of TypeKind.Error: "anyerror"
  of TypeKind.Vector: "@Vector(" & $value.width & ", " & typeStr(value.elem) & ")"
  of TypeKind.TaggedUnion: "union(enum)"
  of TypeKind.PackedStruct: "packed struct"
  of TypeKind.ExternUnion: "extern union"
  of TypeKind.Opaque: "opaque {}"
  of TypeKind.Function:
    var params: seq[string]
    for parameter in value.params: params.add(typeStr(parameter))
    let convention = if value.abi.len > 0 and not value.abi.startsWith("runtime"):
      " callconv(." & value.abi & ")" else: ""
    "*const fn (" & params.join(", ") & ")" & convention & " " & typeStr(value.ret)
  of TypeKind.ExternStruct: "extern struct"
  else: "void"

proc packedBitWidth*(value: `Type`): int =
  if value == nil: return 0
  case value.kind
  of TypeKind.Bool: return 1
  of TypeKind.Int, TypeKind.Uint: return (if value.width > 0: value.width else: 32)
  of TypeKind.PackedStruct:
    if value.width > 0: return value.width
    else:
      for field in value.fields.values: result += packedBitWidth(field)
  else: return 0

proc valueStr*(value: Value): string =
  case value.kind
  of ValueKind.Reg: "v_" & value.name
  of ValueKind.Const:
    if value.type != nil and value.type.kind == TypeKind.Error: "error." & value.name
    elif value.type != nil and value.type.kind == TypeKind.Float and value.bits.len > 0:
      "@as(" & typeStr(value.type) & ", @bitCast(@as(u" &
        $(if value.type.width > 0: value.type.width else: 64) & ", 0x" & value.bits & ")))"
    else: value.name
  of ValueKind.Global: "(&" & value.name & ")"

proc functionConvention*(function: Function; target = ""): string =
  if "naked" in function.attributes: return ".naked"
  if "interrupt" notin function.attributes:
    return if function.abi.len > 0: "." & function.abi else: ""
  if target.startsWith("x86_64"): ".{ .x86_64_interrupt = .{} }"
  elif target.startsWith("riscv64"): ".{ .riscv64_interrupt = .{ .mode = .machine } }"
  elif target.startsWith("riscv32"): ".{ .riscv32_interrupt = .{ .mode = .machine } }"
  elif target.startsWith("arm") or target.startsWith("thumb"): ".{ .arm_interrupt = .{} }"
  else: ".c"

proc emitTypeDecl*(declaration: TypeDecl): seq[string] =
  let value = declaration.type
  if value.kind == TypeKind.Opaque:
    return @["pub const " & declaration.name & " = opaque {};"]
  if value.kind == TypeKind.TaggedUnion:
    result.add("pub const " & declaration.name & " = union(enum) {")
    for fieldName, payload in value.variants:
      result.add("  " & fieldName & ": " & (if payload == nil: "void" else: typeStr(payload)) & ",")
    result.add("};")
    return
  if value.kind notin {TypeKind.Struct, TypeKind.PackedStruct,
      TypeKind.ExternStruct, TypeKind.ExternUnion}:
    return @["pub const " & declaration.name & " = " & typeStr(value) & ";"]
  var keyword = "struct"
  if value.kind == TypeKind.PackedStruct:
    let width = if value.width > 0: value.width else: packedBitWidth(value)
    keyword = "packed struct" & (if width > 0: "(u" & $width & ")" else: "")
  elif value.kind == TypeKind.ExternUnion: keyword = "extern union"
  elif value.kind == TypeKind.ExternStruct: keyword = "extern struct"
  result.add("pub const " & declaration.name & " = " & keyword & " {")
  for fieldName, field in value.fields: result.add("  " & fieldName & ": " & typeStr(field) & ",")
  result.add("};")

proc usedRegisters*(function: Function): HashSet[string] =
  var pending = function.blocks
  while pending.len > 0:
    let basicBlock = pending[0]
    pending.delete(0)
    for instruction in basicBlock.instrs & @[basicBlock.term]:
      if instruction == nil: continue
      if instruction.fallback != nil: pending.add(instruction.fallback)
      for value in [instruction.target, instruction.ptr, instruction.val,
          instruction.val2, instruction.cond, instruction.value,
          instruction.expr, instruction.callee]:
        if value.kind == ValueKind.Reg: result.incl(value.name)
      for value in instruction.args:
        if value.kind == ValueKind.Reg: result.incl(value.name)
      for edge in instruction.blocks:
        if edge.value.kind == ValueKind.Reg: result.incl(edge.value.name)

proc region(id: string): string = "@" & quote("arena_" & id)

proc emitInstr(instruction: Instruction; used: HashSet[string]): string

proc emitInstr(instruction: Instruction; used: HashSet[string]): string =
  if instruction == nil: return ""
  let hasDest = instruction.dest.type != nil
  let destination = if hasDest: "const " & valueStr(instruction.dest) & " = " else: ""
  let discardResult = if hasDest and instruction.dest.name notin used:
    " _ = " & valueStr(instruction.dest) & ";" else: ""
  template finish(value: string): string = value & discardResult
  case instruction.kind
  of InstrKind.Region:
    if instruction.op == "open":
      region(instruction.region) & " = @import(\"std\").heap.ArenaAllocator.init(@import(\"std\").heap.page_allocator);"
    else: region(instruction.region) & ".deinit();"
  of InstrKind.Allocate:
    if instruction.target.type != nil:
      finish(destination & "shim.managed(" & valueStr(instruction.target) & ", " & valueStr(instruction.val) & ");")
    else:
      finish(destination & "shim.reserve(" & region(instruction.region) & ".allocator(), " & valueStr(instruction.val) & ");")
  of InstrKind.Alloc:
    if instruction.op == "slot": finish(destination & "&cell_" & instruction.dest.name & ";")
    else: finish(destination & "shim.allocScope(" & typeStr(instruction.dest.type.elem) & ") catch shim.panic(\"out of memory\");")
  of InstrKind.Remainder: finish(destination & "@rem(" & valueStr(instruction.val) & ", " & valueStr(instruction.val2) & ");")
  of InstrKind.Not: finish(destination & "!" & valueStr(instruction.val) & ";")
  of InstrKind.Convert:
    let value = valueStr(instruction.val)
    let converted = if instruction.dest.type.kind == TypeKind.Float and
        instruction.val.type.kind in {TypeKind.Int, TypeKind.Uint}:
      "@floatFromInt(" & value & ")" else: value
    finish(destination & "@as(" & typeStr(instruction.dest.type) & ", " & converted & ");")
  of InstrKind.Compare:
    let operators = {"equals": "==", "does not equal": "!=", "is less than": "<",
      "is greater than": ">", "is at least": ">=", "is at most": "<="}.toTable
    if not operators.hasKey(instruction.op): raise newException(ValueError, "Unknown comparison")
    let operation = operators[instruction.op]
    let composite = instruction.val.type.kind in {TypeKind.Bool, TypeKind.Struct,
      TypeKind.PackedStruct, TypeKind.ExternStruct, TypeKind.TaggedUnion,
      TypeKind.Optional, TypeKind.Slice}
    if operation notin ["==", "!="] and composite:
      let relations = {"<": "== .lt", ">": "== .gt", "<=": "!= .gt", ">=": "!= .lt"}.toTable
      return finish(destination & "shim.library.order(" & valueStr(instruction.val) & ", " &
        valueStr(instruction.val2) & ") " & relations[operation] & ";")
    if operation in ["==", "!="] and composite:
      return finish(destination & (if operation == "!=": "!" else: "") &
        "shim.library.equal(" & valueStr(instruction.val) & ", " & valueStr(instruction.val2) & ");")
    finish(destination & valueStr(instruction.val) & " " & operation & " " & valueStr(instruction.val2) & ";")
  of InstrKind.Length:
    finish(destination & "@as(" & typeStr(instruction.dest.type) & ", @intCast(" & valueStr(instruction.val) & ".len));")
  of InstrKind.Index:
    finish(destination & (if instruction.op == "address": "&" else: "") & valueStr(instruction.val) &
      "[@intCast(" & valueStr(instruction.val2) & ")];")
  of InstrKind.Construct:
    let target = instruction.dest.type
    if target.kind == TypeKind.Fallible and instruction.op == "error":
      return finish(destination & "@as(" & typeStr(target) & ", " & valueStr(instruction.args[0]) & ");")
    var fields: seq[string]
    if target.kind == TypeKind.TaggedUnion:
      fields.add("." & instruction.field & " = " &
        (if instruction.args.len > 0: valueStr(instruction.args[0]) else: "{}"))
    else:
      var index = 0
      for name in target.fields.keys:
        fields.add("." & name & " = " & (if index < instruction.args.len: valueStr(instruction.args[index]) else: "{}"))
        inc index
    finish(destination & typeStr(target) & "{ " & fields.join(", ") & " };")
  of InstrKind.Extract:
    if instruction.val.type.kind == TypeKind.Fallible:
      if instruction.field == "failed": return finish(destination & "if (" & valueStr(instruction.val) & ") |_| false else |_| true;")
      if instruction.field == "value": return finish(destination & valueStr(instruction.val) & " catch unreachable;")
    if instruction.val.type.kind == TypeKind.TaggedUnion and instruction.field == "tag":
      return finish(destination & "@as(u32, @intCast(@intFromEnum(" & valueStr(instruction.val) & ")));")
    finish(destination & (if instruction.op == "address": "&" else: "") & valueStr(instruction.val) & "." & instruction.field & ";")
  of InstrKind.Load: finish(destination & valueStr(instruction.ptr) & ".*;")
  of InstrKind.Store: valueStr(instruction.ptr) & ".* = " & valueStr(instruction.val) & ";"
  of InstrKind.Add:
    if instruction.dest.type.kind == TypeKind.Slice and instruction.dest.type.constant and
        instruction.dest.type.elem != nil and instruction.dest.type.elem.width == 8:
      finish(destination & "shim.library.join(" & valueStr(instruction.val) & ", " & valueStr(instruction.val2) & ");")
    else: finish(destination & valueStr(instruction.val) & " + " & valueStr(instruction.val2) & ";")
  of InstrKind.Sub: finish(destination & valueStr(instruction.val) & " - " & valueStr(instruction.val2) & ";")
  of InstrKind.Mul: finish(destination & valueStr(instruction.val) & " * " & valueStr(instruction.val2) & ";")
  of InstrKind.Div:
    if instruction.val.type.kind == TypeKind.Int:
      finish(destination & "@divTrunc(" & valueStr(instruction.val) & ", " & valueStr(instruction.val2) & ");")
    else: finish(destination & valueStr(instruction.val) & " / " & valueStr(instruction.val2) & ";")
  of InstrKind.Call, InstrKind.Thread:
    var arguments: seq[string]
    for argument in instruction.args: arguments.add(valueStr(argument))
    if instruction.callee.type == nil and instruction.abi.startsWith("runtime."):
      let provider = instruction.abi[8 .. ^1]
      if provider.anyIt(not it.isLowerAscii): raise newException(ValueError, "Invalid runtime module")
      finish(destination & "shim.library.call(" & quote(provider) & ", " &
        quote(if instruction.symbol.len > 0: instruction.symbol else: instruction.func) & ", " &
        (if hasDest: typeStr(instruction.dest.type) else: "void") & ", .{" & arguments.join(", ") & "});")
    else:
      let callee = if instruction.callee.type != nil: valueStr(instruction.callee)
        elif instruction.abi == "runtime": "shim." & (if instruction.symbol.len > 0: instruction.symbol else: instruction.func)
        else: instruction.func
      finish(destination & callee & "(" & arguments.join(", ") & ");")
  of InstrKind.Catch:
    let fallback = instruction.fallback
    var body: seq[string]
    for child in fallback.instrs: body.add(emitInstr(child, used))
    finish(destination & valueStr(instruction.val) & " catch " & fallback.label & ": {\n" &
      body.join("\n") & "\nbreak :" & fallback.label & " " & valueStr(fallback.term.value) & ";\n};")
  of InstrKind.Defer:
    var body: seq[string]
    for child in instruction.fallback.instrs: body.add(emitInstr(child, used))
    (if instruction.error: "errdefer" else: "defer") & " {\n" & body.join("\n") & "\n}"
  of InstrKind.Jump: "// jump " & instruction.label
  of InstrKind.Cjump: "if (" & valueStr(instruction.cond) & ") { /* " & instruction.trueLabel & " */ } else { /* " & instruction.falseLabel & " */ }"
  of InstrKind.Return: (if instruction.value.type != nil: "return " & valueStr(instruction.value) & ";" else: "return;")
  of InstrKind.Panic: "shim.panic(" & quote(instruction.msg) & ");"
  of InstrKind.Try: finish((if hasDest: destination else: "_ = ") & "try " & valueStr(instruction.expr) & ";")
  of InstrKind.Phi: "// phi"
  of InstrKind.Eval: "comptime { " & instruction.evalBody & " }"
  of InstrKind.Reflect:
    finish(destination & typeStr(instruction.dest.type) & "{ .name = " & quote(label(instruction.typeArg)) &
      ", .kind = " & quote(label(instruction.typeArg)) & ", .size = @sizeOf(" & typeStr(instruction.typeArg) &
      "), .alignment = @alignOf(" & typeStr(instruction.typeArg) & ") };")
  of InstrKind.Embed: finish(destination & "@embedFile(" & quote(instruction.path) & ");")
  of InstrKind.Splat: finish(destination & "@as(" & typeStr(instruction.dest.type) & ", @splat(" & valueStr(instruction.val) & "));")
  of InstrKind.Shuffle:
    var mask: seq[string]
    let lanes = instruction.val.type.width
    for lane in instruction.mask: mask.add($(if lane >= lanes: not (lane - lanes) else: lane))
    finish(destination & "@shuffle(" & typeStr(instruction.dest.type.elem) & ", " & valueStr(instruction.val) &
      ", " & valueStr(instruction.val2) & ", @Vector(" & $instruction.mask.len & ", i32){ " & mask.join(", ") & " });")
  of InstrKind.Select: finish(destination & "@select(" & typeStr(instruction.dest.type.elem) & ", " & valueStr(instruction.cond) & ", " & valueStr(instruction.val) & ", " & valueStr(instruction.val2) & ");")
  of InstrKind.Reduce: finish(destination & "@reduce(." & (if instruction.reduceOp.len > 0: instruction.reduceOp else: "Add") & ", " & valueStr(instruction.val) & ");")
  of InstrKind.NativeZig: instruction.code
  of InstrKind.Trace: "shim.trace(" & quote(instruction.trace) & ", " & quote(instruction.span.file) & ", " & $instruction.span.start & ");"
  of InstrKind.Atomic:
    let order = if instruction.field == "relaxed": "monotonic" else: instruction.field
    if instruction.op == "fence": "@fence(." & order & ");"
    elif instruction.op == "load": finish(destination & "@atomicLoad(" & typeStr(instruction.ptr.type.elem) & ", " & valueStr(instruction.ptr) & ", ." & order & ");")
    elif instruction.op == "store": "@atomicStore(" & typeStr(instruction.ptr.type.elem) & ", " & valueStr(instruction.ptr) & ", " & valueStr(instruction.val) & ", ." & order & ");"
    else: finish(destination & "@atomicRmw(" & typeStr(instruction.ptr.type.elem) & ", " & valueStr(instruction.ptr) &
      ", ." & (if instruction.op == "add": "Add" else: "Xchg") & ", " & valueStr(instruction.val) & ", ." & order & ");")
  else: raise newException(ValueError, "Zig backend does not support IR " & $instruction.kind)

proc control(function: Function; used: HashSet[string]): seq[string] =
  var labels = initTable[string, int]()
  for index, basicBlock in function.blocks: labels[basicBlock.label] = index
  var registers = initOrderedTable[string, Value]()
  for basicBlock in function.blocks:
    for instruction in basicBlock.instrs:
      if instruction.fallback != nil:
        raise newException(ValueError, "Cleanup and catch inside multi-block IR are not supported by the Zig backend yet")
      if instruction.dest.type != nil: registers[instruction.dest.name] = instruction.dest
  for value in registers.values:
    result.add("  var " & valueStr(value) & ": " & typeStr(value.type) & " = undefined;")
  var assigned = used
  for name in registers.keys: assigned.incl(name)
  result.add(@["  var pc: usize = 0;", "  flow: while (true) {", "    switch (pc) {"])
  for index, basicBlock in function.blocks:
    proc edge(target: string): string =
      if not labels.hasKey(target): raise newException(ValueError, "Unknown IR block '" & target & "'")
      var before, after: seq[string]
      var serial = 0
      for phi in function.blocks[labels[target]].instrs:
        if phi.kind != InstrKind.Phi: continue
        var found = false
        var source: Value
        for incoming in phi.blocks:
          if incoming.label == basicBlock.label: source = incoming.value; found = true
        if not found: raise newException(ValueError, "Phi has no edge from '" & basicBlock.label & "'")
        before.add("const incoming_" & $serial & ": " & typeStr(phi.dest.type) & " = " & valueStr(source) & ";")
        after.add(valueStr(phi.dest) & " = incoming_" & $serial & ";")
        inc serial
      before.join(" ") & " " & after.join(" ") & " pc = " & $labels[target] & "; continue :flow;"
    result.add("      " & $index & " => {")
    for instruction in basicBlock.instrs & @[basicBlock.term]:
      if instruction.kind == InstrKind.Phi: continue
      if instruction.kind == InstrKind.Jump: result.add(edge(instruction.label))
      elif instruction.kind == InstrKind.Cjump:
        result.add("if (" & valueStr(instruction.cond) & ") { " & edge(instruction.trueLabel) &
          " } else { " & edge(instruction.falseLabel) & " }")
      else:
        let emitted = emitInstr(instruction, assigned)
        result.add(if emitted.startsWith("const "): emitted[6 .. ^1] else: emitted)
    result.add("      },")
  result.add(@["      else => unreachable,", "    }", "  }"])

proc emit*(input: Module; mode: string; options = EmitOptions()): EmitResult =
  let module = prepare(input)
  if module.native.len > 0:
    raise newException(ValueError, "Native residues need a verified substrate binding before emission")
  var code = "// FOO IR v1 -> Zig\nconst shim = @import(\"shim.zig\");\n\n"
  if options.coverage.len > 0:
    if options.runtime == "none":
      raise newException(ValueError, "Coverage requires the hosted runtime")
    code.add("var coverage = [_]@import(\"std\").atomic.Value(u64){.init(0)} ** " &
      $module.funcs.len & ";\n")
    code.add("fn report() void {\n  var counts: [" & $module.funcs.len &
      "]u64 = undefined;\n  for (&coverage, 0..) |*counter, index| counts[index] = counter.load(.monotonic);\n")
    var names, lines: seq[string]
    for function in module.funcs:
      names.add(quote(function.name))
      lines.add($function.line)
    code.add("  shim.library.report(" &
      quote(options.coverage.replace("\\", "/")) & ", &.{" &
      names.join(",") & "}, &.{" & lines.join(",") &
      "}, &counts) catch |err| @import(\"std\").log.err(\"Could not write coverage: {s}\", .{@errorName(err)});\n}\n")
  var mappings = initTable[int, int]()
  var generatedLine = code.count('\n') + 1
  template addLine(sourceLine: int; value: string) =
    if sourceLine > 0 and not mappings.hasKey(sourceLine): mappings[sourceLine] = generatedLine
    code.add(value & "\n")
    generatedLine += value.count('\n') + 1
  for item in module.storage:
    addLine(0, (if item.public: "pub " else: "") & "var " & item.name & ": " & typeStr(item.value.type) & " = " & valueStr(item.value) & ";")
  for declaration in module.types:
    for line in emitTypeDecl(declaration): addLine(0, line)
    addLine(0, "")
  var externSymbols = initTable[string, string]()
  for external in module.externs:
    if external.abi == "runtime": continue
    if external.abi.startsWith("runtime."):
      var params, args: seq[string]
      for index, typ in external.params:
        params.add("p" & $index & ": " & typeStr(typ)); args.add("p" & $index)
      addLine(0, "fn " & external.name & "(" & params.join(", ") & ") " & typeStr(external.ret) &
        " { return shim.library.call(" & quote(external.abi[8 .. ^1]) & ", " &
        quote(if external.symbol.len > 0: external.symbol else: external.name) & ", " & typeStr(external.ret) &
        ", .{" & args.join(", ") & "}); }")
      continue
    var params: seq[string]
    for typ in external.params: params.add(typeStr(typ))
    let symbol = if external.symbol.len > 0: external.symbol else: external.name
    let signature = external.abi & "(" & params.join(", ") & ") " & typeStr(external.ret)
    if externSymbols.hasKey(symbol) and externSymbols[symbol] != signature:
      raise newException(ValueError, "Conflicting declarations for external function '" & symbol & "'")
    if not externSymbols.hasKey(symbol):
      addLine(0, "extern " & (if external.abi == "c": "" else: quote(external.abi) & " ") &
        "fn " & symbol & "(" & params.join(", ") & ") " & typeStr(external.ret) & ";")
    externSymbols[symbol] = signature
    if symbol != external.name: addLine(0, "const " & external.name & " = " & symbol & ";")
  if module.externs.len > 0: addLine(0, "")
  for functionIndex, function in module.funcs:
    let used = usedRegisters(function)
    var params: seq[string]
    if function.name == "main" and hosted(module): params.add("process: @import(\"std\").process.Init")
    else:
      for parameter in function.params: params.add(valueStr(parameter) & ": " & typeStr(parameter.type))
    let qualifier = if function.abi == "c" or (options.library and function.public) or
        "start" in function.attributes or "interrupt" in function.attributes: "export" else: "pub"
    let convention = functionConvention(function, options.target)
    let callconv = if convention.len > 0: " callconv(" & convention & ")" else: ""
    let functionName = if "start" in function.attributes: "_start" else: function.name
    let returnType = if function.name == "main" and options.runtime != "none": "anyerror!void" else: typeStr(function.ret)
    addLine(function.line, qualifier & " fn " & functionName & "(" & params.join(", ") & ")" & callconv & " " & returnType & " {")
    for attribute in function.attributes:
      if attribute.startsWith("target_feature(\"") and attribute.endsWith("\")"):
        let feature = attribute[16 ..< attribute.len - 2]
        if feature.len > 0 and feature[0].isLowerAscii and
            feature.allIt(it.isLowerAscii or it.isDigit or it == '_'):
          addLine(function.line,
            "  comptime { const std = @import(\"std\"); const cpu = @import(\"builtin\").target.cpu; const architecture = switch (cpu.arch) { .x86_64 => std.Target.x86, .aarch64 => std.Target.aarch64, else => @compileError(\"CPU features require x86_64 or aarch64\") }; if (!architecture.featureSetHas(cpu.features, std.meta.stringToEnum(architecture.Feature, \"" &
            feature & "\") orelse @compileError(\"Unknown CPU feature: " & feature &
            "\"))) @compileError(\"Enable CPU feature " & feature & " in build.cpu\"); }")
    if options.coverage.len > 0 and "naked" notin function.attributes:
      addLine(function.line, "  _ = coverage[" & $functionIndex & "].fetchAdd(1, .monotonic);")
    if function.name == "main" and options.runtime != "none":
      addLine(0, "  shim.init(" & $(mode == "dev") & ");")
      addLine(0, "  defer shim.deinit();")
      if hosted(module):
        addLine(0, "  try @import(\"service.zig\").init(process.minimal.args);")
        addLine(0, "  defer @import(\"service.zig\").deinit();")
      if options.coverage.len > 0: addLine(0, "  defer report();")
    var pending = function.blocks
    var arenas = initHashSet[string]()
    while pending.len > 0:
      let basicBlock = pending[0]; pending.delete(0)
      for instruction in basicBlock.instrs:
        if instruction.fallback != nil: pending.add(instruction.fallback)
        if instruction.kind == InstrKind.Alloc and instruction.op == "slot":
          addLine(0, "  var cell_" & instruction.dest.name & ": " & typeStr(instruction.dest.type.elem) & " = undefined;")
        if instruction.kind == InstrKind.Region and instruction.region notin arenas:
          arenas.incl(instruction.region)
          addLine(0, "  var " & region(instruction.region) & ": @import(\"std\").heap.ArenaAllocator = undefined;")
    if function.blocks.len > 1:
      for line in control(function, used): addLine(0, line)
    else:
      for basicBlock in function.blocks:
        addLine(0, "  // block " & basicBlock.label)
        for instruction in basicBlock.instrs: addLine(0, "  " & emitInstr(instruction, used))
        if "naked" notin function.attributes or basicBlock.term.kind != InstrKind.Return:
          addLine(0, "  " & emitInstr(basicBlock.term, used))
    addLine(0, "}")
    if "Equatable" in function.derives:
      addLine(0, "pub fn eql(self: " & function.name & ", other: " &
        function.name & ") bool {")
      addLine(0, "  return shim.eql(self, other);")
      addLine(0, "}")
    if "Hash" in function.derives:
      addLine(0, "pub fn hash(self: " & function.name & ") u64 {")
      addLine(0, "  return shim.hash(self);")
      addLine(0, "}")
    addLine(0, "")
  result = EmitResult(code: code, map: mappings)
