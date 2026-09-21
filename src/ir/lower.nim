import std/[json, sequtils, sets, strutils, tables, unicode]
import ../ast/node as ast
import ../types/type as semantic
import ./[kind, node, valid, eval]

type Type = node.Type

proc lowerType(node: ast.`Type`; aliases: Table[string, `Type`]): `Type`

proc lowerType(node: ast.`Type`; aliases: Table[string, `Type`]): `Type` =
  if node == nil: return `Type`(kind: TypeKind.Void)
  case node.tag
  of "primitive":
    let primitive = ast.Primitive(node)
    if primitive.name == "integer": return `Type`(kind: TypeKind.Int, width: if primitive.width.len > 0: parseInt(primitive.width) else: 64)
    if primitive.name in ["unsigned", "byte", "character"]: return `Type`(kind: TypeKind.Uint, width: if primitive.width.len > 0: parseInt(primitive.width) elif primitive.name == "byte": 8 elif primitive.name == "character": 32 else: 64)
    if primitive.name == "decimal": return `Type`(kind: TypeKind.Float, width: if primitive.width.len > 0: parseInt(primitive.width) else: 64)
    if primitive.name == "boolean": return `Type`(kind: TypeKind.Bool)
    if primitive.name == "nothing": return `Type`(kind: TypeKind.Void)
    if primitive.name == "Error": return `Type`(kind: TypeKind.Error)
    if primitive.name == "text": return `Type`(kind: TypeKind.Slice, constant: true, elem: `Type`(kind: TypeKind.Uint, width: 8))
    `Type`(kind: TypeKind.Void)
  of "pointer": `Type`(kind: TypeKind.Ptr, elem: lowerType(ast.Pointer(node).elem, aliases))
  of "array", "sequence":
    let sequence = ast.Sequence(node)
    `Type`(kind: TypeKind.Slice, elem: lowerType(sequence.elem, aliases), constant: node.tag == "sequence" and sequence.constant)
  of "optional": `Type`(kind: TypeKind.Optional, elem: lowerType(ast.Optional(node).elem, aliases))
  of "error": `Type`(kind: TypeKind.Fallible, elem: lowerType(ast.Error(node).elem, aliases))
  of "vector": `Type`(kind: TypeKind.Vector, width: parseInt(ast.Vector(node).length), elem: lowerType(ast.Vector(node).elem, aliases))
  of "function-type":
    let functionType = ast.FunctionType(node)
    var params: seq[`Type`]
    for parameter in functionType.params: params.add(lowerType(parameter, aliases))
    `Type`(kind: TypeKind.Function, params: params, ret: lowerType(functionType.ret, aliases), abi: functionType.abi)
  of "named": aliases.getOrDefault(ast.Named(node).name.text, `Type`(kind: TypeKind.Struct, name: ast.Named(node).name.text))
  of "generic-inst": aliases.getOrDefault(ast.GenericInst(node).name.text, `Type`(kind: TypeKind.Struct, name: ast.GenericInst(node).name.text))
  else: `Type`(kind: TypeKind.Void)

proc lowerAlias(alias: ast.Alias; aliases: Table[string, `Type`]): `Type` =
  if alias.body == nil: return `Type`(kind: TypeKind.Opaque, name: alias.name.text)
  case alias.body.tag
  of "record":
    let record = ast.Record(alias.body)
    var fields = initOrderedTable[string, `Type`]()
    var fieldAttrs = initTable[string, seq[string]]()
    for field in record.fields:
      fields[field.name.text] = lowerType(field.type, aliases)
      if field.attributes.len > 0:
        fieldAttrs[field.name.text] = field.attributes
        if "volatile" in field.attributes: fields[field.name.text].volatile = true
    `Type`(kind: if record.layout == "packed": TypeKind.PackedStruct elif record.layout == "c": TypeKind.ExternStruct else: TypeKind.Struct,
      name: alias.name.text, fields: fields, fieldAttrs: fieldAttrs)
  of "union":
    var fields = initOrderedTable[string, `Type`]()
    var fieldAttrs = initTable[string, seq[string]]()
    for field in ast.Union(alias.body).fields:
      fields[field.name.text] = lowerType(field.type, aliases)
      if field.attributes.len > 0:
        fieldAttrs[field.name.text] = field.attributes
        if "volatile" in field.attributes: fields[field.name.text].volatile = true
    `Type`(kind: TypeKind.ExternUnion, name: alias.name.text, fields: fields, fieldAttrs: fieldAttrs)
  of "choice":
    var variants = initOrderedTable[string, `Type`]()
    for variant in ast.Choice(alias.body).variants: variants[variant.name.text] = if variant.payload == nil: nil else: lowerType(variant.payload, aliases)
    `Type`(kind: TypeKind.TaggedUnion, name: alias.name.text, variants: variants)
  of "opaque": `Type`(kind: TypeKind.Opaque, name: alias.name.text)
  else: lowerType(alias.body, aliases)

proc semanticTypeImpl(value: semantic.Type; aliases: Table[string, `Type`];
    seen: var Table[pointer, `Type`]): `Type` =
  if value == nil: return `Type`(kind: TypeKind.Void)
  let identity = cast[pointer](value)
  if seen.hasKey(identity): return seen[identity]
  case value.kind
  of "primitive": return lowerType(ast.Primitive(tag: "primitive",
    name: value.name, width: if value.width > 0: $value.width else: ""), aliases)
  of "literal": return `Type`(kind: TypeKind.Int, width: 64)
  of "pointer": return `Type`(kind: TypeKind.Ptr,
    elem: semanticTypeImpl(value.elem, aliases, seen))
  of "array", "sequence": return `Type`(kind: TypeKind.Slice,
    elem: semanticTypeImpl(value.elem, aliases, seen), constant: value.constant)
  of "optional": return `Type`(kind: TypeKind.Optional,
    elem: semanticTypeImpl(value.elem, aliases, seen))
  of "error": return `Type`(kind: TypeKind.Fallible,
    elem: semanticTypeImpl(value.elem, aliases, seen))
  of "vector": return `Type`(kind: TypeKind.Vector, width: value.length,
    elem: semanticTypeImpl(value.elem, aliases, seen))
  of "function":
    var params: seq[`Type`]
    for parameter in value.params:
      params.add(semanticTypeImpl(parameter, aliases, seen))
    return `Type`(kind: TypeKind.Function, params: params,
      ret: semanticTypeImpl(value.ret, aliases, seen), abi: value.abi)
  of "record", "choice":
    if aliases.hasKey(value.name): return aliases[value.name]
    let base = value.name.split('[')[0]
    let kind = if value.kind == "choice": TypeKind.TaggedUnion
      elif aliases.hasKey(base): aliases[base].kind else: TypeKind.Struct
    result = `Type`(kind: kind, name: value.name,
      fields: initOrderedTable[string, `Type`](),
      variants: initOrderedTable[string, `Type`]())
    seen[identity] = result
    for argument in value.arguments:
      result.params.add(semanticTypeImpl(argument, aliases, seen))
    if value.kind == "record":
      for name, field in value.fields:
        result.fields[name] = semanticTypeImpl(field, aliases, seen)
    else:
      for name, variant in value.variants:
        result.variants[name] = if variant == nil: nil
          else: semanticTypeImpl(variant, aliases, seen)
  of "union", "named", "opaque": return aliases.getOrDefault(value.name,
    `Type`(kind: if value.kind == "opaque": TypeKind.Opaque else: TypeKind.Struct,
      name: value.name))
  else: return `Type`(kind: TypeKind.Void)

