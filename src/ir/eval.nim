import std/[math, sets, strutils, tables]
import ../ast/node as ast
import ../ast/print as astPrint

type Layout = object
  size: int
  alignment: int
  offsets: Table[string, int]
  names: seq[string]
  types: seq[string]
  count: int

proc layout(node: ast.`Type`; types: Table[string, ast.Alias];
    active: HashSet[string]; pointerBytes: int): Layout =
  if node.tag == "primitive":
    let primitive = ast.Primitive(node)
    case primitive.name
    of "byte", "boolean": result.size = 1
    of "character": result.size = 4
    of "integer", "unsigned", "decimal":
      let width = if primitive.width.len == 0: 64 else: parseInt(primitive.width)
      if width in [8, 16, 32, 64]: result.size = width div 8
    of "text":
      result.size = pointerBytes * 2
      result.alignment = pointerBytes
      return
    else: discard
    if result.size == 0:
      raise newException(ValueError, "Compile-time layout requires a fixed-width scalar")
    result.alignment = result.size
    return
  if node.tag in ["pointer", "function-type"]:
    return Layout(size: pointerBytes, alignment: pointerBytes)
  if node.tag in ["sequence", "array"]:
    return Layout(size: pointerBytes * 2, alignment: pointerBytes)
  if node.tag != "named":
    raise newException(ValueError, "Compile-time layout requires a fixed-width scalar, address, slice, or c record")
  let name = ast.Named(node).name.text
  if name in active:
    raise newException(ValueError, "Recursive compile-time layout for '" & name & "'")
  if not types.hasKey(name) or types[name].body == nil or
      types[name].body.tag != "record" or ast.Record(types[name].body).layout != "c":
    raise newException(ValueError, "Compile-time layout requires a c record: '" & name & "'")
  var pending = active
  pending.incl(name)
  result.alignment = 1
  result.offsets = initTable[string, int]()
  for field in ast.Record(types[name].body).fields:
    let member = layout(field.type, types, pending, pointerBytes)
    let padding = (member.alignment - result.size mod member.alignment) mod member.alignment
    if result.size > high(int) - padding - member.size:
      raise newException(ValueError, "Compile-time record layout overflows")
    result.size += padding
    result.offsets[field.name.text] = result.size
    result.names.add(field.name.text)
    result.types.add(astPrint.print(field.type))
    result.size += member.size
    result.alignment = max(result.alignment, member.alignment)
    inc result.count
  if result.count == 0:
    raise newException(ValueError, "Compile-time layout requires a nonempty c record")
  for attribute in types[name].attributes:
    if attribute.startsWith("align(") and attribute.endsWith(")"):
      result.alignment = max(result.alignment,
        parseInt(attribute[6 ..< attribute.len - 1]))
  result.size += (result.alignment - result.size mod result.alignment) mod result.alignment

proc evaluate*(expression: ast.Expression; bindings: Table[string, ast.Expression];
    active: HashSet[string]; types: Table[string, ast.Alias];
    pointerBytes: int = sizeof(pointer)): ast.Expression

