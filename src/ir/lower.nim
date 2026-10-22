import std/[json, sequtils, sets, strutils, tables, unicode]
import ../ast/node as ast
import ../types/type as semantic
import ../opt/gpu as graphics
import ./[kind, node, valid, eval]

type Type = node.Type

proc lower(node: ast.`Type`; aliases: Table[string, `Type`]): `Type`
proc semantic(value: semantic.Type; aliases: Table[string, `Type`]): `Type`

proc lower(node: ast.`Type`; aliases: Table[string, `Type`]): `Type` =
  if node == nil: return `Type`(kind: Shape.Void)
  case node.tag
  of "primitive":
    let primitive = ast.Primitive(node)
    if primitive.name == "integer": return `Type`(kind: Shape.Int, width: if primitive.width.len > 0: parseInt(primitive.width) else: 64)
    if primitive.name in ["unsigned", "byte", "character"]: return `Type`(kind: Shape.Uint, width: if primitive.width.len > 0: parseInt(primitive.width) elif primitive.name == "byte": 8 elif primitive.name == "character": 32 else: 64)
    if primitive.name == "decimal": return `Type`(kind: Shape.Float, width: if primitive.width.len > 0: parseInt(primitive.width) else: 64)
    if primitive.name == "boolean": return `Type`(kind: Shape.Bool)
    if primitive.name == "nothing": return `Type`(kind: Shape.Void)
    if primitive.name == "Error": return `Type`(kind: Shape.Error)
    if primitive.name == "text": return `Type`(kind: Shape.Slice, constant: true, elem: `Type`(kind: Shape.Uint, width: 8))
    `Type`(kind: Shape.Void)
  of "pointer": `Type`(kind: Shape.Ptr, elem: lower(ast.Pointer(node).elem, aliases))
  of "array", "sequence":
    let sequence = ast.Sequence(node)
    `Type`(kind: Shape.Slice, elem: lower(sequence.elem, aliases), constant: node.tag == "sequence" and sequence.constant)
  of "optional": `Type`(kind: Shape.Optional, elem: lower(ast.Optional(node).elem, aliases))
  of "error": `Type`(kind: Shape.Failable, elem: lower(ast.Error(node).elem, aliases))
  of "vector": `Type`(kind: Shape.Vector, width: parseInt(ast.Vector(node).length), elem: lower(ast.Vector(node).elem, aliases))
  of "function-type":
    let representation = ast.Signature(node)
    var params: seq[`Type`]
    for parameter in representation.params: params.add(lower(parameter, aliases))
    `Type`(kind: Shape.Function, params: params, ret: lower(representation.ret, aliases), abi: representation.abi)
  of "named": aliases.getOrDefault(ast.Named(node).name.text, `Type`(kind: Shape.Struct, name: ast.Named(node).name.text))
  of "generic-inst": aliases.getOrDefault(ast.Instantiation(node).name.text, `Type`(kind: Shape.Struct, name: ast.Instantiation(node).name.text))
  else: `Type`(kind: Shape.Void)

proc alias(alias: ast.Alias; aliases: Table[string, `Type`];
    typed: Table[pointer, semantic.Type]): `Type` =
  if alias.body == nil: return `Type`(kind: Shape.Opaque, name: alias.name.text)
  case alias.body.tag
  of "record":
    let record = ast.Record(alias.body)
    var fields = initOrderedTable[string, `Type`]()
    var annotations = initTable[string, seq[string]]()
    for field in record.fields:
      fields[field.name.text] = if typed.hasKey(cast[pointer](field.type)):
        semantic(typed[cast[pointer](field.type)], aliases)
      else: lower(field.type, aliases)
      if field.attributes.len > 0:
        annotations[field.name.text] = field.attributes
        if "volatile" in field.attributes: fields[field.name.text].volatile = true
    `Type`(kind: if record.layout == "packed": Shape.PackedStruct elif record.layout == "c": Shape.ExternStruct else: Shape.Struct,
      name: alias.name.text, fields: fields, annotations: annotations,
      attributes: alias.attributes)
  of "union":
    var fields = initOrderedTable[string, `Type`]()
    var annotations = initTable[string, seq[string]]()
    for field in ast.Union(alias.body).fields:
      fields[field.name.text] = if typed.hasKey(cast[pointer](field.type)):
        semantic(typed[cast[pointer](field.type)], aliases)
      else: lower(field.type, aliases)
      if field.attributes.len > 0:
        annotations[field.name.text] = field.attributes
        if "volatile" in field.attributes: fields[field.name.text].volatile = true
    `Type`(kind: Shape.ExternUnion, name: alias.name.text, fields: fields, annotations: annotations)
  of "choice":
    var variants = initOrderedTable[string, `Type`]()
    for variant in ast.Choice(alias.body).variants:
      variants[variant.name.text] = if variant.payload == nil: nil
        elif typed.hasKey(cast[pointer](variant.payload)):
          semantic(typed[cast[pointer](variant.payload)], aliases)
        else: lower(variant.payload, aliases)
    `Type`(kind: Shape.TaggedUnion, name: alias.name.text, variants: variants)
  of "opaque": `Type`(kind: Shape.Opaque, name: alias.name.text)
  else: lower(alias.body, aliases)

proc derive(value: semantic.Type; aliases: Table[string, `Type`];
    seen: var Table[pointer, `Type`]): `Type` =
  if value == nil: return `Type`(kind: Shape.Void)
  let identity = cast[pointer](value)
  if seen.hasKey(identity): return seen[identity]
  case value.kind
  of "primitive": return lower(ast.Primitive(tag: "primitive",
    name: value.name, width: if value.width > 0: $value.width else: ""), aliases)
  of "literal": return `Type`(kind: Shape.Int, width: 64)
  of "pointer": return `Type`(kind: Shape.Ptr,
    elem: derive(value.elem, aliases, seen))
  of "array", "sequence": return `Type`(kind: Shape.Slice,
    elem: derive(value.elem, aliases, seen), constant: value.constant)
  of "optional": return `Type`(kind: Shape.Optional,
    elem: derive(value.elem, aliases, seen))
  of "error": return `Type`(kind: Shape.Failable,
    elem: derive(value.elem, aliases, seen))
  of "vector": return `Type`(kind: Shape.Vector, width: value.length,
    elem: derive(value.elem, aliases, seen))
  of "function":
    var params: seq[`Type`]
    for parameter in value.params:
      params.add(derive(parameter, aliases, seen))
    return `Type`(kind: Shape.Function, params: params,
      ret: derive(value.ret, aliases, seen), abi: value.abi)
  of "record", "choice":
    if aliases.hasKey(value.name) and value.arguments.len == 0:
      return aliases[value.name]
    let base = value.name.split('[')[0]
    let kind = if value.kind == "choice": Shape.TaggedUnion
      elif aliases.hasKey(base): aliases[base].kind else: Shape.Struct
    result = `Type`(kind: kind, name: value.name,
      fields: initOrderedTable[string, `Type`](),
      variants: initOrderedTable[string, `Type`]())
    seen[identity] = result
    for argument in value.arguments:
      result.params.add(derive(argument, aliases, seen))
    if value.kind == "record":
      for name, field in value.fields:
        result.fields[name] = derive(field, aliases, seen)
    else:
      for name, variant in value.variants:
        result.variants[name] = if variant == nil: nil
          else: derive(variant, aliases, seen)
  of "union", "named", "opaque": return aliases.getOrDefault(value.name,
    `Type`(kind: if value.kind == "opaque": Shape.Opaque else: Shape.Struct,
      name: value.name))
  else: return `Type`(kind: Shape.Void)

proc semantic(value: semantic.Type; aliases: Table[string, `Type`]): `Type` =
  var seen = initTable[pointer, `Type`]()
  derive(value, aliases, seen)