proc semanticType(value: semantic.Type; aliases: Table[string, `Type`]): `Type` =
  var seen = initTable[pointer, `Type`]()
  semanticTypeImpl(value, aliases, seen)

proc literalValue(node: ast.Expression; typ: `Type`): Value =
  case node.tag
  of "true", "false": Value(kind: ValueKind.Const, name: node.tag, `type`: typ)
  of "nothing": Value(kind: ValueKind.Const, name: if typ != nil and typ.kind == TypeKind.Optional: "null" else: "{}", `type`: typ)
  of "text", "newline":
    let text = if node.tag == "newline": "\n" else: ast.Text(node).value
    var data = newSeq[byte](text.len)
    for index, item in text: data[index] = byte(item.ord)
    Value(kind: ValueKind.Const, name: quoted(data), `type`: typ)
  of "character": Value(kind: ValueKind.Const, name: $ast.Character(node).value.runeAt(0).int, `type`: typ)
  of "decimal": Value(kind: ValueKind.Const, name: ast.Decimal(node).value, `type`: typ)
  of "integer": Value(kind: ValueKind.Const, name: ast.Integer(node).value, `type`: typ)
  else: Value(kind: ValueKind.Const, name: "undefined", `type`: typ)

proc copyType(value: `Type`; attributes: seq[string]): `Type` =
  if value == nil: return nil
  `Type`(kind: value.kind, name: value.name, elem: value.elem, width: value.width,
    fields: value.fields, fieldAttrs: value.fieldAttrs, variants: value.variants,
    params: value.params, ret: value.ret, abi: value.abi, attributes: attributes,
    volatile: value.volatile, constant: value.constant)

proc copyLabel(value: string): string =
  result = newString(value.len)
  for index, character in value: result[index] = character