proc evaluate*(expression: ast.Expression; bindings: Table[string, ast.Expression];
    active: HashSet[string]; types: Table[string, ast.Alias];
    pointerBytes: int): ast.Expression =
  if expression == nil: raise newException(ValueError, "Compile-time evaluation cannot execute an empty expression")
  if expression.tag in ["integer", "decimal", "text", "character", "true",
      "false", "nothing", "null", "newline"]:
    return expression
  if expression.tag == "group":
    return evaluate(ast.Group(expression).expr, bindings, active, types, pointerBytes)
  if expression.tag == "name":
    let name = ast.Name(expression).text
    if name in active:
      raise newException(ValueError, "Circular compile-time value '" & name & "'")
    if not bindings.hasKey(name):
      raise newException(ValueError, "Compile-time value '" & name & "' is not constant")
    var pending = active
    pending.incl(name)
    return evaluate(bindings[name], bindings, pending, types, pointerBytes)
  if expression.tag == "field":
    let field = ast.Field(expression)
    if field.object.tag == "reflect" and field.field.text in ["size", "alignment", "count"]:
      let measured = layout(ast.Reflect(field.object).type, types,
        initHashSet[string](), pointerBytes)
      let value = case field.field.text
        of "size": measured.size
        of "alignment": measured.alignment
        else: measured.count
      return ast.Integer(tag: "integer", span: expression.span, value: $value)
  if expression.tag == "call":
    let call = ast.Call(expression)
    if call.callee.tag == "field":
      let field = ast.Field(call.callee)
      if field.object.tag == "reflect" and field.field.text in
          ["offset", "fieldname", "fieldtype"]:
        if call.args.len != 1:
          raise newException(ValueError, "reflect field query requires one name or index")
        let name = evaluate(call.args[0], bindings, active, types, pointerBytes)
        let measured = layout(ast.Reflect(field.object).type, types,
          initHashSet[string](), pointerBytes)
        if measured.count == 0:
          raise newException(ValueError, "reflect field query requires a c record")
        var label: string
        if name.tag == "text": label = ast.Text(name).value
        elif name.tag == "integer":
          let index = parseInt(ast.Integer(name).value.replace("_", ""))
          if index < 0 or index >= measured.count:
            raise newException(ValueError, "Record field index is out of bounds")
          label = measured.names[index]
        else:
          raise newException(ValueError, "reflect field query requires a constant name or index")
        if not measured.offsets.hasKey(label):
          raise newException(ValueError, "Unknown record field '" & label & "'")
        if field.field.text == "offset":
          return ast.Integer(tag: "integer", span: expression.span,
            value: $measured.offsets[label])
        let index = measured.names.find(label)
        return ast.Text(tag: "text", span: expression.span,
          value: if field.field.text == "fieldname": label else: measured.types[index])
  if expression.tag == "binary":
    let binary = ast.Binary(expression)
    let left = evaluate(binary.left, bindings, active, types, pointerBytes)
    if (binary.op == "and" and left.tag == "false") or
        (binary.op == "or" and left.tag == "true"):
      return left
    let right = evaluate(binary.right, bindings, active, types, pointerBytes)
    proc boolean(value: bool): ast.Expression =
      if value: ast.`True`(tag: "true", span: expression.span)
      else: ast.`False`(tag: "false", span: expression.span)
    if left.tag in ["true", "false"] and right.tag in ["true", "false"]:
      case binary.op
      of "and": return boolean(left.tag == "true" and right.tag == "true")
      of "or": return boolean(left.tag == "true" or right.tag == "true")
      of "is", "==", "equals": return boolean(left.tag == right.tag)
      of "is not", "!=", "does not equal": return boolean(left.tag != right.tag)
      else: discard
    if left.tag == "text" and right.tag == "text" and binary.op in ["plus", "+"]:
      return ast.Text(tag: "text", span: expression.span,
        value: ast.Text(left).value & ast.Text(right).value)
    if left.tag == "text" and right.tag == "text" and
        binary.op in ["is", "==", "equals", "is not", "!=", "does not equal"]:
      let equal = ast.Text(left).value == ast.Text(right).value
      return boolean(if binary.op in ["is", "==", "equals"]: equal else: not equal)
    if left.tag in ["integer", "decimal"] and right.tag in ["integer", "decimal"]:
      let integral = left.tag == "integer" and right.tag == "integer"
      if integral:
        let a = parseBiggestInt(ast.Integer(left).value.replace("_", ""))
        let b = parseBiggestInt(ast.Integer(right).value.replace("_", ""))
        case binary.op
        of "+", "plus": return ast.Integer(tag: "integer", span: expression.span, value: $(a + b))
        of "-", "minus": return ast.Integer(tag: "integer", span: expression.span, value: $(a - b))
        of "*", "times": return ast.Integer(tag: "integer", span: expression.span, value: $(a * b))
        of "/", "divided by":
          if b == 0: raise newException(ValueError, "Compile-time division by zero")
          return ast.Integer(tag: "integer", span: expression.span, value: $(a div b))
        of "%", "remainder":
          if b == 0: raise newException(ValueError, "Compile-time division by zero")
          return ast.Integer(tag: "integer", span: expression.span, value: $(a mod b))
        of "is", "==", "equals": return boolean(a == b)
        of "is not", "!=", "does not equal": return boolean(a != b)
        of "less than", "<", "is less than": return boolean(a < b)
        of "greater than", ">", "is greater than": return boolean(a > b)
        of "<=", "is at most": return boolean(a <= b)
        of ">=", "is at least": return boolean(a >= b)
        else: raise newException(ValueError, "Unsupported compile-time operator '" & binary.op & "'")
      else:
        let a = parseFloat((if left.tag == "integer": ast.Integer(left).value else: ast.Decimal(left).value).replace("_", ""))
        let b = parseFloat((if right.tag == "integer": ast.Integer(right).value else: ast.Decimal(right).value).replace("_", ""))
        case binary.op
        of "+", "plus": return ast.Decimal(tag: "decimal", span: expression.span, value: $(a + b))
        of "-", "minus": return ast.Decimal(tag: "decimal", span: expression.span, value: $(a - b))
        of "*", "times": return ast.Decimal(tag: "decimal", span: expression.span, value: $(a * b))
        of "/", "divided by":
          if b == 0: raise newException(ValueError, "Compile-time division by zero")
          return ast.Decimal(tag: "decimal", span: expression.span, value: $(a / b))
        of "%", "remainder":
          if b == 0: raise newException(ValueError, "Compile-time division by zero")
          return ast.Decimal(tag: "decimal", span: expression.span,
            value: $(a - trunc(a / b) * b))
        of "is", "==", "equals": return boolean(a == b)
        of "is not", "!=", "does not equal": return boolean(a != b)
        of "less than", "<", "is less than": return boolean(a < b)
        of "greater than", ">", "is greater than": return boolean(a > b)
        of "<=", "is at most": return boolean(a <= b)
        of ">=", "is at least": return boolean(a >= b)
        else: raise newException(ValueError, "Unsupported compile-time operator '" & binary.op & "'")
  if expression.tag == "unary":
    let unary = ast.Unary(expression)
    let value = evaluate(unary.operand, bindings, active, types, pointerBytes)
    if unary.op == "not" and value.tag in ["true", "false"]:
      if value.tag == "true": return ast.`False`(tag: "false", span: expression.span)
      return ast.`True`(tag: "true", span: expression.span)
    if unary.op in ["minus", "-"]:
      if value.tag == "integer":
        return ast.Integer(tag: "integer", span: value.span,
          value: $(-parseBiggestInt(ast.Integer(value).value.replace("_", ""))))
      if value.tag == "decimal":
        return ast.Decimal(tag: "decimal", span: value.span,
          value: $(-parseFloat(ast.Decimal(value).value.replace("_", ""))))
  raise newException(ValueError,
    "Compile-time evaluation cannot execute '" & expression.tag & "'")