proc literal(node: ast.Expression; typ: `Type`): Value =
  case node.tag
  of "true", "false": Value(kind: Flavor.Const, name: node.tag, `type`: typ)
  of "nothing": Value(kind: Flavor.Const, name: "{}", `type`: typ)
  of "null": Value(kind: Flavor.Const, name: "null", `type`: typ)
  of "text", "newline":
    let text = if node.tag == "newline": "\n" else: ast.Text(node).value
    var data = newSeq[byte](text.len)
    for index, item in text: data[index] = byte(item.ord)
    Value(kind: Flavor.Const, name: quoted(data), `type`: typ)
  of "character": Value(kind: Flavor.Const, name: $ast.Character(node).value.runeAt(0).int, `type`: typ)
  of "decimal": Value(kind: Flavor.Const, name: ast.Decimal(node).value, `type`: typ)
  of "integer": Value(kind: Flavor.Const, name: ast.Integer(node).value, `type`: typ)
  else: Value(kind: Flavor.Const, name: "undefined", `type`: typ)

proc copy(value: `Type`; attributes: seq[string]): `Type` =
  if value == nil: return nil
  `Type`(kind: value.kind, name: value.name, elem: value.elem, width: value.width,
    fields: value.fields, annotations: value.annotations, variants: value.variants,
    params: value.params, ret: value.ret, abi: value.abi, attributes: attributes,
    volatile: value.volatile, constant: value.constant)

proc label(value: string): string =
  result = newString(value.len)
  for index, character in value: result[index] = character