proc lowerFunction(functionNode: ast.Function; signatures: Table[string, `Type`];
    aliases: Table[string, `Type`]; constants: Table[string, ast.Constant];
    bindings: Table[string, ast.Expression]; storage: seq[Storage];
    symbols: Table[string, string]; typed: Table[pointer, semantic.Type]): node.Function =
  let signature = signatures[functionNode.name.text]
  var params: seq[Value]
  for index, parameter in functionNode.params:
    params.add(Value(kind: ValueKind.Reg, name: parameter.name.text, `type`: signature.params[index]))
  var environment = initTable[string, Value]()
  var slots = initTable[string, Value]()
  for parameter in params: environment[parameter.name] = parameter
  for item in storage:
    if not environment.hasKey(item.name):
      slots[item.name] = Value(kind: ValueKind.Global, name: item.name,
        `type`: `Type`(kind: TypeKind.Ptr, elem: item.value.type))
  var pending = initHashSet[string]()
  var instructions: seq[Instruction]
  var serial = 0
  proc fresh(typ: `Type`): Value =
    inc serial
    Value(kind: ValueKind.Reg, name: "tmp_" & $serial, `type`: typ)
  proc emit(instruction: Instruction) = instructions.add(instruction)
  proc adapt(value: Value; expected: `Type`): Value =
    if expected == nil or value.type == nil: return value
    let numeric = {TypeKind.Int, TypeKind.Uint, TypeKind.Float}
    if value.kind == ValueKind.Const and value.type.kind in numeric and
        expected.kind in numeric:
      result = value
      result.type = expected
      return
    let widen = value.type.kind in numeric and expected.kind in numeric and
      (value.type.kind != expected.kind or value.type.width != expected.width)
    let wrap = expected.kind in {TypeKind.Optional, TypeKind.Fallible} and
      value.type.kind != expected.kind
    let view = expected.kind == TypeKind.Slice and value.type.kind == TypeKind.Slice and
      expected.constant != value.type.constant
    if widen or wrap or view:
      let dest = fresh(expected)
      emit(Instruction(kind: InstrKind.Convert, dest: dest, val: value))
      return dest
    value
  var blocks: seq[node.Block]
  var label = "entry"
  var term: Instruction
  var loops: seq[tuple[head: string, exit: string, depth: int]]
  proc finish(ending: Instruction) =
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
  var cleaning = false
  proc snapshot(source: Table[string, Value]): Table[string, Value] =
    result = initTable[string, Value]()
    for key, value in source: result[key] = value
  proc expression(node: ast.Expression; expected: `Type` = nil): Value
  proc statements(body: seq[ast.Statement])
  proc cleanup(first: int; failed: Value = Value(); status = -1)
  proc propagate(value: Value): Value
  proc hasCleanups(): bool =
    for scope in scopes:
      if scope.len > 0: return true
  proc place(value: ast.Expression): Value
  proc place(value: ast.Expression): Value =
    if value != nil and value.tag == "name" and slots.hasKey(ast.Name(value).text):
      return slots[ast.Name(value).text]
    if value != nil and value.tag == "index":
      let indexed = ast.Index(value)
      let source = expression(indexed.object)
      let dest = fresh(`Type`(kind: TypeKind.Ptr, elem: source.type.elem))
      emit(Instruction(kind: InstrKind.Index, op: "address", dest: dest,
        val: source, val2: expression(indexed.index)))
      return dest
    if value != nil and value.tag == "field":
      let field = ast.Field(value)
      let pointer = place(field.object)
      if pointer.type == nil or pointer.type.elem == nil or
          not pointer.type.elem.fields.hasKey(field.field.text):
        raise newException(ValueError, "Unknown mutable field '" & field.field.text & "'")
      let dest = fresh(`Type`(kind: TypeKind.Ptr,
        elem: pointer.type.elem.fields[field.field.text]))
      emit(Instruction(kind: InstrKind.Extract, op: "address", dest: dest,
        `ptr`: pointer, field: field.field.text))
      return dest
    raise newException(ValueError, "Assignment requires a mutable place")
  proc expression(node: ast.Expression; expected: `Type` = nil): Value =
    if node == nil: return Value(kind: ValueKind.Const, name: "null", `type`: expected)
    case node.tag
    of "integer", "decimal", "text", "character", "true", "false", "nothing", "newline":
      let inferred =
        if node.tag == "integer": `Type`(kind: TypeKind.Int, width: 64)
        elif node.tag == "decimal": `Type`(kind: TypeKind.Float, width: 64)
        elif node.tag in ["true", "false"]: `Type`(kind: TypeKind.Bool)
        elif node.tag == "character": `Type`(kind: TypeKind.Uint, width: 32)
        elif node.tag in ["text", "newline"]: `Type`(kind: TypeKind.Slice, constant: true, elem: `Type`(kind: TypeKind.Uint, width: 8))
        else: `Type`(kind: TypeKind.Void)
      let target =
        if node.tag == "nothing":
          if expected != nil and expected.kind == TypeKind.Fallible: expected.elem
          elif expected != nil: expected
          else: inferred
        elif expected != nil and expected.kind in {TypeKind.Optional, TypeKind.Fallible}:
          expected.elem
        elif expected != nil: expected
        else: inferred
      return literalValue(node, target)
    of "uninitialized": return Value(kind: ValueKind.Const, name: "undefined", `type`: if expected != nil: expected else: `Type`(kind: TypeKind.Void))
    of "quantity":
      let quantity = ast.Quantity(node)
      let scale = case quantity.unit
        of "kilobytes": 1024'i64
        of "megabytes": 1024'i64 * 1024
        of "gigabytes": 1024'i64 * 1024 * 1024
        of "terabytes": 1024'i64 * 1024 * 1024 * 1024
        of "seconds": 1_000_000_000'i64
        of "milliseconds": 1_000_000'i64
        of "microseconds": 1_000'i64
        else: 1'i64
      return Value(kind: ValueKind.Const, name: $(parseBiggestInt(quantity.value) * scale),
        `type`: `Type`(kind: TypeKind.Int, width: 64))
    of "name":
      if slots.hasKey(ast.Name(node).text):
        let pointer = slots[ast.Name(node).text]
        let dest = fresh(pointer.type.elem)
        emit(Instruction(kind: InstrKind.Load, dest: dest, `ptr`: pointer))
        return adapt(dest, expected)
      if environment.hasKey(ast.Name(node).text):
        return adapt(environment[ast.Name(node).text], expected)
      if constants.hasKey(ast.Name(node).text):
        let name = ast.Name(node).text
        if name in pending: raise newException(ValueError, "Circular constant initializer '" & name & "'")
        pending.incl(name)
        let declaration = constants[name]
        let value = expression(eval.evaluate(declaration.value, bindings),
          if declaration.type != nil: lowerType(declaration.type, aliases) else: expected)
        pending.excl(name)
        return value
      for alias in aliases.values:
        if alias.kind == TypeKind.TaggedUnion and alias.variants.hasKey(ast.Name(node).text):
          let dest = fresh(alias)
          emit(Instruction(kind: InstrKind.Construct, dest: dest,
            field: ast.Name(node).text, args: @[]))
          return dest
      return Value(kind: ValueKind.Global, name: ast.Name(node).text, `type`: signatures.getOrDefault(ast.Name(node).text, `Type`(kind: TypeKind.Void)))
    of "group": return expression(ast.Group(node).expr, expected)
    of "index", "field":
      if node.tag == "field":
        let field = ast.Field(node)
        if field.object.tag == "name" and ast.Name(field.object).text == "Error":
          return Value(kind: ValueKind.Const, name: field.field.text, `type`: `Type`(kind: TypeKind.Error))
      let source = if node.tag == "index": expression(ast.Index(node).object) else: expression(ast.Field(node).object)
      var projected: `Type`
      let dest = if node.tag == "index":
        projected = source.type.elem
        fresh(projected)
      else:
        let field = ast.Field(node).field.text
        if source.type != nil and source.type.fields.hasKey(field): projected = source.type.fields[field]
        fresh(if projected != nil: projected else: `Type`(kind: TypeKind.Void))
      if node.tag == "index":
        emit(Instruction(kind: InstrKind.Index, dest: dest, val: source,
          val2: expression(ast.Index(node).index)))
      else:
        emit(Instruction(kind: InstrKind.Extract, dest: dest, val: source,
          field: ast.Field(node).field.text))
      return dest
    of "error-chain":
      let chain = ast.ErrorChain(node)
      let value = expression(chain.expr, expected)
      emit(Instruction(kind: InstrKind.Trace, expr: value,
        val: expression(chain.context), trace: functionNode.name.text & ".trace", effects: @["trace"]))
      return value
    of "embed":
      let embedded = ast.Embed(node)
      let target = if expected != nil: expected elif embedded.type != nil: lowerType(embedded.type, aliases) else: `Type`(kind: TypeKind.Slice, constant: true, elem: `Type`(kind: TypeKind.Uint, width: 8))
      let dest = fresh(target)
      emit(Instruction(kind: InstrKind.Embed, dest: dest, path: embedded.path))
      return dest
    of "reflect":
      let reflected = ast.Reflect(node)
      let dest = fresh(if expected != nil: expected else: `Type`(kind: TypeKind.Opaque, name: "Description"))
      emit(Instruction(kind: InstrKind.Reflect, dest: dest, typeArg: lowerType(reflected.type, aliases)))
      return dest
    of "unreachable":
      term = Instruction(kind: InstrKind.Panic, msg: "unreachable")
      return Value(kind: ValueKind.Const, name: "{}", `type`: if expected != nil: expected else: `Type`(kind: TypeKind.Void))
    of "binary":
      let binary = ast.Binary(node)
      if binary.op in ["and", "or"]:
        let left = expression(binary.left)
        let origin = copyLabel(label)
        inc serial
        let rightLabel = "right_" & $serial
        let ending = "logic_" & $serial
        finish(Instruction(kind: InstrKind.Cjump, cond: left,
          trueLabel: if binary.op == "and": rightLabel else: ending,
          falseLabel: if binary.op == "and": ending else: rightLabel))
        begin(rightLabel)
        let right = expression(binary.right)
        let predecessor = copyLabel(label)
        finish(Instruction(kind: InstrKind.Jump, label: ending))
        begin(ending)
        let dest = fresh(`Type`(kind: TypeKind.Bool))
        emit(Instruction(kind: InstrKind.Phi, dest: dest,
          blocks: @[(label: origin, value: left), (label: predecessor, value: right)]))
        return dest
      if binary.op == "catch":
        let left = expression(binary.left)
        if left.type == nil or left.type.kind != TypeKind.Fallible:
          raise newException(ValueError, "catch needs a fallible value")
        inc serial
        let errorLabel = "catch_" & $serial
        let success = "success_" & $serial
        let ending = "result_" & $serial
        let failed = fresh(`Type`(kind: TypeKind.Bool))
        emit(Instruction(kind: InstrKind.Extract, dest: failed, val: left, field: "failed"))
        finish(Instruction(kind: InstrKind.Cjump, cond: failed, trueLabel: errorLabel, falseLabel: success))
        begin(errorLabel)
        let fallback = expression(binary.right, left.type.elem)
        let predecessor = copyLabel(label)
        finish(Instruction(kind: InstrKind.Jump, label: ending))
        begin(success)
        let value = fresh(left.type.elem)
        emit(Instruction(kind: InstrKind.Extract, dest: value, val: left, field: "value"))
        finish(Instruction(kind: InstrKind.Jump, label: ending))
        begin(ending)
        if left.type.elem.kind == TypeKind.Void:
          return Value(kind: ValueKind.Const, name: "{}", `type`: left.type.elem)
        let dest = fresh(left.type.elem)
        emit(Instruction(kind: InstrKind.Phi, dest: dest,
          blocks: @[(label: predecessor, value: fallback), (label: success, value: value)]))
        return dest
      let left = expression(binary.left, expected); let right = expression(binary.right, left.type)
      let comparison = binary.op in ["equals", "does not equal", "is greater than", "is less than", "is at least", "is at most"]
      let resultType = if comparison and left.type.kind == TypeKind.Vector: `Type`(kind: TypeKind.Vector, width: left.type.width, elem: `Type`(kind: TypeKind.Bool)) elif comparison: `Type`(kind: TypeKind.Bool) else: left.type
      let dest = fresh(resultType)
      let operation = if comparison: InstrKind.Compare elif binary.op in ["plus", "+"]: InstrKind.Add elif binary.op in ["minus", "-"]: InstrKind.Sub elif binary.op in ["times", "*"]: InstrKind.Mul elif binary.op == "remainder": InstrKind.Remainder elif binary.op == "divided by": InstrKind.Div else: raise newException(ValueError, "lowering for binary operator '" & binary.op & "' is not implemented")
      emit(Instruction(kind: operation, dest: dest, op: binary.op, val: left, val2: right)); return dest
    of "unary":
      let unary = ast.Unary(node); let operand = expression(unary.operand)
      if unary.op == "try":
        if operand.type == nil or operand.type.kind != TypeKind.Fallible:
          raise newException(ValueError, "try needs a fallible value")
        if hasCleanups(): return propagate(operand)
        let dest = fresh(operand.type.elem)
        emit(Instruction(kind: InstrKind.Try, dest: dest, expr: operand))
        return dest
      let dest = fresh(if unary.op == "not": `Type`(kind: TypeKind.Bool) else: operand.type)
      emit(Instruction(kind: if unary.op == "not": InstrKind.Not else: InstrKind.Convert, dest: dest, val: operand)); return dest
    of "call":
      let call = ast.Call(node)
      if call.callee.tag == "name":
        let name = ast.Name(call.callee).text
        if name == "fail" and not signatures.hasKey(name):
          let target = if expected != nil and expected.kind == TypeKind.Fallible: expected else: `Type`(kind: TypeKind.Fallible, elem: `Type`(kind: TypeKind.Void))
          let dest = fresh(target)
          emit(Instruction(kind: InstrKind.Construct, op: "error", dest: dest,
            args: @[expression(call.args[0], `Type`(kind: TypeKind.Error))]))
          return dest
        if aliases.hasKey(name) and aliases[name].kind in {TypeKind.Struct, TypeKind.PackedStruct, TypeKind.ExternStruct}:
          let checked = typed.getOrDefault(cast[pointer](node))
          let target =
            if checked != nil and checked.kind == "record": semanticType(checked, aliases)
            elif expected != nil and expected.fields.len > 0: expected
            else: aliases[name]
          var fields: seq[`Type`]
          for field in target.fields.values: fields.add(field)
          var args: seq[Value]
          for index, argument in call.args: args.add(expression(argument, if index < fields.len: fields[index] else: nil))
          let dest = fresh(target)
          emit(Instruction(kind: InstrKind.Construct, dest: dest, args: args))
          return dest
        for alias in aliases.values:
          if alias.kind == TypeKind.TaggedUnion and alias.variants.hasKey(name):
            let dest = fresh(alias)
            var args: seq[Value]
            if alias.variants[name] != nil:
              for argument in call.args: args.add(expression(argument, alias.variants[name]))
            emit(Instruction(kind: InstrKind.Construct, dest: dest, field: name, args: args))
            return dest
        if name in ["splat", "shuffle", "select", "reduce"]:
          if name == "splat":
            if expected == nil: raise newException(ValueError, "splat lowering needs an expected vector type")
            let dest = fresh(expected)
            emit(Instruction(kind: InstrKind.Splat, dest: dest, val: expression(call.args[0], expected.elem)))
            return dest
          let first = expression(call.args[0])
          if name == "reduce":
            let dest = fresh(first.type.elem)
            let operation = if call.args.len > 1 and call.args[1].tag == "text": ast.Text(call.args[1]).value else: "add"
            emit(Instruction(kind: InstrKind.Reduce, dest: dest, val: first, reduceOp: operation.capitalizeAscii))
            return dest
          if name == "shuffle":
            let second = expression(call.args[1], first.type)
            var mask: seq[int]
            for index in 2 ..< call.args.len: mask.add(if call.args[index].tag == "integer": parseInt(ast.Integer(call.args[index]).value) else: 0)
            let dest = fresh(`Type`(kind: TypeKind.Vector, width: mask.len, elem: first.type.elem))
            emit(Instruction(kind: InstrKind.Shuffle, dest: dest, val: first, val2: second, mask: mask))
            return dest
          let yes = expression(call.args[1])
          let no = expression(call.args[2], yes.type)
          let dest = fresh(yes.type)
          emit(Instruction(kind: InstrKind.Select, dest: dest, cond: first, val: yes, val2: no))
          return dest
        var sig: `Type`
        var indirect = Value()
        if signatures.hasKey(name): sig = signatures[name]
        elif environment.hasKey(name) and environment[name].type.kind == TypeKind.Function:
          indirect = environment[name]
          sig = indirect.type
        if sig != nil:
          var typeArgs: seq[`Type`]
          if sig.attributes.len > 0:
            var substitutions = initTable[string, `Type`]()
            proc infer(pattern, actual: `Type`) =
              if pattern == nil or actual == nil: return
              if pattern.name.len > 0 and pattern.name in sig.attributes:
                substitutions[pattern.name] = actual
              elif pattern.elem != nil and actual.elem != nil:
                infer(pattern.elem, actual.elem)
              elif pattern.fields.len > 0 and actual.fields.len > 0:
                for field, fieldType in pattern.fields:
                  if actual.fields.hasKey(field): infer(fieldType, actual.fields[field])
            for index, argument in call.args:
              if index < sig.params.len and typed.hasKey(cast[pointer](argument)):
                infer(sig.params[index], semanticType(typed[cast[pointer](argument)], aliases))
            for index, argument in call.types:
              if index < sig.attributes.len:
                substitutions[sig.attributes[index]] = if typed.hasKey(cast[pointer](argument)): semanticType(typed[cast[pointer](argument)], aliases) else: lowerType(argument, aliases)
            for parameter in sig.attributes:
              if not substitutions.hasKey(parameter):
                raise newException(ValueError, "Generic calls need fully inferred type arguments")
              typeArgs.add(substitutions[parameter])
            proc replaceType(value: `Type`): `Type` =
              if value == nil: return nil
              if value.name.len > 0 and substitutions.hasKey(value.name): return substitutions[value.name]
              result = copyType(value, value.attributes)
              if value.elem != nil: result.elem = replaceType(value.elem)
              if value.ret != nil: result.ret = replaceType(value.ret)
              result.params = @[]
              for parameter in value.params: result.params.add(replaceType(parameter))
              result.fields = initOrderedTable[string, `Type`]()
              for field, fieldType in value.fields: result.fields[field] = replaceType(fieldType)
              result.variants = initOrderedTable[string, `Type`]()
              for variant, variantType in value.variants:
                result.variants[variant] = if variantType == nil: nil else: replaceType(variantType)
            sig = replaceType(sig)
          var args: seq[Value]
          for index, argument in call.args: args.add(expression(argument, if index < sig.params.len: sig.params[index] else: nil))
          let dest = if sig.ret.kind == TypeKind.Void: Value() else: fresh(sig.ret)
          emit(Instruction(kind: InstrKind.Call, dest: dest,
            `func`: if indirect.name.len == 0: name else: "", callee: indirect,
            abi: sig.abi, symbol: symbols.getOrDefault(name), args: args, typeArgs: typeArgs))
          return if sig.ret.kind == TypeKind.Void: Value(kind: ValueKind.Const, name: "{}", `type`: sig.ret) else: dest
      let callee = expression(call.callee)
      if callee.type == nil or callee.type.kind != TypeKind.Function:
        raise newException(ValueError, "An indirect call needs a function value")
      var args: seq[Value]
      for index, argument in call.args: args.add(expression(argument, if index < callee.type.params.len: callee.type.params[index] else: nil))
      let dest = if callee.type.ret.kind == TypeKind.Void: Value() else: fresh(callee.type.ret)
      emit(Instruction(kind: InstrKind.Call, dest: dest, callee: callee, abi: callee.type.abi, args: args))
      return if callee.type.ret.kind == TypeKind.Void: Value(kind: ValueKind.Const, name: "{}", `type`: callee.type.ret) else: dest
    of "allocation":
      let allocation = ast.Allocation(node); let size = expression(allocation.size)
      let dest = fresh(if expected != nil: expected else: `Type`(kind: TypeKind.Fallible, elem: `Type`(kind: TypeKind.Slice, elem: `Type`(kind: TypeKind.Uint, width: 8))))
      let owner = if allocation.owner != nil: expression(allocation.owner) else: Value()
      emit(Instruction(kind: InstrKind.Allocate, dest: dest, val: size,
        target: owner, region: "scope", effects: @["allocate", "write"])); return dest
    of "machine":
      let machine = ast.Machine(node)
      let integer = `Type`(kind: TypeKind.Int, width: 64)
      let unsigned = `Type`(kind: TypeKind.Uint, width: 64)
      let unit = `Type`(kind: TypeKind.Void)
      if machine.operation == "atomic":
        let pointer = place(machine.target)
        let element = pointer.type.elem
        var atomicAttributes = element.attributes
        if "atomic" notin atomicAttributes: atomicAttributes.add("atomic")
        element.attributes = atomicAttributes
        let plain = copyType(element, @[])
        let dest = fresh(plain)
        emit(Instruction(kind: InstrKind.Atomic, op: "add", field: "seq_cst", `ptr`: pointer,
          val: expression(machine.value, plain), dest: dest,
          effects: @["read", "write", "synchronize", "machine"]))
        return Value(kind: ValueKind.Const, name: "void", `type`: unit)
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
      emit(Instruction(kind: InstrKind.Native,
        op: "machine:" & machine.operation & (if machine.register.len > 0: ":" & machine.register else: ""),
        field: "@c", args: args, dest: dest, effects: @["unknown", "machine"]))
      return if machine.operation == "system": dest else: Value(kind: ValueKind.Const, name: "void", `type`: unit)
    else: raise newException(ValueError, "lowering for expression '" & node.tag & "' is not implemented")
  proc statements(body: seq[ast.Statement]) =
    let outer = snapshot(environment)
    let saved = snapshot(slots)
    scopes.add(@[])
    for statement in body:
      case statement.tag
      of "unsafe":
        statements(ast.Unsafe(statement).body.stmts)
        if term != nil: break
      of "repeat":
        let repeated = ast.Repeat(statement)
        let condition = ast.Binary(tag: "binary", span: statement.span, op: "is less than",
          left: repeated.target, right: repeated.limit)
        statements(@[ast.Statement(ast.`While`(tag: "while", span: statement.span,
          cond: condition, body: repeated.body))])
        if term != nil: break
      of "for":
        let iteration = ast.`For`(statement)
        let iter = expression(iteration.iter)
        if iter.type == nil or iter.type.elem == nil:
          raise newException(ValueError, "for needs an iterable sequence")
        inc serial
        let suffix = $serial
        let number = `Type`(kind: TypeKind.Uint, width: 64)
        let counter = fresh(`Type`(kind: TypeKind.Ptr, elem: number))
        emit(Instruction(kind: InstrKind.Alloc, op: "slot", region: "scope", dest: counter))
        emit(Instruction(kind: InstrKind.Store, `ptr`: counter,
          val: Value(kind: ValueKind.Const, name: "0", `type`: number)))
        let head = "for_" & suffix
        let visit = "item_" & suffix
        let advance = "advance_" & suffix
        let ending = "end_" & suffix
        finish(Instruction(kind: InstrKind.Jump, label: head))
        begin(head)
        let index = fresh(number)
        let length = fresh(number)
        let condition = fresh(`Type`(kind: TypeKind.Bool))
        emit(Instruction(kind: InstrKind.Load, dest: index, `ptr`: counter))
        emit(Instruction(kind: InstrKind.Length, dest: length, val: iter))
        emit(Instruction(kind: InstrKind.Compare, dest: condition, op: "is less than",
          val: index, val2: length))
        finish(Instruction(kind: InstrKind.Cjump, cond: condition,
          trueLabel: visit, falseLabel: ending))
        begin(visit)
        let item = fresh(iter.type.elem)
        emit(Instruction(kind: InstrKind.Index, dest: item, val: iter, val2: index))
        let existed = environment.hasKey(iteration.bind.text)
        let previous = environment.getOrDefault(iteration.bind.text)
        environment[iteration.bind.text] = item
        loops.add((head: advance, exit: ending, depth: scopes.len))
        statements(iteration.body.stmts)
        discard loops.pop()
        if existed: environment[iteration.bind.text] = previous
        else: environment.del(iteration.bind.text)
        finish(if term != nil: term else: Instruction(kind: InstrKind.Jump, label: advance))
        begin(advance)
        let increment = fresh(number)
        emit(Instruction(kind: InstrKind.Add, dest: increment, val: index,
          val2: Value(kind: ValueKind.Const, name: "1", `type`: number)))
        emit(Instruction(kind: InstrKind.Store, `ptr`: counter, val: increment))
        finish(Instruction(kind: InstrKind.Jump, label: head))
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
          var condition = Value(kind: ValueKind.Const, name: "true",
            `type`: `Type`(kind: TypeKind.Bool))
          let variant =
            if arm.pattern.tag == "variant-pattern": ast.VariantPattern(arm.pattern).name.text
            elif arm.pattern.tag == "name": ast.Name(arm.pattern).text
            else: ""
          if arm.pattern.tag != "wildcard":
            var left = value
            var right: Value
            if value.type.kind == TypeKind.TaggedUnion and variant.len > 0:
              left = fresh(`Type`(kind: TypeKind.Uint, width: 32))
              emit(Instruction(kind: InstrKind.Extract, dest: left, val: value, field: "tag"))
              var tag = 0
              var current = 0
              for name in value.type.variants.keys:
                if name == variant: tag = current
                inc current
              right = Value(kind: ValueKind.Const, name: $tag, `type`: left.type)
            else:
              right = expression(ast.Expression(arm.pattern), value.type)
            condition = fresh(`Type`(kind: TypeKind.Bool))
            emit(Instruction(kind: InstrKind.Compare, dest: condition, op: "equals",
              val: left, val2: right))
          finish(Instruction(kind: InstrKind.Cjump, cond: condition,
            trueLabel: yes, falseLabel: no))
          begin(yes)
          let savedEnvironment = environment
          if arm.pattern.tag == "variant-pattern" and ast.VariantPattern(arm.pattern).binding != nil:
            let payloadType = value.type.variants.getOrDefault(variant)
            if payloadType != nil:
              let payload = fresh(payloadType)
              emit(Instruction(kind: InstrKind.Extract, dest: payload, val: value, field: variant))
              environment[ast.VariantPattern(arm.pattern).binding.text] = payload
          if arm.guard != nil:
            let guard = expression(arm.guard)
            let guarded = "guard_" & suffix & "_" & $index
            finish(Instruction(kind: InstrKind.Cjump, cond: guard,
              trueLabel: guarded, falseLabel: no))
            begin(guarded)
          statements(arm.body.stmts)
          exits = exits and term != nil
          finish(if term != nil: term else: Instruction(kind: InstrKind.Jump, label: ending))
          environment = savedEnvironment
          begin(no)
        finish(Instruction(kind: InstrKind.Panic, msg: "non-exhaustive match"))
        begin(ending)
        if exits:
          term = Instruction(kind: InstrKind.Panic, msg: "unreachable match join")
          break
      of "when":
        let branch = ast.`When`(statement)
        let condition = expression(branch.cond)
        inc serial
        let yes = "then_" & $serial
        let no = "else_" & $serial
        let ending = "end_" & $serial
        finish(Instruction(kind: InstrKind.Cjump, cond: condition,
          trueLabel: yes, falseLabel: no))
        begin(yes)
        statements(branch.`then`.stmts)
        let yesTerminated = term != nil
        finish(if term != nil: term else: Instruction(kind: InstrKind.Jump, label: ending))
        begin(no)
        if branch.`else` != nil:
          if branch.`else`.tag == "when": statements(@[ast.Statement(branch.`else`)])
          else: statements(ast.Block(branch.`else`).stmts)
        let noTerminated = term != nil
        finish(if term != nil: term else: Instruction(kind: InstrKind.Jump, label: ending))
        begin(ending)
        if yesTerminated and noTerminated:
          term = Instruction(kind: InstrKind.Panic, msg: "unreachable branch join")
          break
      of "while":
        let loopStatement = ast.`While`(statement)
        inc serial
        let head = "while_" & $serial
        let bodyLabel = "body_" & $serial
        let ending = "end_" & $serial
        finish(Instruction(kind: InstrKind.Jump, label: head))
        begin(head)
        let condition = expression(loopStatement.cond)
        finish(Instruction(kind: InstrKind.Cjump, cond: condition,
          trueLabel: bodyLabel, falseLabel: ending))
        begin(bodyLabel)
        loops.add((head: head, exit: ending, depth: scopes.len))
        statements(loopStatement.body.stmts)
        discard loops.pop()
        finish(if term != nil: term else: Instruction(kind: InstrKind.Jump, label: head))
        begin(ending)
      of "break", "continue":
        if loops.len == 0: raise newException(ValueError, statement.tag & " needs a loop")
        let active = loops[^1]
        cleanup(active.depth, status = -1)
        term = Instruction(kind: InstrKind.Jump,
          label: if statement.tag == "break": active.exit else: active.head)
        break
      of "constant":
        let declaration = ast.Constant(statement)
        let expected =
          if typed.hasKey(cast[pointer](statement)): semanticType(typed[cast[pointer](statement)], aliases)
          elif declaration.`type` != nil: lowerType(declaration.`type`, aliases)
          else: nil
        environment[declaration.name.text] = expression(declaration.value, expected)
        slots.del(declaration.name.text)
      of "mutable":
        let declaration = ast.Mutable(statement)
        let expected =
          if typed.hasKey(cast[pointer](statement)): semanticType(typed[cast[pointer](statement)], aliases)
          elif declaration.`type` != nil: lowerType(declaration.`type`, aliases)
          else: nil
        let value = expression(declaration.value, expected)
        let pointer = fresh(`Type`(kind: TypeKind.Ptr, elem: value.type))
        emit(Instruction(kind: InstrKind.Alloc, op: "slot", dest: pointer, region: "scope"))
        emit(Instruction(kind: InstrKind.Store, `ptr`: pointer, val: value))
        slots[declaration.name.text] = pointer
        environment.del(declaration.name.text)
      of "assignment":
        let assignment = ast.Assignment(statement)
        let pointer = place(assignment.target)
        emit(Instruction(kind: InstrKind.Store, `ptr`: pointer,
          val: expression(assignment.value, pointer.type.elem), effects: @["write"]))
      of "advance":
        let target = ast.AdvanceStatement(statement).target
        let pointer = place(target)
        let previous = expression(target)
        let next = fresh(previous.type)
        emit(Instruction(kind: InstrKind.Add, dest: next, val: previous,
          val2: Value(kind: ValueKind.Const, name: "1", `type`: previous.type)))
        emit(Instruction(kind: InstrKind.Store, `ptr`: pointer, val: next, effects: @["write"]))
      of "give":
        let value = if ast.Give(statement).value == nil: Value() else: expression(ast.Give(statement).value, signature.ret)
        var hasErrorCleanup = false
        for scope in scopes:
          for entry in scope:
            if entry.statement.error: hasErrorCleanup = true
        if value.type != nil and value.type.kind == TypeKind.Fallible and hasErrorCleanup:
          let failed = fresh(`Type`(kind: TypeKind.Bool))
          emit(Instruction(kind: InstrKind.Extract, dest: failed, val: value, field: "failed"))
          cleanup(0, failed, 0)
        else:
          cleanup(0, status = -1)
        term = Instruction(kind: InstrKind.Return, value: value)
        break
      of "action":
        let action = ast.Action(statement)
        discard expression(if action.value != nil: action.value else: ast.Call(tag: "call", callee: action.name, args: action.args, span: statement.span))
      of "try":
        let value = expression(ast.`Try`(statement).expr)
        if hasCleanups(): discard propagate(value)
        else: emit(Instruction(kind: InstrKind.Try, expr: value))
      of "defer":
        if cleaning: raise newException(ValueError, "Cleanup cannot register another cleanup")
        scopes[^1].add(Cleanup(statement: ast.`Defer`(statement),
          values: snapshot(environment), storage: snapshot(slots)))
      of "machine": discard expression(statement)
      of "native": emit(Instruction(kind: InstrKind.Native, code: ast.Native(statement).code, field: "@" & ast.Native(statement).substrate, effects: @["unknown"]))
      of "native-zig": emit(Instruction(kind: InstrKind.NativeZig, code: ast.NativeZig(statement).code, effects: @["unknown"]))
      of "eval": statements(ast.EvalBlock(statement).body.stmts)
      of "unreachable-statement":
        term = Instruction(kind: InstrKind.Panic, msg: "unreachable")
        break
      of "asm": emit(Instruction(kind: InstrKind.NativeZig,
        code: "asm volatile (" & ast.Asm(statement).code & ");", effects: @["unknown"]))
      of "alias", "function", "extern-function", "use", "c-import", "test": discard
      else: raise newException(ValueError, "lowering for statement '" & statement.tag & "' is not implemented")
    if term == nil and not cleaning: cleanup(scopes.high, status = -1)
    scopes.setLen(scopes.len - 1)
    environment = outer
    slots = saved
  proc cleanup(first: int; failed: Value = Value(); status = -1) =
    if first < 0 or first >= scopes.len: return
    let activeValues = snapshot(environment)
    let activeSlots = snapshot(slots)
    let previousCleaning = cleaning
    cleaning = true
    for scopeIndex in countdown(scopes.high, first):
      for cleanupIndex in countdown(scopes[scopeIndex].high, 0):
        let entry = scopes[scopeIndex][cleanupIndex]
        if entry.statement.error and status < 0: continue
        var ending = ""
        if entry.statement.error and status == 0:
          inc serial
          let yes = "cleanup_" & $serial
          ending = "cleaned_" & $serial
          finish(Instruction(kind: InstrKind.Cjump, cond: failed,
            trueLabel: yes, falseLabel: ending))
          begin(yes)
        environment = snapshot(entry.values)
        slots = snapshot(entry.storage)
        if entry.statement.body.tag == "block":
          statements(ast.Block(entry.statement.body).stmts)
        else:
          discard expression(ast.Expression(entry.statement.body))
        if term != nil:
          raise newException(ValueError, "Cleanup cannot leave its enclosing scope")
        if ending.len > 0:
          finish(Instruction(kind: InstrKind.Jump, label: ending))
          begin(ending)
    environment = activeValues
    slots = activeSlots
    cleaning = previousCleaning
  proc propagate(value: Value): Value =
    if value.type == nil or value.type.kind != TypeKind.Fallible:
      raise newException(ValueError, "try needs a fallible value")
    inc serial
    let errorLabel = "error_" & $serial
    let success = "value_" & $serial
    let failed = fresh(`Type`(kind: TypeKind.Bool))
    emit(Instruction(kind: InstrKind.Extract, dest: failed, val: value, field: "failed"))
    finish(Instruction(kind: InstrKind.Cjump, cond: failed,
      trueLabel: errorLabel, falseLabel: success))
    begin(errorLabel)
    cleanup(0, status = 1)
    emit(Instruction(kind: InstrKind.Try, expr: value))
    finish(Instruction(kind: InstrKind.Panic, msg: "unreachable successful propagation"))
    begin(success)
    let dest = fresh(value.type.elem)
    emit(Instruction(kind: InstrKind.Extract, dest: dest, val: value, field: "value"))
    dest
  statements(functionNode.body.stmts)
  if term == nil: term = Instruction(kind: InstrKind.Return)
  finish(term)
  result = node.Function(name: if functionNode.name.text == "start": "main" else: functionNode.name.text,
    public: functionNode.public, line: functionNode.span.line, abi: functionNode.abi,
    attributes: functionNode.attributes, typeParams: functionNode.typeParams.mapIt(it.name.text),
    params: params, ret: signature.ret, blocks: blocks)

