import std/[math, sets, strutils, tables]
import ../ast/node as ast

proc evaluate*(expression: ast.Expression; bindings: Table[string, ast.Expression];
    active: HashSet[string]): ast.Expression

proc evaluate*(expression: ast.Expression; bindings: Table[string, ast.Expression];
    active: HashSet[string]): ast.Expression =
  if expression == nil: raise newException(ValueError, "Compile-time evaluation cannot execute an empty expression")
  if expression.tag in ["integer", "decimal", "text", "character", "true",
      "false", "nothing", "newline"]:
    return expression
  if expression.tag == "group":
    return evaluate(ast.Group(expression).expr, bindings, active)
  if expression.tag == "name":
    let name = ast.Name(expression).text
    if name in active:
      raise newException(ValueError, "Circular compile-time value '" & name & "'")
    if not bindings.hasKey(name):
      raise newException(ValueError, "Compile-time value '" & name & "' is not constant")
    var pending = active
    pending.incl(name)
    return evaluate(bindings[name], bindings, pending)
  if expression.tag == "binary":
    let binary = ast.Binary(expression)
    let left = evaluate(binary.left, bindings, active)
    if (binary.op == "and" and left.tag == "false") or
        (binary.op == "or" and left.tag == "true"):
      return left
    let right = evaluate(binary.right, bindings, active)
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
    let value = evaluate(unary.operand, bindings, active)
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
  evaluate(expression, bindings, initHashSet[string]())

proc visit(body: ast.Block; inherited: Table[string, ast.Expression]) =
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
          constant.value = evaluate(constant.value, bindings)
          constant.evaluated = true
          bindings[constant.name.text] = constant.value
        elif declaration.tag != "alias":
          raise newException(ValueError,
            "eval accepts only constant and type declarations; runtime side effects are forbidden")
        hoisted.add(declaration)
    else:
      runtime.add(statement)
  body.stmts = hoisted & runtime
  for statement in body.stmts:
    var scope = bindings
    if statement.tag == "function":
      for parameter in ast.Function(statement).params: scope.del(parameter.name.text)
      visit(ast.Function(statement).body, scope)
    elif statement.tag == "when":
      let branch = ast.`When`(statement)
      visit(branch.then, scope)
      if branch.else != nil:
        if branch.else.tag == "block": visit(ast.Block(branch.else), scope)
        elif branch.else.tag == "when":
          let wrapper = ast.Block(tag: "block", span: branch.else.span, stmts: @[ast.Statement(branch.else)])
          visit(wrapper, scope)
    elif statement.tag == "while": visit(ast.`While`(statement).body, scope)
    elif statement.tag == "repeat": visit(ast.Repeat(statement).body, scope)
    elif statement.tag == "for": visit(ast.`For`(statement).body, scope)
    elif statement.tag == "unsafe": visit(ast.Unsafe(statement).body, scope)
    elif statement.tag == "test": visit(ast.TestBlock(statement).body, scope)
    elif statement.tag == "defer" and ast.`Defer`(statement).body.tag == "block":
      visit(ast.Block(ast.`Defer`(statement).body), scope)
    elif statement.tag == "match":
      for arm in ast.Match(statement).cases: visit(arm.body, scope)

proc expand*(program: ast.Program) =
  for unit in program.units: visit(unit.body, initTable[string, ast.Expression]())