proc function(routine: ast.Function; signatures: Table[string, `Type`];
    aliases: Table[string, `Type`]; constants: Table[string, ast.Constant];
    bindings: Table[string, ast.Expression]; storage: seq[Storage];
    symbols: Table[string, string]; typed: Table[pointer, semantic.Type]; destination: string): node.Function =
  let signature = signatures[routine.name.text]
  var params: seq[Value]
  for index, parameter in routine.params:
    params.add(Value(kind: Flavor.Reg, name: parameter.name.text, `type`: signature.params[index]))
  var environment = initTable[string, Value]()
  var slots = initTable[string, Value]()
  var closures = initTable[string, ast.Closure]()
  for parameter in params: environment[parameter.name] = parameter
  for item in storage:
    if not environment.hasKey(item.name):
      slots[item.name] = Value(kind: Flavor.Global, name: item.name,
        `type`: `Type`(kind: Shape.Ptr, elem: item.value.type))
  var pending = initHashSet[string]()
  var instructions: seq[Instruction]
  var serial = 0
  proc fresh(typ: `Type`): Value =
    inc serial
    Value(kind: Flavor.Reg, name: "tmp_" & $serial, `type`: typ)
  var range = Location(file: (if destination.len > 0: destination else: routine.span.file), start: routine.span.start, `end`: routine.span.end)
  proc emit(instruction: Instruction) =
    if instruction.span.file.len == 0: instruction.span = range
    instructions.add(instruction)
  proc adapt(value: Value; expected: `Type`): Value =
    if expected == nil or value.type == nil: return value
    let numeric = {Shape.Int, Shape.Uint, Shape.Float}
    if value.kind == Flavor.Const and value.type.kind in numeric and
        expected.kind in numeric:
      result = value
      result.type = expected
      return
    let widen = value.type.kind in numeric and expected.kind in numeric and
      (value.type.kind != expected.kind or value.type.width != expected.width)
    let wrap = expected.kind in {Shape.Optional, Shape.Failable} and
      value.type.kind != expected.kind
    let view = expected.kind == Shape.Slice and value.type.kind == Shape.Slice and
      expected.constant != value.type.constant
    if wrap:
      let inner = adapt(value,expected.elem)
      let dest = fresh(expected)
      emit(Instruction(kind: Opcode.Convert,dest:dest,val:inner))
      return dest
    let codecAdapter = value.type.kind == Shape.Function and
      expected.kind == Shape.Function and value.type.abi == "runtime.codec" and
      expected.abi.len == 0
    if widen or wrap or view or codecAdapter:
      let dest = fresh(expected)
      emit(Instruction(kind: Opcode.Convert, dest: dest, val: value))
      return dest
    value
  var blocks: seq[node.Block]
  var label = "entry"
  var term: Instruction
  var loops: seq[tuple[head: string, exit: string, depth: int]]
  proc finish(ending: Instruction) =
    if ending != nil and ending.span.file.len == 0: ending.span = range
    blocks.add(node.Block(label: label, instrs: instructions, term: ending))
  proc begin(name: string) =
    label = name
    instructions = @[]
    term = nil
  type Cleanup = object
    statement: ast.`Defer`
    values: Table[string, Value]
    storage: Table[string, Value]
  var scopes: seq[seq[Cleanup]]
  var cleanupLimits: seq[int]
  proc snapshot(source: Table[string, Value]): Table[string, Value] =
    result = initTable[string, Value]()
    for key, value in source: result[key] = value
  proc expression(node: ast.Expression; expected: `Type` = nil): Value
  proc statements(body: seq[ast.Statement])
  proc cleanup(first: int; failed: Value = Value(); status = -1)
  proc propagate(value: Value): Value
  proc cleanup(): bool =
    for scope in scopes:
      if scope.len > 0: return true
  proc place(value: ast.Expression): Value
  proc place(value: ast.Expression): Value =
    if value != nil and value.tag == "name" and slots.hasKey(ast.Name(value).text):
      return slots[ast.Name(value).text]
    if value != nil and value.tag == "index":
      let indexed = ast.Index(value)
      let source = expression(indexed.object)
      let dest = fresh(`Type`(kind: Shape.Ptr, elem: source.type.elem))
      emit(Instruction(kind: Opcode.Index, op: "address", dest: dest,
        val: source, val2: expression(indexed.index)))
      return dest
    if value != nil and value.tag == "field":
      let field = ast.Field(value)
      let pointer = place(field.object)
      if pointer.type == nil or pointer.type.elem == nil or
          not pointer.type.elem.fields.hasKey(field.field.text):
        raise newException(ValueError, "Unknown dynamic field '" & field.field.text & "'")
      let dest = fresh(`Type`(kind: Shape.Ptr,
        elem: pointer.type.elem.fields[field.field.text]))
      emit(Instruction(kind: Opcode.Extract, op: "address", dest: dest,
        val: pointer, field: field.field.text))
      return dest
    raise newException(ValueError, "Assignment requires a dynamic place")
  proc expression(node: ast.Expression; expected: `Type` = nil): Value =
    if node == nil: return Value(kind: Flavor.Const, name: "null", `type`: expected)
    let location = range
    range = Location(file: (if destination.len > 0: destination else: node.span.file), start: node.span.start, `end`: node.span.end)
    defer: range = location
    proc invoke(callee: Value; name = "";
        arguments: seq[ast.Expression] = @[]): Value =
      let signature = if name.len > 0: signatures.getOrDefault(name) else: callee.type
      if signature == nil or signature.kind != Shape.Function:
        raise newException(ValueError, "A zero-argument call needs a function value")
      let dest = if signature.ret.kind == Shape.Void: Value() else: fresh(signature.ret)
      var args: seq[Value]
      for index, argument in arguments:
        args.add(expression(argument,
          if index < signature.params.len: signature.params[index] else: nil))
      emit(Instruction(kind: Opcode.Call, dest: dest,
        `func`: name, callee: if name.len == 0: callee else: Value(),
        abi: signature.abi, symbol: if name.len > 0: symbols.getOrDefault(name) else: "",
        args: args))
      if signature.ret.kind == Shape.Void:
        Value(kind: Flavor.Const, name: "{}", `type`: signature.ret)
      else:
        adapt(dest, expected)
    case node.tag
    of "integer", "decimal", "text", "character", "true", "false", "nothing", "null", "newline":
      let inferred =
        if node.tag == "integer": `Type`(kind: Shape.Int, width: 64)
        elif node.tag == "decimal": `Type`(kind: Shape.Float, width: 64)
        elif node.tag in ["true", "false"]: `Type`(kind: Shape.Bool)
        elif node.tag == "character": `Type`(kind: Shape.Uint, width: 32)
        elif node.tag in ["text", "newline"]: `Type`(kind: Shape.Slice, constant: true, elem: `Type`(kind: Shape.Uint, width: 8))
        else: `Type`(kind: Shape.Void)
      let target =
        if node.tag == "nothing":
          if expected != nil and expected.kind == Shape.Failable: expected.elem
          elif expected != nil: expected
          else: inferred
        elif node.tag == "null":
          if expected != nil and expected.kind == Shape.Optional: expected
          else: inferred
        elif expected != nil and expected.kind in {Shape.Optional, Shape.Failable}:
          expected.elem
        elif expected != nil: expected
        else: inferred
      return adapt(literal(node, target), expected)
    of "uninitialized": return Value(kind: Flavor.Const, name: "undefined", `type`: if expected != nil: expected else: `Type`(kind: Shape.Void))
    of "name":
      if ast.Name(node).invoke and closures.hasKey(ast.Name(node).text):
        return expression(ast.Call(tag: "call", span: node.span,
          callee: ast.Name(tag: "name", span: node.span,
            text: ast.Name(node).text), args: @[]), expected)
      if slots.hasKey(ast.Name(node).text):
        let pointer = slots[ast.Name(node).text]
        let dest = fresh(pointer.type.elem)
        emit(Instruction(kind: Opcode.Load, dest: dest, `ptr`: pointer))
        if ast.Name(node).invoke:
          return invoke(dest, arguments = ast.Name(node).arguments)
        return adapt(dest, expected)
      if environment.hasKey(ast.Name(node).text):
        let value = environment[ast.Name(node).text]
        if ast.Name(node).invoke:
          return invoke(value, arguments = ast.Name(node).arguments)
        return adapt(value, expected)
      if constants.hasKey(ast.Name(node).text):
        let name = ast.Name(node).text
        if name in pending: raise newException(ValueError, "Circular constant initializer '" & name & "'")
        pending.incl(name)
        let declaration = constants[name]
        let value = expression(eval.evaluate(declaration.value, bindings),
          if declaration.type != nil: lower(declaration.type, aliases) else: expected)
        pending.excl(name)
        if ast.Name(node).invoke:
          return invoke(value, arguments = ast.Name(node).arguments)
        return value
      for alias in aliases.values:
        if alias.kind == Shape.TaggedUnion and alias.variants.hasKey(ast.Name(node).text):
          let checked = typed.getOrDefault(cast[pointer](node))
          let target = if checked != nil and checked.kind == "choice":
            semantic(checked, aliases) else: alias
          let dest = fresh(target)
          emit(Instruction(kind: Opcode.Construct, dest: dest,
            field: ast.Name(node).text, args: @[]))
          return dest
      if ast.Name(node).invoke:
        return invoke(Value(), ast.Name(node).text,
          ast.Name(node).arguments)
      return adapt(Value(kind: Flavor.Global, name: ast.Name(node).text,
        `type`: signatures.getOrDefault(ast.Name(node).text,
          `Type`(kind: Shape.Void))), expected)
    of "group": return expression(ast.Group(node).expr, expected)
    of "sequence-value":
      let sequence = ast.Values(node)
      let checked = typed.getOrDefault(cast[pointer](node))
      let target = if expected != nil: expected
        elif checked != nil: semantic(checked, aliases)
        else: `Type`(kind: Shape.Slice, constant: true,
          elem: `Type`(kind: Shape.Void))
      var items: seq[Value]
      for item in sequence.items: items.add(expression(item, target.elem))
      let dest = fresh(target)
      emit(Instruction(kind: Opcode.Construct, op: "sequence",
        dest: dest, args: items))
      return dest
    of "index", "field":
      if node.tag == "field":
        let field = ast.Field(node)
        if field.object.tag == "name" and ast.Name(field.object).text == "Error":
          return Value(kind: Flavor.Const, name: field.field.text, `type`: `Type`(kind: Shape.Error))
      let source = if node.tag == "index": expression(ast.Index(node).object) else: expression(ast.Field(node).object)
      var projected: `Type`
      let dest = if node.tag == "index":
        projected = source.type.elem
        fresh(projected)
      else:
        let field = ast.Field(node).field.text
        if source.type != nil and source.type.fields.hasKey(field): projected = source.type.fields[field]
        fresh(if projected != nil: projected else: `Type`(kind: Shape.Void))
      if node.tag == "index":
        emit(Instruction(kind: Opcode.Index, dest: dest, val: source,
          val2: expression(ast.Index(node).index)))
      else:
        emit(Instruction(kind: Opcode.Extract, dest: dest, val: source,
          field: ast.Field(node).field.text))
      if node.tag == "field" and ast.Field(node).invoke:
        return invoke(dest)
      return adapt(dest, expected)
    of "embed":
      let embedded = ast.Embed(node)
      let target = if expected != nil: expected elif embedded.type != nil: lower(embedded.type, aliases) else: `Type`(kind: Shape.Slice, constant: true, elem: `Type`(kind: Shape.Uint, width: 8))
      let dest = fresh(target)
      emit(Instruction(kind: Opcode.Embed, dest: dest, path: embedded.path))
      return dest
    of "reflect":
      let reflected = ast.Reflect(node)
      let target = if expected != nil: expected
        elif typed.hasKey(cast[pointer](node)): semantic(typed[cast[pointer](node)], aliases)
        else: `Type`(kind: Shape.Opaque, name: "Description")
      let dest = fresh(target)
      emit(Instruction(kind: Opcode.Reflect, dest: dest, argument: lower(reflected.type, aliases)))
      return dest
    of "unreachable":
      term = Instruction(kind: Opcode.Panic, msg: "unreachable")
      return Value(kind: Flavor.Const, name: "{}", `type`: if expected != nil: expected else: `Type`(kind: Shape.Void))
    of "binary":
      let binary = ast.Binary(node)
      if binary.op in ["and", "or"]:
        let left = expression(binary.left)
        let origin = label(label)
        inc serial
        let alternative = "right_" & $serial
        let ending = "logic_" & $serial
        finish(Instruction(kind: Opcode.Cjump, cond: left,
          yes: if binary.op == "and": alternative else: ending,
          no: if binary.op == "and": ending else: alternative))
        begin(alternative)
        let right = expression(binary.right)
        let predecessor = label(label)
        finish(Instruction(kind: Opcode.Jump, label: ending))
        begin(ending)
        let dest = fresh(`Type`(kind: Shape.Bool))
        emit(Instruction(kind: Opcode.Phi, dest: dest,
          blocks: @[(label: origin, value: left), (label: predecessor, value: right)]))
        return dest
      if binary.op == "catch":
        let left = expression(binary.left)
        if left.type == nil or left.type.kind != Shape.Failable:
          raise newException(ValueError, "fallback needs a failable value")
        inc serial
        let failure = "catch_" & $serial
        let success = "success_" & $serial
        let ending = "result_" & $serial
        let failed = fresh(`Type`(kind: Shape.Bool))
        emit(Instruction(kind: Opcode.Extract, dest: failed, val: left, field: "failed"))
        finish(Instruction(kind: Opcode.Cjump, cond: failed, yes: failure, no: success))
        begin(failure)
        let fallback = expression(binary.right, left.type.elem)
        let predecessor = label(label)
        finish(Instruction(kind: Opcode.Jump, label: ending))
        begin(success)
        let value = fresh(left.type.elem)
        emit(Instruction(kind: Opcode.Extract, dest: value, val: left, field: "value"))
        finish(Instruction(kind: Opcode.Jump, label: ending))
        begin(ending)
        if left.type.elem.kind == Shape.Void:
          return Value(kind: Flavor.Const, name: "{}", `type`: left.type.elem)
        let dest = fresh(left.type.elem)
        emit(Instruction(kind: Opcode.Phi, dest: dest,
          blocks: @[(label: predecessor, value: fallback), (label: success, value: value)]))
        return dest
      var hint = if typed.hasKey(cast[pointer](binary.left)):
        semantic(typed[cast[pointer](binary.left)], aliases)
        elif expected != nil and expected.kind in {Shape.Failable, Shape.Optional}:
          expected.elem
        else: expected
      if binary.op in ["equals", "does not equal", "is greater than", "is less than", "is at least", "is at most"] and
          typed.hasKey(cast[pointer](binary.left)) and typed[cast[pointer](binary.left)].kind == "literal" and
          typed.hasKey(cast[pointer](binary.right)):
        let inference = semantic(typed[cast[pointer](binary.right)],aliases)
        if inference.kind in {Shape.Int,Shape.Uint,Shape.Float}: hint = inference
      var left = expression(binary.left, hint)
      var right = expression(binary.right, left.type)
      let comparison = binary.op in ["equals", "does not equal", "is greater than", "is less than", "is at least", "is at most"]
      if comparison:
        if left.type.kind == Shape.Optional and right.type.kind != Shape.Optional:
          right = adapt(right,left.type)
        elif right.type.kind == Shape.Optional and left.type.kind != Shape.Optional:
          left = adapt(left,right.type)
      let output = if comparison and left.type.kind == Shape.Vector: `Type`(kind: Shape.Vector, width: left.type.width, elem: `Type`(kind: Shape.Bool)) elif comparison: `Type`(kind: Shape.Bool) else: left.type
      let dest = fresh(output)
      let operation = if comparison: Opcode.Compare elif binary.op in ["plus", "+"]: Opcode.Add elif binary.op in ["minus", "-"]: Opcode.Sub elif binary.op in ["times", "*"]: Opcode.Mul elif binary.op == "remainder": Opcode.Remainder elif binary.op == "divided by": Opcode.Div else: raise newException(ValueError, "lowering for binary operator '" & binary.op & "' is not implemented")
      emit(Instruction(kind: operation, dest: dest, op: binary.op, val: left, val2: right)); return dest
    of "unary":
      let unary = ast.Unary(node); let operand = expression(unary.operand)
      if unary.op == "try":
        if operand.type == nil or operand.type.kind != Shape.Failable:
          raise newException(ValueError, "try needs a failable value")
        if cleanup(): return propagate(operand)
        let dest = fresh(operand.type.elem)
        emit(Instruction(kind: Opcode.Try, dest: dest, expr: operand))
        return dest
      let dest = fresh(if unary.op == "not": `Type`(kind: Shape.Bool) else: operand.type)
      emit(Instruction(kind: if unary.op == "not": Opcode.Not else: Opcode.Convert, dest: dest, val: operand)); return dest
    of "call":
      let call = ast.Call(node)
      if call.callee.tag == "name":
        let name = ast.Name(call.callee).text
        if closures.hasKey(name):
          let closure = closures[name]
          if call.args.len != closure.params.len:
            raise newException(ValueError, "Closure argument count was not normalized")
          var arguments: seq[Value]
          for index, argument in call.args:
            let shape = if typed.hasKey(cast[pointer](closure.params[index])):
              semantic(typed[cast[pointer](closure.params[index])], aliases)
            else: lower(closure.params[index].type, aliases)
            arguments.add(expression(argument, shape))
          let context = snapshot(environment)
          let backup = snapshot(slots)
          for index, parameter in closure.params:
            environment[parameter.name.text] = arguments[index]
            slots.del(parameter.name.text)
          var body = closure.body.stmts
          var returned: ast.Expression
          if body.len > 0 and body[^1].tag == "give":
            returned = ast.Give(body[^1]).value
            body.setLen(body.len - 1)
          statements(body)
          if term != nil:
            raise newException(ValueError,
              "A scoped closure must reach its final give statement")
          let value = if returned != nil: expression(returned, expected)
            else: Value(kind: Flavor.Const, name: "void",
              `type`: `Type`(kind: Shape.Void))
          environment = context
          slots = backup
          return value
        if name == "fail" and not signatures.hasKey(name):
          let target = if expected != nil and expected.kind == Shape.Failable: expected else: `Type`(kind: Shape.Failable, elem: `Type`(kind: Shape.Void))
          let dest = fresh(target)
          emit(Instruction(kind: Opcode.Construct, op: "error", dest: dest,
            args: @[expression(call.args[0], `Type`(kind: Shape.Error))]))
          return dest
        if name == "bit":
          let checked = typed.getOrDefault(cast[pointer](node))
          if checked == nil or call.args.len notin [2, 3] or
              call.args[^1].tag != "text":
            raise newException(ValueError, "bit call needs checked operands and a literal operation")
          let target = semantic(checked, aliases)
          let mode = ast.Text(call.args[^1]).value
          let left = expression(call.args[0], target)
          let right = if call.args.len == 3:
              expression(call.args[1], if mode in ["and", "or", "xor"]: target else: nil)
            else: Value()
          let dest = fresh(target)
          emit(Instruction(kind: Opcode.Bit, op: mode, dest: dest,
            val: left, val2: right))
          return dest
        if name == "lengthof":
          let input = expression(call.args[0])
          let dest = fresh(`Type`(kind: Shape.Uint, width: 64))
          emit(Instruction(kind: Opcode.Length, dest: dest, val: input))
          return dest
        if aliases.hasKey(name) and aliases[name].kind in {Shape.Struct, Shape.PackedStruct, Shape.ExternStruct}:
          let checked = typed.getOrDefault(cast[pointer](node))
          let target =
            if checked != nil and checked.kind == "record": semantic(checked, aliases)
            elif expected != nil and expected.fields.len > 0: expected
            else: aliases[name]
          var fields: seq[`Type`]
          for field in target.fields.values: fields.add(field)
          var args: seq[Value]
          for index, argument in call.args: args.add(expression(argument, if index < fields.len: fields[index] else: nil))
          let dest = fresh(target)
          emit(Instruction(kind: Opcode.Construct, dest: dest, args: args))
          return dest
        let checked = typed.getOrDefault(cast[pointer](node))
        for alias in aliases.values:
          if alias.kind == Shape.TaggedUnion and alias.variants.hasKey(name):
            let target = if checked != nil and checked.kind == "choice":
              semantic(checked, aliases) else: alias
            let dest = fresh(target)
            var args: seq[Value]
            if target.variants[name] != nil:
              for argument in call.args:
                args.add(expression(argument, target.variants[name]))
            emit(Instruction(kind: Opcode.Construct, dest: dest, field: name, args: args))
            return dest
        if name in ["splat", "shuffle", "permute", "gather", "scatter", "select", "reduce"]:
          if name == "splat":
            if expected == nil: raise newException(ValueError, "splat lowering needs an expected vector type")
            let dest = fresh(expected)
            emit(Instruction(kind: Opcode.Splat, dest: dest, val: expression(call.args[0], expected.elem)))
            return dest
          let first = expression(call.args[0])
          if name in ["gather", "scatter"]:
            let indices = expression(call.args[1])
            if name == "gather":
              let target = `Type`(kind: Shape.Vector, width: indices.type.width,
                elem: first.type.elem)
              let dest = fresh(target)
              emit(Instruction(kind: Opcode.Gather, dest: dest, val: first,
                val2: indices))
              return dest
            let values = expression(call.args[2])
            let dest = fresh(first.type)
            emit(Instruction(kind: Opcode.Scatter, dest: dest, val: first,
              val2: indices, args: @[values]))
            return dest
          if name == "reduce":
            let dest = fresh(first.type.elem)
            let operation = if call.args.len > 1 and call.args[1].tag == "text": ast.Text(call.args[1]).value else: "add"
            let reduction = case operation
              of "add": "Add"
              of "multiply": "Mul"
              of "minimum": "Min"
              of "maximum": "Max"
              of "and": "And"
              of "or": "Or"
              of "xor": "Xor"
              else: raise newException(ValueError, "unknown vector reduction " & operation)
            emit(Instruction(kind: Opcode.Reduce, dest: dest, val: first, reduction: reduction))
            return dest
          if name in ["shuffle", "permute"]:
            let second = if name == "shuffle": expression(call.args[1], first.type) else: first
            var mask: seq[int]
            for index in (if name == "shuffle": 2 else: 1) ..< call.args.len:
              mask.add(if call.args[index].tag == "integer": parseInt(ast.Integer(call.args[index]).value) else: 0)
            let dest = fresh(`Type`(kind: Shape.Vector, width: mask.len, elem: first.type.elem))
            emit(Instruction(kind: Opcode.Shuffle, dest: dest, val: first, val2: second, mask: mask))
            return dest
          let yes = expression(call.args[1])
          let no = expression(call.args[2], yes.type)
          let dest = fresh(yes.type)
          emit(Instruction(kind: Opcode.Select, dest: dest, cond: first, val: yes, val2: no))
          return dest
        var sig: `Type`
        var indirect = Value()
        if environment.hasKey(name) and environment[name].type.kind == Shape.Function:
          indirect = environment[name]
          sig = indirect.type
        elif signatures.hasKey(name): sig = signatures[name]
        if sig != nil:
          var arguments: seq[`Type`]
          if sig.attributes.len > 0:
            var substitutions = initTable[string, `Type`]()
            proc infer(pattern, actual: `Type`) =
              if pattern == nil or actual == nil: return
              if pattern.name.len > 0 and pattern.name in sig.attributes:
                substitutions[pattern.name] = actual
              elif pattern.elem != nil and actual.elem != nil:
                infer(pattern.elem, actual.elem)
              elif pattern.fields.len > 0 and actual.fields.len > 0:
                for field, member in pattern.fields:
                  if actual.fields.hasKey(field): infer(member, actual.fields[field])
            for index, argument in call.args:
              if index < sig.params.len and typed.hasKey(cast[pointer](argument)):
                infer(sig.params[index], semantic(typed[cast[pointer](argument)], aliases))
            for index, argument in call.types:
              if index < sig.attributes.len:
                substitutions[sig.attributes[index]] = if typed.hasKey(cast[pointer](argument)): semantic(typed[cast[pointer](argument)], aliases) else: lower(argument, aliases)
            for parameter in sig.attributes:
              if not substitutions.hasKey(parameter):
                raise newException(ValueError, "Generic calls need fully inferred type arguments")
              arguments.add(substitutions[parameter])
            proc replace(value: `Type`): `Type` =
              if value == nil: return nil
              if value.name.len > 0 and substitutions.hasKey(value.name): return substitutions[value.name]
              result = copy(value, value.attributes)
              if value.elem != nil: result.elem = replace(value.elem)
              if value.ret != nil: result.ret = replace(value.ret)
              result.params = @[]
              for parameter in value.params: result.params.add(replace(parameter))
              result.fields = initOrderedTable[string, `Type`]()
              for field, member in value.fields: result.fields[field] = replace(member)
              result.variants = initOrderedTable[string, `Type`]()
              for variant, variantType in value.variants:
                result.variants[variant] = if variantType == nil: nil else: replace(variantType)
            sig = replace(sig)
          var args: seq[Value]
          for index, argument in call.args:
            let parameter = if index < sig.params.len: sig.params[index] else: nil
            args.add(adapt(expression(argument, parameter), parameter))
          let dest = if sig.ret.kind == Shape.Void: Value() else: fresh(sig.ret)
          emit(Instruction(kind: Opcode.Call, dest: dest,
            `func`: if indirect.name.len == 0: name else: "", callee: indirect,
            abi: sig.abi, symbol: symbols.getOrDefault(name), args: args, arguments: arguments))
          return if sig.ret.kind == Shape.Void: Value(kind: Flavor.Const, name: "{}", `type`: sig.ret) else: dest
      let callee = expression(call.callee)
      if callee.type == nil or callee.type.kind != Shape.Function:
        raise newException(ValueError, "An indirect call needs a function value")
      var args: seq[Value]
      for index, argument in call.args:
        let parameter = if index < callee.type.params.len: callee.type.params[index] else: nil
        args.add(adapt(expression(argument, parameter), parameter))
      let dest = if callee.type.ret.kind == Shape.Void: Value() else: fresh(callee.type.ret)
      emit(Instruction(kind: Opcode.Call, dest: dest, callee: callee, abi: callee.type.abi, args: args))
      return if callee.type.ret.kind == Shape.Void: Value(kind: Flavor.Const, name: "{}", `type`: callee.type.ret) else: dest
    of "allocation":
      let allocation = ast.Allocation(node); let size = expression(allocation.size)
      let dest = fresh(if expected != nil: expected else: `Type`(kind: Shape.Failable, elem: `Type`(kind: Shape.Slice, elem: `Type`(kind: Shape.Uint, width: 8))))
      let owner = if allocation.owner != nil: expression(allocation.owner) else: Value()
      emit(Instruction(kind: Opcode.Allocate, dest: dest, val: size,
        target: owner, region: "scope", effects: @["allocate", "write"])); return dest
    of "machine":
      let machine = ast.Machine(node)
      let integer = `Type`(kind: Shape.Int, width: 64)
      let unsigned = `Type`(kind: Shape.Uint, width: 64)
      let unit = `Type`(kind: Shape.Void)
      if machine.operation == "atomic":
        let pointer = place(machine.target)
        let element = pointer.type.elem
        var properties = element.attributes
        if "atomic" notin properties: properties.add("atomic")
        element.attributes = properties
        let plain = copy(element, @[])
        let dest = fresh(plain)
        emit(Instruction(kind: Opcode.Atomic, op: "add", field: "seq_cst", `ptr`: pointer,
          val: expression(machine.value, plain), dest: dest,
          effects: @["read", "write", "synchronize", "machine"]))
        return Value(kind: Flavor.Const, name: "void", `type`: unit)
      if machine.operation in ["set", "clear", "toggle"]:
        let pointer = place(machine.target)
        let current = fresh(pointer.type.elem)
        let updated = fresh(pointer.type.elem)
        emit(Instruction(kind: Opcode.Load, dest: current, `ptr`: pointer))
        emit(Instruction(kind: Opcode.Bit, op: machine.operation, dest: updated,
          val: current, val2: expression(machine.value, unsigned)))
        emit(Instruction(kind: Opcode.Store, `ptr`: pointer, val: updated))
        return Value(kind: Flavor.Const, name: "void", `type`: unit)
      var args: seq[Value]
      if machine.operation == "system":
        args.add(expression(machine.value, integer))
        for argument in machine.args: args.add(expression(argument, integer))
      elif machine.operation == "register":
        args.add(expression(machine.value, unsigned))
      elif machine.operation == "align":
        args.add(place(machine.target))
        args.add(expression(machine.value, unsigned))
      else:
        args.add(place(machine.target))
        args.add(expression(machine.value, unsigned))
      let dest = if machine.operation == "system": fresh(integer) else: Value()
      emit(Instruction(kind: Opcode.Native,
        op: "machine:" & machine.operation & (if machine.register.len > 0: ":" & machine.register else: ""),
        field: "@c", args: args, dest: dest, effects: @["unknown", "machine"]))
      return if machine.operation == "system": dest else: Value(kind: Flavor.Const, name: "void", `type`: unit)
    else: raise newException(ValueError, "lowering for expression '" & node.tag & "' is not implemented")
  proc statements(body: seq[ast.Statement]) =
    let location = range
    defer: range = location
    let outer = snapshot(environment)
    let saved = snapshot(slots)
    scopes.add(@[])
    cleanupLimits.add(high(int))
    for statement in body:
      range = Location(file: (if destination.len > 0: destination else: statement.span.file), start: statement.span.start, `end`: statement.span.end)
      case statement.tag
      of "unsafe":
        statements(ast.Unsafe(statement).body.stmts)
        if term != nil: break
      of "for":
        let iteration = ast.`For`(statement)
        let iter = expression(iteration.iter)
        if iter.type == nil or iter.type.elem == nil:
          raise newException(ValueError, "for needs an iterable sequence")
        inc serial
        let suffix = $serial
        let number = `Type`(kind: Shape.Uint, width: 64)
        let counter = fresh(`Type`(kind: Shape.Ptr, elem: number))
        emit(Instruction(kind: Opcode.Alloc, op: "slot", region: "scope", dest: counter))
        emit(Instruction(kind: Opcode.Store, `ptr`: counter,
          val: Value(kind: Flavor.Const, name: "0", `type`: number)))
        let head = "for_" & suffix
        let visit = "item_" & suffix
        let advance = "advance_" & suffix
        let ending = "end_" & suffix
        finish(Instruction(kind: Opcode.Jump, label: head))
        begin(head)
        let index = fresh(number)
        let length = fresh(number)
        let condition = fresh(`Type`(kind: Shape.Bool))
        emit(Instruction(kind: Opcode.Load, dest: index, `ptr`: counter))
        emit(Instruction(kind: Opcode.Length, dest: length, val: iter))
        emit(Instruction(kind: Opcode.Compare, dest: condition, op: "is less than",
          val: index, val2: length))
        finish(Instruction(kind: Opcode.Cjump, cond: condition,
          yes: visit, no: ending))
        begin(visit)
        let item = fresh(iter.type.elem)
        emit(Instruction(kind: Opcode.Index, dest: item, val: iter, val2: index))
        let existed = environment.hasKey(iteration.bind.text)
        let previous = environment.getOrDefault(iteration.bind.text)
        environment[iteration.bind.text] = item
        loops.add((head: advance, exit: ending, depth: scopes.len))
        statements(iteration.body.stmts)
        discard loops.pop()
        if existed: environment[iteration.bind.text] = previous
        else: environment.del(iteration.bind.text)
        finish(if term != nil: term else: Instruction(kind: Opcode.Jump, label: advance))
        begin(advance)
        let increment = fresh(number)
        emit(Instruction(kind: Opcode.Add, dest: increment, val: index,
          val2: Value(kind: Flavor.Const, name: "1", `type`: number)))
        emit(Instruction(kind: Opcode.Store, `ptr`: counter, val: increment))
        finish(Instruction(kind: Opcode.Jump, label: head))
        begin(ending)
      of "match":
        let matched = ast.Match(statement)
        let value = expression(matched.scrutinee)
        inc serial
        let suffix = $serial
        let ending = "match_" & suffix
        var exits = true
        for index, arm in matched.cases:
          let yes = "case_" & suffix & "_" & $index
          let no = "next_" & suffix & "_" & $index
          var condition = Value(kind: Flavor.Const, name: "true",
            `type`: `Type`(kind: Shape.Bool))
          let variant =
            if arm.pattern.tag == "variant-pattern": ast.Arm(arm.pattern).name.text
            elif arm.pattern.tag == "name": ast.Name(arm.pattern).text
            else: ""
          if arm.pattern.tag != "wildcard":
            var left = value
            var right: Value
            if value.type.kind == Shape.TaggedUnion and variant.len > 0:
              left = fresh(`Type`(kind: Shape.Uint, width: 32))
              emit(Instruction(kind: Opcode.Extract, dest: left, val: value, field: "tag"))
              var tag = 0
              var current = 0
              for name in value.type.variants.keys:
                if name == variant: tag = current
                inc current
              right = Value(kind: Flavor.Const, name: $tag, `type`: left.type)
            else:
              right = expression(ast.Expression(arm.pattern), value.type)
            condition = fresh(`Type`(kind: Shape.Bool))
            emit(Instruction(kind: Opcode.Compare, dest: condition, op: "equals",
              val: left, val2: right))
          finish(Instruction(kind: Opcode.Cjump, cond: condition,
            yes: yes, no: no))
          begin(yes)
          let context = environment
          if arm.pattern.tag == "variant-pattern" and ast.Arm(arm.pattern).binding != nil:
            let contained = value.type.variants.getOrDefault(variant)
            if contained != nil:
              let payload = fresh(contained)
              emit(Instruction(kind: Opcode.Extract, dest: payload, val: value, field: variant))
              environment[ast.Arm(arm.pattern).binding.text] = payload
          if arm.guard != nil:
            let guard = expression(arm.guard)
            let guarded = "guard_" & suffix & "_" & $index
            finish(Instruction(kind: Opcode.Cjump, cond: guard,
              yes: guarded, no: no))
            begin(guarded)
          statements(arm.body.stmts)
          exits = exits and term != nil
          finish(if term != nil: term else: Instruction(kind: Opcode.Jump, label: ending))
          environment = context
          begin(no)
        finish(Instruction(kind: Opcode.Panic, msg: "non-exhaustive match"))
        begin(ending)
        if exits:
          term = Instruction(kind: Opcode.Panic, msg: "unreachable match join")
          break
      of "when":
        let branch = ast.`When`(statement)
        let condition = expression(branch.cond)
        inc serial
        let yes = "then_" & $serial
        let no = "else_" & $serial
        let ending = "end_" & $serial
        finish(Instruction(kind: Opcode.Cjump, cond: condition,
          yes: yes, no: no))
        begin(yes)
        statements(branch.`then`.stmts)
        let finished = term != nil
        finish(if term != nil: term else: Instruction(kind: Opcode.Jump, label: ending))
        begin(no)
        if branch.`else` != nil:
          if branch.`else`.tag == "when": statements(@[ast.Statement(branch.`else`)])
          else: statements(ast.Block(branch.`else`).stmts)
        let terminated = term != nil
        finish(if term != nil: term else: Instruction(kind: Opcode.Jump, label: ending))
        begin(ending)
        if finished and terminated:
          term = Instruction(kind: Opcode.Panic, msg: "unreachable branch join")
          break
      of "while":
        let loop = ast.`While`(statement)
        inc serial
        let head = "while_" & $serial
        let content = "body_" & $serial
        let ending = "end_" & $serial
        finish(Instruction(kind: Opcode.Jump, label: head))
        begin(head)
        let condition = expression(loop.cond)
        finish(Instruction(kind: Opcode.Cjump, cond: condition,
          yes: content, no: ending))
        begin(content)
        loops.add((head: head, exit: ending, depth: scopes.len))
        statements(loop.body.stmts)
        discard loops.pop()
        finish(if term != nil: term else: Instruction(kind: Opcode.Jump, label: head))
        begin(ending)
      of "break", "continue":
        if loops.len == 0: raise newException(ValueError, statement.tag & " needs a loop")
        let active = loops[^1]
        cleanup(active.depth, status = -1)
        term = Instruction(kind: Opcode.Jump,
          label: if statement.tag == "break": active.exit else: active.head)
        break
      of "constant":
        let declaration = ast.Constant(statement)
        if declaration.value.tag == "closure":
          closures[declaration.name.text] = ast.Closure(declaration.value)
          environment.del(declaration.name.text)
          slots.del(declaration.name.text)
          continue
        let expected =
          if typed.hasKey(cast[pointer](statement)): semantic(typed[cast[pointer](statement)], aliases)
          elif declaration.`type` != nil: lower(declaration.`type`, aliases)
          else: nil
        environment[declaration.name.text] = expression(declaration.value, expected)
        slots.del(declaration.name.text)
      of "destructure":
        let declaration = ast.Destructure(statement)
        let expected =
          if typed.hasKey(cast[pointer](statement)):
            semantic(typed[cast[pointer](statement)], aliases)
          else: lower(declaration.record, aliases)
        let source = expression(declaration.value, expected)
        for index, field in declaration.fields:
          if index >= declaration.bindings.len or
              not expected.fields.hasKey(field.text): continue
          let extracted = fresh(expected.fields[field.text])
          emit(Instruction(kind: Opcode.Extract, dest: extracted,
            val: source, field: field.text))
          environment[declaration.bindings[index].text] = extracted
          slots.del(declaration.bindings[index].text)
      of "mutable":
        let declaration = ast.Mutable(statement)
        if declaration.alignment > 0 or declaration.section.len > 0:
          raise newException(ValueError,
            "Storage placement applies only to file-level dynamic declarations")
        let expected =
          if typed.hasKey(cast[pointer](statement)): semantic(typed[cast[pointer](statement)], aliases)
          elif declaration.`type` != nil: lower(declaration.`type`, aliases)
          else: nil
        let value = expression(declaration.value, expected)
        let pointer = fresh(`Type`(kind: Shape.Ptr, elem: value.type))
        emit(Instruction(kind: Opcode.Alloc, op: "slot", dest: pointer, region: "scope"))
        emit(Instruction(kind: Opcode.Store, `ptr`: pointer, val: value))
        slots[declaration.name.text] = pointer
        environment.del(declaration.name.text)
      of "assignment":
        let assignment = ast.Assignment(statement)
        let pointer = place(assignment.target)
        emit(Instruction(kind: Opcode.Store, `ptr`: pointer,
          val: expression(assignment.value, pointer.type.elem), effects: @["write"]))
      of "give":
        let value = if ast.Give(statement).value == nil: Value() else: expression(ast.Give(statement).value, signature.ret)
        var teardown = false
        for scope in scopes:
          for entry in scope:
            if entry.statement.error: teardown = true
        if value.type != nil and value.type.kind == Shape.Failable and teardown:
          let failed = fresh(`Type`(kind: Shape.Bool))
          emit(Instruction(kind: Opcode.Extract, dest: failed, val: value, field: "failed"))
          cleanup(0, failed, 0)
        else:
          cleanup(0, status = -1)
        term = Instruction(kind: Opcode.Return, value: value, span: range)
        break
      of "action":
        let action = ast.Action(statement)
        discard expression(if action.value != nil: action.value else: ast.Call(tag: "call", callee: action.name, args: action.args, span: statement.span))
      of "defer":
        scopes[^1].add(Cleanup(statement: ast.`Defer`(statement),
          values: snapshot(environment), storage: snapshot(slots)))
      of "machine": discard expression(statement)
      of "native": emit(Instruction(kind: Opcode.Native, code: ast.Native(statement).code, field: "@" & ast.Native(statement).substrate, effects: @["unknown"]))
      of "eval": statements(ast.Evaluation(statement).body.stmts)
      of "unreachable-statement":
        term = Instruction(kind: Opcode.Panic, msg: "unreachable")
        break
      of "alias", "function", "extern-function", "use", "c-import", "test": discard
      else: raise newException(ValueError, "lowering for statement '" & statement.tag & "' is not implemented")
    if term == nil: cleanup(scopes.high, status = -1)
    scopes.setLen(scopes.len - 1)
    cleanupLimits.setLen(cleanupLimits.len - 1)
    environment = outer
    slots = saved
  proc cleanup(first: int; failed: Value = Value(); status = -1) =
    if first < 0 or first >= scopes.len: return
    let available = snapshot(environment)
    let occupied = snapshot(slots)
    for cursor in countdown(scopes.high, first):
      for offset in countdown(min(scopes[cursor].high, cleanupLimits[cursor]), 0):
        let entry = scopes[cursor][offset]
        if entry.statement.error and status < 0: continue
        let previousLimit = cleanupLimits[cursor]
        cleanupLimits[cursor] = offset - 1
        var ending = ""
        if entry.statement.error and status == 0:
          inc serial
          let yes = "cleanup_" & $serial
          ending = "cleaned_" & $serial
          finish(Instruction(kind: Opcode.Cjump, cond: failed,
            yes: yes, no: ending))
          begin(yes)
        environment = snapshot(entry.values)
        slots = snapshot(entry.storage)
        if entry.statement.body.tag == "block":
          statements(ast.Block(entry.statement.body).stmts)
        else:
          discard expression(ast.Expression(entry.statement.body))
        if term != nil:
          raise newException(ValueError, "Cleanup cannot leave its enclosing scope")
        cleanupLimits[cursor] = previousLimit
        if ending.len > 0:
          finish(Instruction(kind: Opcode.Jump, label: ending))
          begin(ending)
    environment = available
    slots = occupied
  proc propagate(value: Value): Value =
    if value.type == nil or value.type.kind != Shape.Failable:
      raise newException(ValueError, "try needs a failable value")
    inc serial
    let failure = "error_" & $serial
    let success = "value_" & $serial
    let failed = fresh(`Type`(kind: Shape.Bool))
    emit(Instruction(kind: Opcode.Extract, dest: failed, val: value, field: "failed"))
    finish(Instruction(kind: Opcode.Cjump, cond: failed,
      yes: failure, no: success))
    begin(failure)
    cleanup(0, status = 1)
    emit(Instruction(kind: Opcode.Try, expr: value))
    finish(Instruction(kind: Opcode.Panic, msg: "unreachable successful propagation"))
    begin(success)
    let dest = fresh(value.type.elem)
    emit(Instruction(kind: Opcode.Extract, dest: dest, val: value, field: "value"))
    dest
  if routine.guard != nil:
    inc serial
    let accepted = "guard_" & $serial
    let rejected = "guard_failed_" & $serial
    let condition = expression(routine.guard)
    finish(Instruction(kind: Opcode.Cjump, cond: condition,
      yes: accepted, no: rejected))
    begin(rejected)
    finish(Instruction(kind: Opcode.Panic,
      msg: "FunctionGuard: " & routine.dispatch))
    begin(accepted)
  statements(routine.body.stmts)
  if term == nil: term = Instruction(kind: Opcode.Return)
  finish(term)
  result = node.Function(name: if routine.name.text == "start": "main" else: routine.name.text,
    public: routine.public, line: routine.span.line, abi: routine.abi,
    attributes: routine.attributes, generics: routine.generics.mapIt(it.name.text),
    params: params, ret: signature.ret, blocks: blocks)

