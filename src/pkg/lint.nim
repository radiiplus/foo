import ../ast/node as ast
import ../diag/[code, engine]

proc expression(node: ast.Expression; diag: Engine)
proc body(body: ast.Block; diag: Engine)

proc expression(node: ast.Expression; diag: Engine) =
  if node == nil: return
  if node.tag == "machine":
    diag.emit(Code.Invalid, node.span, "This operation requires \"machine\" capability")
    diag.suggestion("Set requires to machine in the project manifest")
  case node.tag
  of "call":
    expression(ast.Call(node).callee, diag)
    for argument in ast.Call(node).args: expression(argument, diag)
  of "sequence-value":
    for item in ast.Values(node).items: expression(item, diag)
  of "closure": body(ast.Closure(node).body, diag)
  of "unary": expression(ast.Unary(node).operand, diag)
  of "binary": expression(ast.Binary(node).left, diag); expression(ast.Binary(node).right, diag)
  of "group": expression(ast.Group(node).expr, diag)
  of "field": expression(ast.Field(node).object, diag)
  of "index": expression(ast.Index(node).object, diag); expression(ast.Index(node).index, diag)
  of "allocation": expression(ast.Allocation(node).size, diag); expression(ast.Allocation(node).owner, diag)
  of "machine":
    expression(ast.Machine(node).target, diag); expression(ast.Machine(node).value, diag)
    for argument in ast.Machine(node).args: expression(argument, diag)
  else: discard

proc statement(node: ast.Statement; diag: Engine) =
  if node == nil: return
  case node.tag
  of "constant": expression(ast.Constant(node).value, diag)
  of "mutable": expression(ast.Mutable(node).value, diag)
  of "function":
    expression(ast.Function(node).guard, diag)
    body(ast.Function(node).body, diag)
  of "give": expression(ast.Give(node).value, diag)
  of "assignment": expression(ast.Assignment(node).target, diag); expression(ast.Assignment(node).value, diag)
  of "when":
    expression(ast.`When`(node).cond, diag); body(ast.`When`(node).then, diag)
    if ast.`When`(node).else != nil:
      if ast.`When`(node).else.tag == "block": body(ast.Block(ast.`When`(node).else), diag)
      else: statement(ast.`When`(node).else, diag)
  of "while": expression(ast.`While`(node).cond, diag); body(ast.`While`(node).body, diag)
  of "for": expression(ast.`For`(node).iter, diag); body(ast.`For`(node).body, diag)
  of "match":
    expression(ast.Match(node).scrutinee, diag)
    for arm in ast.Match(node).cases: expression(arm.guard, diag); body(arm.body, diag)
  of "defer":
    if ast.`Defer`(node).body.tag == "block": body(ast.Block(ast.`Defer`(node).body), diag)
    else: expression(ast.`Defer`(node).body, diag)
  of "unsafe": body(ast.Unsafe(node).body, diag)
  of "eval": body(ast.Evaluation(node).body, diag)
  of "test": body(ast.Test(node).body, diag)
  of "action":
    expression(ast.Action(node).value, diag)
    for argument in ast.Action(node).args: expression(argument, diag)
  of "machine": expression(node, diag)
  else: discard

proc body(body: ast.Block; diag: Engine) =
  if body != nil:
    for statement in body.stmts: statement(statement, diag)

proc capabilities*(program: ast.Program; diag: Engine; level = "base") =
  if level in ["machine", "hardware"]: return
  for unit in program.units: body(unit.body, diag)

proc native(body: ast.Block): bool
proc statement(node: ast.Statement): bool =
  if node == nil: return false
  if node.tag == "native": return true
  if node.tag == "extern-function" and ast.External(node).native.code.len > 0: return true
  case node.tag
  of "function": native(ast.Function(node).body)
  of "eval": native(ast.Evaluation(node).body)
  of "test": native(ast.Test(node).body)
  of "unsafe": native(ast.Unsafe(node).body)
  of "while": native(ast.`While`(node).body)
  of "for": native(ast.`For`(node).body)
  of "when":
    native(ast.`When`(node).then) or
      (ast.`When`(node).else != nil and (if ast.`When`(node).else.tag == "block": native(ast.Block(ast.`When`(node).else)) else: statement(ast.`When`(node).else)))
  of "match":
    for arm in ast.Match(node).cases:
      if native(arm.body): return true
    false
  of "defer": ast.`Defer`(node).body.tag == "block" and native(ast.Block(ast.`Defer`(node).body))
  else: false

proc native(body: ast.Block): bool =
  if body == nil: return false
  for statement in body.stmts:
    if statement(statement): return true
  false

proc inspect(body: ast.Block; diag: Engine; backend: string) =
  if body == nil: return
  for node in body.stmts:
    if node.tag == "extern-function" and ast.External(node).native.code.len > 0:
      diag.emit(Code.NativePublic, node.span,
        "Declare a native function at file scope, then call it with explicit arguments")
    case node.tag
    of "function": inspect(ast.Function(node).body, diag, backend)
    of "eval": inspect(ast.Evaluation(node).body, diag, backend)
    of "test": inspect(ast.Test(node).body, diag, backend)
    of "unsafe": inspect(ast.Unsafe(node).body, diag, backend)
    of "while": inspect(ast.`While`(node).body, diag, backend)
    of "for": inspect(ast.`For`(node).body, diag, backend)
    of "when":
      inspect(ast.`When`(node).then, diag, backend)
      if ast.`When`(node).else != nil:
        if ast.`When`(node).else.tag == "block": inspect(ast.Block(ast.`When`(node).else), diag, backend)
        else: inspect(ast.Block(tag: "block", span: ast.`When`(node).else.span, stmts: @[ast.Statement(ast.`When`(node).else)]), diag, backend)
    of "match":
      for arm in ast.Match(node).cases: inspect(arm.body, diag, backend)
    of "defer":
      if ast.`Defer`(node).body.tag == "block": inspect(ast.Block(ast.`Defer`(node).body), diag, backend)
    else: discard

proc lint*(program: ast.Program; diag: Engine; backend = "qbe") =
  for unit in program.units:
    for node in unit.body.stmts:
      if node.tag == "extern-function":
        let function = ast.External(node)
        if function.native.code.len > 0 and function.public:
          diag.emit(Code.NativePublic, node.span,
            "Public APIs cannot expose a native function; use a private implementation and a portable wrapper")
      if node.tag == "function":
        let function = ast.Function(node)
        if function.public and native(function.body):
          diag.emit(Code.NativePublic, node.span,
            "public function '" & function.name.text & "' cannot contain native code")
          diag.suggestion("Move the native implementation behind a private function and expose a portable wrapper")
        inspect(function.body, diag, backend)
      elif node.tag == "eval": inspect(ast.Evaluation(node).body, diag, backend)
      elif node.tag == "test": inspect(ast.Test(node).body, diag, backend)
