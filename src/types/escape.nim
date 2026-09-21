import std/[sets, tables]
import ../ast/node as ast
import ../diag/[code, engine, span]
import ./env
import ./type as semantic

type Binding = object
  origins: HashSet[int]
  depth: int
  span: Span

proc storage(value: semantic.Type; seen: var HashSet[pointer]): bool =
  if value == nil or cast[pointer](value) in seen: return false
  seen.incl(cast[pointer](value))
  case value.kind
  of "pointer", "sequence", "array", "named", "unknown": true
  of "optional", "error", "vector": storage(value.elem, seen)
  of "opaque": value.name == "Allocator"
  of "record", "union":
    for field in value.fields.values:
      if storage(field, seen): return true
    false
  of "choice":
    for variant in value.variants.values:
      if storage(variant, seen): return true
    false
  else: false

proc storage(value: semantic.Type): bool =
  var seen = initHashSet[pointer]()
  storage(value, seen)

proc merge(sets: varargs[HashSet[int]]): HashSet[int] =
  result = initHashSet[int]()
  for values in sets:
    for value in values: result.incl(value)

proc nodeType(types: Table[pointer, semantic.Type]; node: ast.Node): semantic.Type =
  if node != nil and types.hasKey(cast[pointer](node)): types[cast[pointer](node)] else: nil