proc lower*(program: ast.Program; typed: Table[pointer, semantic.Type] = initTable[pointer, semantic.Type]()): Module =
  if program == nil or program.units.len == 0: raise newException(ValueError, "cannot lower an empty program")
  var aliases = initTable[string, `Type`]()
  var declarations: seq[Definition]
  for unit in program.units:
    for statement in unit.body.stmts:
      if statement.tag == "alias": aliases[ast.Alias(statement).name.text] = `Type`(kind: Shape.Struct, name: ast.Alias(statement).name.text)
  for unit in program.units:
    for statement in unit.body.stmts:
      if statement.tag == "alias":
        let alias = ast.Alias(statement)
        let value = alias(alias, aliases, typed)
        value.name = alias.name.text
        let placeholder = aliases[alias.name.text]
        placeholder[] = value[]
        if alias.generics.len == 0: declarations.add(Definition(name: alias.name.text, `type`: placeholder))
  var constants = initTable[string, ast.Constant]()
  var bindings = initTable[string, ast.Expression]()
  for unit in program.units:
    for statement in unit.body.stmts:
      if statement.tag == "constant":
        let declaration = ast.Constant(statement)
        constants[declaration.name.text] = declaration
        bindings[declaration.name.text] = declaration.value
  var signatures = initTable[string, `Type`]()
  var symbols = initTable[string, string]()
  var externs: seq[Extern]
  for unit in program.units:
    for statement in unit.body.stmts:
      if statement.tag == "function":
        let function = ast.Function(statement)
        let checked = typed.getOrDefault(cast[pointer](statement))
        var params: seq[`Type`]
        if checked != nil and checked.kind == "function":
          for parameter in checked.params: params.add(semantic(parameter, aliases))
        else:
          for parameter in function.params: params.add(if typed.hasKey(cast[pointer](parameter)): semantic(typed[cast[pointer](parameter)], aliases) else: lower(parameter.type, aliases))
        let ret = if checked != nil and checked.kind == "function": semantic(checked.ret, aliases) elif function.returns == nil: `Type`(kind: Shape.Void) else: lower(function.returns, aliases)
        signatures[function.name.text] = `Type`(kind: Shape.Function, params: params,
          ret: ret, abi: function.abi, attributes: function.generics.mapIt(it.name.text))
      elif statement.tag == "extern-function":
        let function = ast.External(statement); var params: seq[`Type`]
        for parameter in function.params: params.add(lower(parameter.type, aliases))
        let ret = lower(function.returns, aliases)
        signatures[function.name.text] = `Type`(kind: Shape.Function, params: params,
          ret: ret, abi: function.abi, attributes: function.generics.mapIt(it.name.text))
        var symbol = function.symbol
        if function.native.code.len > 0:
          symbol = "foo_escape_"
          for item in function.name.text: symbol.add(toHex(item.ord, 2).toLowerAscii)
        symbols[function.name.text] = symbol
        externs.add(Extern(name: function.name.text, symbol: symbol, abi: function.abi,
          params: params, ret: ret, generics: function.generics.mapIt(it.name.text)))
  var storage: seq[Storage]
  for unit in program.units:
    for statement in unit.body.stmts:
      if statement.tag != "mutable": continue
      let declaration = ast.Mutable(statement)
      let evaluated = eval.evaluate(declaration.value, bindings)
      let checked = typed.getOrDefault(cast[pointer](statement))
      let typ =
        if checked != nil: semantic(checked, aliases)
        elif declaration.type != nil: lower(declaration.type, aliases)
        elif evaluated.tag == "integer": `Type`(kind: Shape.Int, width: 64)
        elif evaluated.tag == "decimal": `Type`(kind: Shape.Float, width: 64)
        elif evaluated.tag in ["text", "newline"]: `Type`(kind: Shape.Slice, constant: true, elem: `Type`(kind: Shape.Uint, width: 8))
        else: `Type`(kind: Shape.Bool)
      var value: Value
      if evaluated.tag in ["integer", "decimal", "text", "character", "true", "false", "nothing", "null", "newline"]:
        value = literal(evaluated, typ)
      else:
        raise newException(ValueError, "File value '" & declaration.name.text & "' needs a scalar compile-time initializer")
      storage.add(Storage(name: declaration.name.text, public: declaration.public,
        value: value, alignment: declaration.alignment,
        section: declaration.section))
  var funcs: seq[node.Function]
  for unit in program.units:
    for statement in unit.body.stmts:
      if statement.tag == "function":
        funcs.add(function(ast.Function(statement), signatures, aliases,
          constants, bindings, storage, symbols, typed, unit.file))
  result = Module(name: program.units[0].name.text, version: 1, stage: "@foo",
    package: program.units[0].name.text, path: program.units[0].file,
    requires: "base", types: declarations, externs: externs, funcs: funcs,
    storage: storage, regions: @[], traces: @[], native: @[], residue: @[])
  for declaration in constants.values:
    if declaration.evaluated:
      result.residue.add(Residue(id: "eval" & $result.residue.len,
        operation: "eval", state: "resolved", payload: declaration.name.text))
  for function in result.funcs:
    let scope = function.name & ".scope"
    result.regions.add(Region(id: scope, kind: "scope"))
    var deferred = function.blocks
    var panics: seq[node.Block]
    var position = 0
    while position < deferred.len:
      let section = deferred[position]
      inc position
      for instruction in section.instrs:
        if instruction.fallback != nil: deferred.add(instruction.fallback)
        deferred.add(instruction.fallbackBlocks)
        if instruction.func.len > 0:
          for declaration in result.externs:
            if declaration.name != instruction.func: continue
            if declaration.abi == "runtime.atomic":
              instruction.effects = @["read", "write", "synchronize"]
              instruction.op = "atomic"
            elif declaration.abi in ["runtime", "runtime.thread", "runtime.task"]:
              instruction.effects = @["read", "write", "synchronize"]
              instruction.op = "thread"
            elif declaration.abi == "runtime.memory" and declaration.symbol == "copy":
              instruction.effects = @["read", "write", "synchronize"]
              instruction.op = "copy"
        if instruction.region == "scope": instruction.region = scope
        if instruction.kind in {Opcode.Try, Opcode.Trace}:
          instruction.trace = function.name & ".trace"
          if not result.traces.anyIt(it.id == instruction.trace):
            result.traces.add(Trace(id: instruction.trace, `function`: function.name))
        if instruction.kind == Opcode.Native and instruction.op notin ["machine:align", "machine:system"] and
            not instruction.op.startsWith("machine:register:"):
          let id = "native" & $result.native.len
          result.native.add(Contract(id: id,
            stage: if instruction.field.len > 0: instruction.field else: "@foo",
            code: instruction.code,
            abi: if instruction.op.startsWith("machine:"): instruction.op else: "foo:1",
            effects: @["unknown"]))
          instruction.symbol = id
        let numeric = if instruction.dest.type != nil and instruction.dest.type.kind == Shape.Vector: instruction.dest.type.elem else: instruction.dest.type
        if instruction.kind in {Opcode.Add, Opcode.Sub, Opcode.Mul,
            Opcode.Div, Opcode.Remainder, Opcode.Index} and
            (numeric == nil or numeric.kind != Shape.Float):
          let target = "panic_" & $panics.len
          instruction.panic = target
          panics.add(node.Block(label: target, instrs: @[], term: Instruction(
            kind: Opcode.Panic, msg: "Checked " & operations[instruction.kind.ord] & " failed")))
        if instruction.kind in {Opcode.Eval, Opcode.Reflect, Opcode.Embed}:
          let id = "residue" & $result.residue.len
          let operation = if instruction.kind == Opcode.Embed: "embed" elif instruction.kind == Opcode.Reflect: "reflect" else: "eval"
          let payload = if instruction.path.len > 0: instruction.path elif instruction.evaluation.len > 0: instruction.evaluation elif instruction.argument != nil: instruction.argument.name else: ""
          result.residue.add(Residue(id: id, operation: operation,
            state: "pending", payload: payload))
          instruction.symbol = id
    function.blocks.add(panics)
    var reachable = initHashSet[string]()
    var queue = if function.blocks.len > 0: @[function.blocks[0].label] else: @[]
    while queue.len > 0:
      let current = queue.pop()
      if current in reachable: continue
      reachable.incl(current)
      for section in function.blocks:
        if section.label != current: continue
        for instruction in section.instrs & @[section.term]:
          if instruction == nil: continue
          for target in [instruction.label, instruction.yes,
              instruction.no, instruction.panic]:
            if target.len > 0: queue.add(target)
    function.blocks = function.blocks.filterIt(it.label in reachable)
    for section in function.blocks:
      for instruction in section.instrs:
        if instruction.kind == Opcode.Phi:
          instruction.blocks = instruction.blocks.filterIt(it.label in reachable)
  for unit in program.units:
    for statement in unit.body.stmts:
      if statement.tag == "native":
        let native = ast.Native(statement)
        result.native.add(Contract(id: "native" & $result.native.len,
          stage: "@" & native.substrate, code: native.code, abi: "foo:1", effects: @["unknown"]))
      elif statement.tag == "extern-function" and ast.External(statement).native.code.len > 0:
        let external = ast.External(statement)
        var parameters = newJArray()
        for parameter in external.params: parameters.add(%parameter.name.text)
        let code = $(%* {"format": "foo.native", "version": 1,
          "parameters": parameters, "source": external.native.code})
        var symbol = "foo_escape_"
        for item in external.name.text: symbol.add(toHex(item.ord, 2).toLowerAscii)
        result.native.add(Contract(id: symbol, stage: "@" & external.native.substrate,
          code: code, abi: "foo.native:1", effects: @["unknown"]))
  discard graphics.apply(result)
  discard seal(result)
