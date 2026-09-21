import ../ast/node as ast
import ../diag/[code, engine]

proc inspectExpression(node: ast.Expression; diag: Engine)
proc inspectBlock(body: ast.Block; diag: Engine)

proc inspectExpression(node: ast.Expression; diag: Engine) =
  if node == nil: return
  if node.tag == "machine":
    diag.emit(Code.Invalid, node.span, "This operation requires \"machine\" capability")
    diag.suggestion("Set requires to machine in project.json, then run foo toolchain install machine")
  case node.tag
  of "call":
    inspectExpression(ast.Call(node).callee, diag)
    for argument in ast.Call(node).args: inspectExpression(argument, diag)
  of "unary": inspectExpression(ast.Unary(node).operand, diag)
  of "binary": inspectExpression(ast.Binary(node).left, diag); inspectExpression(ast.Binary(node).right, diag)
  of "group": inspectExpression(ast.Group(node).expr, diag)
  of "field": inspectExpression(ast.Field(node).object, diag)
  of "index": inspectExpression(ast.Index(node).object, diag); inspectExpression(ast.Index(node).index, diag)
  of "allocation": inspectExpression(ast.Allocation(node).size, diag); inspectExpression(ast.Allocation(node).owner, diag)
  of "error-chain": inspectExpression(ast.ErrorChain(node).expr, diag); inspectExpression(ast.ErrorChain(node).context, diag)
  of "machine":
    inspectExpression(ast.Machine(node).target, diag); inspectExpression(ast.Machine(node).value, diag)
    for argument in ast.Machine(node).args: inspectExpression(argument, diag)
  else: discard

proc inspectStatement(node: ast.Statement; diag: Engine) =
  if node == nil: return
  case node.tag
  of "constant": inspectExpression(ast.Constant(node).value, diag)
  of "mutable": inspectExpression(ast.Mutable(node).value, diag)
  of "function": inspectBlock(ast.Function(node).body, diag)
  of "give": inspectExpression(ast.Give(node).value, diag)
  of "assignment": inspectExpression(ast.Assignment(node).target, diag); inspectExpression(ast.Assignment(node).value, diag)
  of "when":
    inspectExpression(ast.`When`(node).cond, diag); inspectBlock(ast.`When`(node).then, diag)
    if ast.`When`(node).else != nil:
      if ast.`When`(node).else.tag == "block": inspectBlock(ast.Block(ast.`When`(node).else), diag)
      else: inspectStatement(ast.`When`(node).else, diag)
  of "while": inspectExpression(ast.`While`(node).cond, diag); inspectBlock(ast.`While`(node).body, diag)
  of "repeat": inspectExpression(ast.Repeat(node).limit, diag); inspectBlock(ast.Repeat(node).body, diag)
  of "for": inspectExpression(ast.`For`(node).iter, diag); inspectBlock(ast.`For`(node).body, diag)
  of "match":
    inspectExpression(ast.Match(node).scrutinee, diag)
    for arm in ast.Match(node).cases: inspectExpression(arm.guard, diag); inspectBlock(arm.body, diag)
  of "try": inspectExpression(ast.`Try`(node).expr, diag)
  of "defer":
    if ast.`Defer`(node).body.tag == "block": inspectBlock(ast.Block(ast.`Defer`(node).body), diag)
    else: inspectExpression(ast.`Defer`(node).body, diag)
  of "unsafe": inspectBlock(ast.Unsafe(node).body, diag)
  of "eval": inspectBlock(ast.EvalBlock(node).body, diag)
  of "test": inspectBlock(ast.TestBlock(node).body, diag)
  of "action":
    inspectExpression(ast.Action(node).value, diag)
    for argument in ast.Action(node).args: inspectExpression(argument, diag)
  of "machine": inspectExpression(node, diag)
  else: discard

proc inspectBlock(body: ast.Block; diag: Engine) =
  if body != nil:
    for statement in body.stmts: inspectStatement(statement, diag)

proc capabilities*(program: ast.Program; diag: Engine; level = "base") =
  if level in ["machine", "hardware"]: return
  for unit in program.units: inspectBlock(unit.body, diag)