proc lower*(program: ast.Program; typed: Table[pointer, semantic.Type] = initTable[pointer, semantic.Type]()): Module =
  if program == nil or program.units.len == 0: raise newException(ValueError, "cannot lower an empty program")
  var aliases = initTable[string, `Type`]()
  var declarations: seq[TypeDecl]
  for unit in program.units:
    for statement in unit.body.stmts:
      if statement.tag == "alias": aliases[ast.Alias(statement).name.text] = `Type`(kind: TypeKind.Struct, name: ast.Alias(statement).name.text)
  for unit in program.units:
    for statement in unit.body.stmts:
      if statement.tag == "alias":
        let alias = ast.Alias(statement)
        let value = lowerAlias(alias, aliases)
        value.name = alias.name.text
        let placeholder = aliases[alias.name.text]
        placeholder[] = value[]
        if alias.typeParams.len == 0: declarations.add(TypeDecl(name: alias.name.text, `type`: placeholder))
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
          for parameter in checked.params: params.add(semanticType(parameter, aliases))
        else:
          for parameter in function.params: params.add(if typed.hasKey(cast[pointer](parameter)): semanticType(typed[cast[pointer](parameter)], aliases) else: lowerType(parameter.type, aliases))
        let ret = if checked != nil and checked.kind == "function": semanticType(checked.ret, aliases) elif function.returnType == nil: `Type`(kind: TypeKind.Void) else: lowerType(function.returnType, aliases)
        signatures[function.name.text] = `Type`(kind: TypeKind.Function, params: params,
          ret: ret, abi: function.abi, attributes: function.typeParams.mapIt(it.name.text))
      elif statement.tag == "extern-function":
        let function = ast.ExternFunction(statement); var params: seq[`Type`]
        for parameter in function.params: params.add(lowerType(parameter.type, aliases))
        let ret = lowerType(function.returnType, aliases)
        signatures[function.name.text] = `Type`(kind: TypeKind.Function, params: params,
          ret: ret, abi: function.abi, attributes: function.typeParams.mapIt(it.name.text))
        var symbol = function.symbol
        if function.native.code.len > 0:
          symbol = "foo_escape_"
          for item in function.name.text: symbol.add(toHex(item.ord, 2).toLowerAscii)
        symbols[function.name.text] = symbol
        externs.add(Extern(name: function.name.text, symbol: symbol, abi: function.abi,
          params: params, ret: ret, typeParams: function.typeParams.mapIt(it.name.text)))
  var storage: seq[Storage]
  for unit in program.units:
    for statement in unit.body.stmts:
      if statement.tag != "mutable": continue
      let declaration = ast.Mutable(statement)
      let evaluated = eval.evaluate(declaration.value, bindings)
      let checked = typed.getOrDefault(cast[pointer](statement))
      let typ =
        if checked != nil: semanticType(checked, aliases)
        elif declaration.type != nil: lowerType(declaration.type, aliases)
        elif evaluated.tag == "integer": `Type`(kind: TypeKind.Int, width: 64)
        elif evaluated.tag == "decimal": `Type`(kind: TypeKind.Float, width: 64)
        elif evaluated.tag in ["text", "newline"]: `Type`(kind: TypeKind.Slice, constant: true, elem: `Type`(kind: TypeKind.Uint, width: 8))
        else: `Type`(kind: TypeKind.Bool)
      var value: Value
      if evaluated.tag in ["integer", "decimal", "text", "character", "true", "false", "nothing", "newline"]:
        value = literalValue(evaluated, typ)
        if evaluated.tag == "nothing": value.name = "null"
      else:
        raise newException(ValueError, "File value '" & declaration.name.text & "' needs a scalar compile-time initializer")
      storage.add(Storage(name: declaration.name.text, public: declaration.public, value: value))
  var funcs: seq[node.Function]
  for unit in program.units:
    for statement in unit.body.stmts:
      if statement.tag == "function":
        funcs.add(lowerFunction(ast.Function(statement), signatures, aliases,
          constants, bindings, storage, symbols, typed))
  result = Module(name: program.units[0].name.text, version: 1, stage: "@foo",
    unitPackage: program.units[0].name.text, unitPath: program.units[0].file,
    requires: "base", types: declarations, externs: externs, funcs: funcs,
    storage: storage, regions: @[], traces: @[], native: @[], residue: @[])
  for declaration in constants.values:
    if declaration.evaluated:
      result.residue.add(Residue(id: "eval" & $result.residue.len,
        operation: "eval", state: "resolved", payload: declaration.name.text))
  for function in result.funcs:
    let scope = function.name & ".scope"
    result.regions.add(Region(id: scope, kind: "scope"))
    var pendingBlocks = function.blocks
    var panics: seq[node.Block]
    var blockIndex = 0
    while blockIndex < pendingBlocks.len:
      let basicBlock = pendingBlocks[blockIndex]
      inc blockIndex
      for instruction in basicBlock.instrs:
        if instruction.fallback != nil: pendingBlocks.add(instruction.fallback)
        if instruction.func.len > 0:
          for declaration in result.externs:
            if declaration.name != instruction.func: continue
            if declaration.abi == "runtime.atomic":
              instruction.effects = @["read", "write", "synchronize"]
              instruction.op = "atomic"
            elif declaration.abi in ["runtime.thread", "runtime.task"]:
              instruction.effects = @["read", "write", "synchronize"]
              instruction.op = "thread"
            elif declaration.abi == "runtime.memory" and declaration.symbol == "copy":
              instruction.effects = @["read", "write", "synchronize"]
              instruction.op = "copy"
        if instruction.region == "scope": instruction.region = scope
        if instruction.kind in {InstrKind.Try, InstrKind.Trace}:
          instruction.trace = function.name & ".trace"
          if not result.traces.anyIt(it.id == instruction.trace):
            result.traces.add(Trace(id: instruction.trace, `function`: function.name))
        if instruction.kind == InstrKind.Native:
          let id = "native" & $result.native.len
          result.native.add(NativeContract(id: id,
            stage: if instruction.field.len > 0: instruction.field else: "@foo",
            code: instruction.code,
            abi: if instruction.op.startsWith("machine:"): instruction.op else: "foo:1",
            effects: @["unknown"]))
          instruction.symbol = id
        let numeric = if instruction.dest.type != nil and instruction.dest.type.kind == TypeKind.Vector: instruction.dest.type.elem else: instruction.dest.type
        if instruction.kind in {InstrKind.Add, InstrKind.Sub, InstrKind.Mul,
            InstrKind.Div, InstrKind.Remainder, InstrKind.Index} and
            (numeric == nil or numeric.kind != TypeKind.Float):
          let target = "panic_" & $panics.len
          instruction.panic = target
          panics.add(node.Block(label: target, instrs: @[], term: Instruction(
            kind: InstrKind.Panic, msg: "Checked " & operations[instruction.kind.ord] & " failed")))
        if instruction.kind in {InstrKind.Eval, InstrKind.Reflect, InstrKind.Embed}:
          let id = "residue" & $result.residue.len
          let operation = if instruction.kind == InstrKind.Embed: "embed" elif instruction.kind == InstrKind.Reflect: "reflect" else: "eval"
          let payload = if instruction.path.len > 0: instruction.path elif instruction.evalBody.len > 0: instruction.evalBody elif instruction.typeArg != nil: instruction.typeArg.name else: ""
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
      for basicBlock in function.blocks:
        if basicBlock.label != current: continue
        for instruction in basicBlock.instrs & @[basicBlock.term]:
          if instruction == nil: continue
          for target in [instruction.label, instruction.trueLabel,
              instruction.falseLabel, instruction.panic]:
            if target.len > 0: queue.add(target)
    function.blocks = function.blocks.filterIt(it.label in reachable)
    for basicBlock in function.blocks:
      for instruction in basicBlock.instrs:
        if instruction.kind == InstrKind.Phi:
          instruction.blocks = instruction.blocks.filterIt(it.label in reachable)
  for unit in program.units:
    for statement in unit.body.stmts:
      if statement.tag == "native":
        let native = ast.Native(statement)
        result.native.add(NativeContract(id: "native" & $result.native.len,
          stage: "@" & native.substrate, code: native.code, abi: "foo:1", effects: @["unknown"]))
      elif statement.tag == "extern-function" and ast.ExternFunction(statement).native.code.len > 0:
        let external = ast.ExternFunction(statement)
        var parameters = newJArray()
        for parameter in external.params: parameters.add(%parameter.name.text)
        let code = $(%* {"format": "foo.native", "version": 1,
          "parameters": parameters, "source": external.native.code})
        var symbol = "foo_escape_"
        for item in external.name.text: symbol.add(toHex(item.ord, 2).toLowerAscii)
        result.native.add(NativeContract(id: symbol, stage: "@" & external.native.substrate,
          code: code, abi: "foo.native:1", effects: @["unknown"]))
  discard seal(result)