proc checkEscape*(body: ast.Block; environment: Environment; diag: Engine;
    types: Table[pointer, semantic.Type]) =
  proc report(expression: ast.Expression; origins: HashSet[int]; limit: int;
      message: string) =
    for depth in origins:
      if depth > limit:
        let subject = if expression.tag == "name":
          "'" & ast.Name(expression).text & "' may escape"
        else:
          "the value may escape"
        diag.emit(Code.ScopeEscape, expression.span, message & "; " & subject)
        diag.suggestion("Keep this value within its owning scope, or allocate using an explicit longer-lived owner")
        return

  proc expression(node: ast.Expression; bindings: Table[string, Binding];
      depth: int): HashSet[int] =
    result = initHashSet[int]()
    if node == nil: return
    case node.tag
    of "allocation":
      let allocation = ast.Allocation(node)
      discard expression(allocation.size, bindings, depth)
      if allocation.owner != nil: return expression(allocation.owner, bindings, depth)
      result.incl(depth)
    of "name":
      let name = ast.Name(node).text
      if bindings.hasKey(name): result = bindings[name].origins
    of "uninitialized":
      if storage(nodeType(types, node)): result.incl(depth)
    of "group": result = expression(ast.Group(node).expr, bindings, depth)
    of "unary": result = expression(ast.Unary(node).operand, bindings, depth)
    of "error-chain": result = expression(ast.ErrorChain(node).expr, bindings, depth)
    of "binary":
      let binary = ast.Binary(node)
      let origins = merge(expression(binary.left, bindings, depth),
        expression(binary.right, bindings, depth))
      if storage(nodeType(types, node)): result = origins
    of "field":
      let origins = expression(ast.Field(node).object, bindings, depth)
      if storage(nodeType(types, node)): result = origins
    of "index":
      let index = ast.Index(node)
      let origins = expression(index.object, bindings, depth)
      discard expression(index.index, bindings, depth)
      if storage(nodeType(types, node)): result = origins
    of "call":
      let call = ast.Call(node)
      var callee = nodeType(types, call.callee)
      if callee == nil and call.callee.tag == "name":
        callee = environment.lookup(ast.Name(call.callee).text)
      var arguments: seq[HashSet[int]]
      for argument in call.args:
        arguments.add(expression(argument, bindings, depth))
      let callType = nodeType(types, node)
      if callType != nil and callType.kind == "record" and
          (callee == nil or callee.kind != "function"):
        for origins in arguments: result = merge(result, origins)
        return
      for index, argument in call.args:
        if callee == nil or callee.kind != "function" or index notin callee.borrows:
          report(argument, arguments[index], 0,
            "This call may retain storage owned by the current scope")
      if not storage(callType): return
      if callee != nil and callee.kind == "function" and
          (callee.abi.len == 0 or callee.abi == "runtime.sequence"):
        for origins in arguments: result = merge(result, origins)
        return
      if callee != nil and callee.kind == "function" and
          callee.abi in ["runtime.crypto", "runtime.unicode", "runtime.compress",
            "runtime.json", "runtime.http", "runtime.system", "runtime.arch",
            "runtime.atomic", "runtime.list", "runtime.memory", "runtime.stream",
            "runtime.io", "runtime.fs", "runtime.net", "runtime.process",
            "runtime.thread", "runtime.time", "runtime.text"]:
        return
      for origins in arguments: result = merge(result, origins)
      result.incl(depth)
    else: discard

  proc visit(bodyNode: ast.Block; outer: var Table[string, Binding]; depth: int) =
    var bindings = initTable[string, Binding]()
    for name, binding in outer:
      bindings[name] = Binding(origins: merge(binding.origins), depth: binding.depth,
        span: binding.span)
    for statement in bodyNode.stmts:
      case statement.tag
      of "constant":
        let declaration = ast.Constant(statement)
        bindings[declaration.name.text] = Binding(
          origins: expression(declaration.value, bindings, depth),
          depth: depth, span: declaration.span)
      of "mutable":
        let declaration = ast.Mutable(statement)
        bindings[declaration.name.text] = Binding(
          origins: expression(declaration.value, bindings, depth),
          depth: depth, span: declaration.span)
      of "give":
        let value = ast.Give(statement).value
        if value != nil:
          report(value, expression(value, bindings, depth), 0,
            "This result may outlive storage owned by its function")
      of "assignment":
        let assignment = ast.Assignment(statement)
        let origins = expression(assignment.value, bindings, depth)
        var target = assignment.target
        while target != nil and target.tag in ["field", "index"]:
          target = if target.tag == "field": ast.Field(target).object else: ast.Index(target).object
        if target != nil and target.tag == "name" and bindings.hasKey(ast.Name(target).text):
          let name = ast.Name(target).text
          var binding = bindings[name]
          report(assignment.value, origins, binding.depth,
            "This assignment stores a shorter-lived value in an outer scope")
          binding.origins = merge(binding.origins, origins)
          bindings[name] = binding
        else:
          report(assignment.value, origins, 0,
            "This assignment stores a shorter-lived value in an outer scope")
      of "action":
        let action = ast.Action(statement)
        if action.value != nil:
          discard expression(action.value, bindings, depth)
        else:
          discard expression(action.name, bindings, depth)
          for argument in action.args: discard expression(argument, bindings, depth)
      of "try": discard expression(ast.`Try`(statement).expr, bindings, depth)
      of "when":
        let branch = ast.`When`(statement)
        discard expression(branch.cond, bindings, depth)
        visit(branch.then, bindings, depth + 1)
        if branch.else != nil:
          if branch.else.tag == "when":
            var nested = ast.Block(tag: "block", span: branch.else.span,
              stmts: @[ast.Statement(branch.else)])
            visit(nested, bindings, depth + 1)
          else:
            visit(ast.Block(branch.else), bindings, depth + 1)
      of "match":
        let matchNode = ast.Match(statement)
        let scrutineeOrigins = expression(matchNode.scrutinee, bindings, depth)
        for arm in matchNode.cases:
          var locals = bindings
          if arm.pattern != nil and arm.pattern.tag == "variant-pattern":
            let pattern = ast.VariantPattern(arm.pattern)
            if pattern.binding != nil:
              locals[pattern.binding.text] = Binding(origins: scrutineeOrigins,
                depth: depth + 1, span: pattern.span)
          discard expression(arm.guard, locals, depth + 1)
          visit(arm.body, locals, depth + 1)
      of "for":
        let loop = ast.`For`(statement)
        var locals = bindings
        locals[loop.bind.text] = Binding(
          origins: expression(loop.iter, bindings, depth),
          depth: depth + 1, span: loop.span)
        visit(loop.body, locals, depth + 1)
      of "while":
        let loop = ast.`While`(statement)
        discard expression(loop.cond, bindings, depth)
        visit(loop.body, bindings, depth + 1)
      of "repeat": visit(ast.Repeat(statement).body, bindings, depth + 1)
      of "unsafe": visit(ast.Unsafe(statement).body, bindings, depth + 1)
      of "eval": visit(ast.EvalBlock(statement).body, bindings, depth + 1)
      of "defer":
        let deferred = ast.`Defer`(statement)
        if deferred.body != nil and deferred.body.tag == "block":
          visit(ast.Block(deferred.body), bindings, depth + 1)
        else:
          discard expression(deferred.body, bindings, depth)
      else: discard
    for name, binding in outer.mpairs:
      if bindings.hasKey(name) and bindings[name].span == binding.span:
        binding.origins = merge(binding.origins, bindings[name].origins)

  var bindings = initTable[string, Binding]()
  visit(body, bindings, 1)

proc checkEscape*(body: ast.Block; environment: Environment; diag: Engine) =
  checkEscape(body, environment, diag, initTable[pointer, semantic.Type]())