proc evaluate*(expression: ast.Expression;
    bindings: Table[string, ast.Expression]): ast.Expression =
  evaluate(expression, bindings, initHashSet[string](),
    initTable[string, ast.Alias](), sizeof(pointer))

proc visit(body: ast.Block; inherited: Table[string, ast.Expression];
    types: Table[string, ast.Alias]; pointerBytes: int) =
  var bindings = inherited
  for statement in body.stmts:
    if statement.tag == "eval":
      for declaration in ast.EvalBlock(statement).body.stmts:
        if declaration.tag == "constant":
          bindings[ast.Constant(declaration).name.text] = ast.Constant(declaration).value
        elif declaration.tag == "mutable":
          bindings.del(ast.Mutable(declaration).name.text)
    elif statement.tag == "constant":
      bindings[ast.Constant(statement).name.text] = ast.Constant(statement).value
    elif statement.tag == "mutable":
      bindings.del(ast.Mutable(statement).name.text)
  var hoisted: seq[ast.Statement]
  var runtime: seq[ast.Statement]
  for statement in body.stmts:
    if statement.tag == "eval":
      for declaration in ast.EvalBlock(statement).body.stmts:
        if declaration.tag == "constant":
          let constant = ast.Constant(declaration)
          constant.value = evaluate(constant.value, bindings,
            initHashSet[string](), types, pointerBytes)
          constant.evaluated = true
          bindings[constant.name.text] = constant.value
        elif declaration.tag == "verify":
          let verdict = evaluate(ast.Verify(declaration).condition, bindings,
            initHashSet[string](), types, pointerBytes)
          if verdict.tag != "true":
            raise newException(ValueError,
              if verdict.tag == "false": "Compile-time assertion failed"
              else: "Compile-time assertion must be boolean")
        elif declaration.tag != "alias":
          raise newException(ValueError,
            "eval accepts only constants, types, and assertions; runtime side effects are forbidden")
        if declaration.tag != "verify": hoisted.add(declaration)
    else:
      if statement.tag == "verify":
        raise newException(ValueError, "verify belongs inside eval { ... }")
      runtime.add(statement)
  body.stmts = hoisted & runtime
  for statement in body.stmts:
    var scope = bindings
    if statement.tag == "function":
      for parameter in ast.Function(statement).params: scope.del(parameter.name.text)
      visit(ast.Function(statement).body, scope, types, pointerBytes)
    elif statement.tag == "when":
      let branch = ast.`When`(statement)
      visit(branch.then, scope, types, pointerBytes)
      if branch.else != nil:
        if branch.else.tag == "block": visit(ast.Block(branch.else), scope, types, pointerBytes)
        elif branch.else.tag == "when":
          let wrapper = ast.Block(tag: "block", span: branch.else.span, stmts: @[ast.Statement(branch.else)])
          visit(wrapper, scope, types, pointerBytes)
    elif statement.tag == "while": visit(ast.`While`(statement).body, scope, types, pointerBytes)
    elif statement.tag == "for": visit(ast.`For`(statement).body, scope, types, pointerBytes)
    elif statement.tag == "unsafe": visit(ast.Unsafe(statement).body, scope, types, pointerBytes)
    elif statement.tag == "test": visit(ast.TestBlock(statement).body, scope, types, pointerBytes)
    elif statement.tag == "defer" and ast.`Defer`(statement).body.tag == "block":
      visit(ast.Block(ast.`Defer`(statement).body), scope, types, pointerBytes)
    elif statement.tag == "match":
      for arm in ast.Match(statement).cases: visit(arm.body, scope, types, pointerBytes)

proc expand*(program: ast.Program; target = "") =
  let pointerBytes = if target.len == 0: sizeof(pointer)
    elif target.startsWith("wasm32") or target.startsWith("wasi") or
        target == "wasm-freestanding" or target.startsWith("i386") or
        target.startsWith("x86-") or target.startsWith("arm-") or
        target.startsWith("armv") or target.startsWith("thumb") or
        target.startsWith("riscv32"): 4
    else: 8
  for unit in program.units:
    var types = initTable[string, ast.Alias]()
    for statement in unit.body.stmts:
      if statement.tag == "alias":
        let alias = ast.Alias(statement)
        types[alias.name.text] = alias
    visit(unit.body, initTable[string, ast.Expression](), types, pointerBytes)