proc containsNative(body: ast.Block): bool
proc containsNativeStatement(node: ast.Statement): bool =
  if node == nil: return false
  if node.tag in ["native-zig", "native", "asm"]: return true
  if node.tag == "extern-function" and ast.ExternFunction(node).native.code.len > 0: return true
  case node.tag
  of "function": containsNative(ast.Function(node).body)
  of "eval": containsNative(ast.EvalBlock(node).body)
  of "test": containsNative(ast.TestBlock(node).body)
  of "unsafe": containsNative(ast.Unsafe(node).body)
  of "while": containsNative(ast.`While`(node).body)
  of "repeat": containsNative(ast.Repeat(node).body)
  of "for": containsNative(ast.`For`(node).body)
  of "when":
    containsNative(ast.`When`(node).then) or
      (ast.`When`(node).else != nil and (if ast.`When`(node).else.tag == "block": containsNative(ast.Block(ast.`When`(node).else)) else: containsNativeStatement(ast.`When`(node).else)))
  of "match":
    for arm in ast.Match(node).cases:
      if containsNative(arm.body): return true
    false
  of "defer": ast.`Defer`(node).body.tag == "block" and containsNative(ast.Block(ast.`Defer`(node).body))
  else: false

proc containsNative(body: ast.Block): bool =
  if body == nil: return false
  for statement in body.stmts:
    if containsNativeStatement(statement): return true
  false

proc lintBlock(body: ast.Block; diag: Engine; backend: string) =
  if body == nil: return
  for node in body.stmts:
    if node.tag == "extern-function" and ast.ExternFunction(node).native.code.len > 0:
      diag.emit(Code.NativePublic, node.span,
        "Declare a native function at file scope, then call it with explicit arguments")
    if node.tag == "native-zig" and backend != "zig":
      diag.emit(Code.NativePublic, node.span, "native zig blocks require the Zig backend")
      diag.suggestion("Remove this block or keep the package backend-pinned to Zig")
    case node.tag
    of "function": lintBlock(ast.Function(node).body, diag, backend)
    of "eval": lintBlock(ast.EvalBlock(node).body, diag, backend)
    of "test": lintBlock(ast.TestBlock(node).body, diag, backend)
    of "unsafe": lintBlock(ast.Unsafe(node).body, diag, backend)
    of "while": lintBlock(ast.`While`(node).body, diag, backend)
    of "repeat": lintBlock(ast.Repeat(node).body, diag, backend)
    of "for": lintBlock(ast.`For`(node).body, diag, backend)
    of "when":
      lintBlock(ast.`When`(node).then, diag, backend)
      if ast.`When`(node).else != nil:
        if ast.`When`(node).else.tag == "block": lintBlock(ast.Block(ast.`When`(node).else), diag, backend)
        else: lintBlock(ast.Block(tag: "block", span: ast.`When`(node).else.span, stmts: @[ast.Statement(ast.`When`(node).else)]), diag, backend)
    of "match":
      for arm in ast.Match(node).cases: lintBlock(arm.body, diag, backend)
    of "defer":
      if ast.`Defer`(node).body.tag == "block": lintBlock(ast.Block(ast.`Defer`(node).body), diag, backend)
    else: discard

proc lint*(program: ast.Program; diag: Engine; backend = "zig") =
  for unit in program.units:
    for node in unit.body.stmts:
      if node.tag == "extern-function":
        let function = ast.ExternFunction(node)
        if function.native.code.len > 0 and function.public:
          diag.emit(Code.NativePublic, node.span,
            "Public APIs cannot expose a native function; use a private implementation and a portable wrapper")
      if node.tag == "native-zig":
        if backend != "zig":
          diag.emit(Code.NativePublic, node.span, "native zig blocks require the Zig backend")
          diag.suggestion("Remove this block or keep the package backend-pinned to Zig")
        else:
          diag.emit(Code.NativePublic, node.span, "native zig must be inside a private function")
          diag.suggestion("Move the block into a private implementation function")
      if node.tag == "function":
        let function = ast.Function(node)
        if function.public and containsNative(function.body):
          diag.emit(Code.NativePublic, node.span,
            "public function '" & function.name.text & "' cannot contain native code")
          diag.suggestion("Move the native implementation behind a private function and expose a portable wrapper")
        lintBlock(function.body, diag, backend)
      elif node.tag == "eval": lintBlock(ast.EvalBlock(node).body, diag, backend)
      elif node.tag == "test": lintBlock(ast.TestBlock(node).body, diag, backend)
