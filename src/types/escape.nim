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
  of "opaque": value.name == "allocator"
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
    types: Table[pointer, semantic.Type]; parameters: seq[string] = @[];
    returnsFrom: seq[int] = @[]) =
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
        if callee == nil or callee.kind != "function" or
            (index notin callee.borrows and callee.abi != "runtime.dylib"):
          report(argument, arguments[index], 0,
            "This call may retain storage owned by the current scope")
      if not storage(callType): return
      if callee != nil and callee.kind == "function" and
          (callee.abi.len == 0 or callee.abi in ["runtime.sequence", "runtime.memory"] or
          (callee.abi == "runtime.fs" and callee.borrows.len > 0)):
        if callee.borrows.len > 0 and
            (callee.abi.len == 0 or callee.abi == "runtime.fs"):
          for index in callee.borrows:
            if index < arguments.len: result = merge(result, arguments[index])
        else:
          for origins in arguments: result = merge(result, origins)
        return
      if callee != nil and callee.kind == "function" and
          callee.abi in ["runtime", "runtime.binary", "runtime.crypto", "runtime.unicode", "runtime.compress",
            "runtime.codec", "runtime.json", "runtime.http", "runtime.system", "runtime.arch",
            "runtime.cpu", "runtime.topology", "runtime.platform", "runtime.gpu", "runtime.vulkan", "runtime.bloom", "runtime.ring", "runtime.dylib", "runtime.metric", "runtime.trace", "runtime.limit",
            "runtime.atomic", "runtime.list", "runtime.memory", "runtime.stream",
            "runtime.table",
            "runtime.io", "runtime.fs", "runtime.vm", "runtime.net", "runtime.tls", "runtime.process",
            "runtime.thread", "runtime.time", "runtime.text"]:
        return
      for origins in arguments: result = merge(result, origins)
      result.incl(depth)
    of "sequence-value":
      for item in ast.Values(node).items:
        result = merge(result, expression(item, bindings, depth))
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
      of "destructure":
        let declaration = ast.Destructure(statement)
        let origins = expression(declaration.value, bindings, depth)
        for binding in declaration.bindings:
          bindings[binding.text] = Binding(origins: merge(origins),
            depth: depth, span: binding.span)
      of "give":
        let value = ast.Give(statement).value
        if value != nil:
          let origins = expression(value, bindings, depth)
          report(value, origins, 0,
            "This result may outlive storage owned by its function")
          if returnsFrom.len > 0 and storage(nodeType(types, value)):
            for origin in origins:
              if origin < 0 and -origin - 1 notin returnsFrom:
                diag.emit(Code.ScopeEscape, value.span,
                  "This result borrows from a parameter outside its declared relationship")
                break
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
  for index, parameter in parameters:
    if storage(environment.lookup(parameter)):
      var origins = initHashSet[int]()
      origins.incl(-index - 1)
      bindings[parameter] = Binding(origins: origins, depth: 0, span: body.span)
  visit(body, bindings, 1)

proc checkEscape*(body: ast.Block; environment: Environment; diag: Engine) =
  checkEscape(body, environment, diag, initTable[pointer, semantic.Type]())

proc checkBorrowInvalidation*(body: ast.Block; environment: Environment;
    diag: Engine; types: Table[pointer, semantic.Type]; parameters: seq[string] = @[];
    releases: seq[int] = @[]) =
  var parents = initTable[int, HashSet[int]]()
  var returned: seq[tuple[owners: HashSet[int], span: Span]]
  var nextOwner = 0

  proc fresh(): HashSet[int] =
    inc nextOwner
    result = initHashSet[int]()
    result.incl(nextOwner)

  proc includesInvalid(owners, invalid: HashSet[int];
      seen: var HashSet[int]): bool =
    for owner in owners:
      if owner in invalid: return true
      if owner in seen: continue
      seen.incl(owner)
      if parents.hasKey(owner) and includesInvalid(parents[owner], invalid, seen):
        return true

  proc calleeType(node: ast.Expression): semantic.Type =
    result = nodeType(types, node)
    if result == nil and node != nil and node.tag == "name":
      result = environment.lookup(ast.Name(node).text)

  proc callName(node: ast.Expression): string =
    if node == nil: return ""
    if node.tag == "name": return ast.Name(node).text
    if node.tag == "field": return ast.Field(node).field.text

  proc visitExpr(node: ast.Expression; bindings: Table[string, HashSet[int]];
      invalid: var HashSet[int]): HashSet[int] =
    result = initHashSet[int]()
    if node == nil: return
    case node.tag
    of "name":
      let name = ast.Name(node).text
      if bindings.hasKey(name):
        result = bindings[name]
        var seen = initHashSet[int]()
        if includesInvalid(result, invalid, seen):
          diag.emit(Code.ScopeEscape, node.span,
            "Storage is used after its owner was released, resized, or unmapped")
    of "group": result = visitExpr(ast.Group(node).expr, bindings, invalid)
    of "unary": result = visitExpr(ast.Unary(node).operand, bindings, invalid)
    of "field":
      let owners = visitExpr(ast.Field(node).object, bindings, invalid)
      if storage(nodeType(types, node)): result = owners
    of "index":
      let index = ast.Index(node)
      let owners = visitExpr(index.object, bindings, invalid)
      discard visitExpr(index.index, bindings, invalid)
      if storage(nodeType(types, node)): result = owners
    of "call":
      let call = ast.Call(node)
      var arguments: seq[HashSet[int]]
      for argument in call.args:
        arguments.add(visitExpr(argument, bindings, invalid))
      let signature = calleeType(call.callee)
      let name = callName(call.callee)
      if signature != nil and signature.kind == "function":
        for index in signature.borrows:
          if index < arguments.len:
            result = merge(result, arguments[index])
        if signature.abi == "runtime.dylib" and name == "lookup" and arguments.len > 0:
          result = merge(result, arguments[0])
        for index in signature.releases:
          if index < arguments.len:
            invalid = merge(invalid, arguments[index])
        let consumed = if signature.abi == "runtime.memory" and
            name in ["release", "expand"]: 1
          elif signature.abi == "runtime.memory" and name == "close": 0
          elif signature.abi == "runtime.crypto" and
              name in ["close", "discard", "retire", "forget"]: 0
          elif signature.abi == "runtime.fs" and name in ["unmap", "release"]: 0
          elif signature.abi == "runtime.sequence" and name == "release": 0
          elif signature.abi == "runtime.vm" and name == "release": 0
          elif signature.abi == "runtime.gpu" and name == "dispose": 0
          elif signature.abi == "runtime.dylib" and name in ["close", "discard"]: 0
          else: -1
        if consumed >= 0 and consumed < arguments.len:
          invalid = merge(invalid, arguments[consumed])
    of "binary":
      let binary = ast.Binary(node)
      let owners = merge(visitExpr(binary.left, bindings, invalid),
        visitExpr(binary.right, bindings, invalid))
      if storage(nodeType(types, node)): result = owners
    of "allocation":
      let allocation = ast.Allocation(node)
      discard visitExpr(allocation.size, bindings, invalid)
      discard visitExpr(allocation.owner, bindings, invalid)
    of "sequence-value":
      for item in ast.Values(node).items:
        result = merge(result, visitExpr(item, bindings, invalid))
    else: discard

  proc allocationParent(node: ast.Expression;
      bindings: Table[string, HashSet[int]];
      invalid: var HashSet[int]): HashSet[int] =
    result = initHashSet[int]()
    if node == nil: return
    if node.tag in ["group", "unary"]:
      return allocationParent(if node.tag == "group": ast.Group(node).expr
        else: ast.Unary(node).operand, bindings, invalid)
    if node.tag != "call": return
    let call = ast.Call(node)
    let signature = calleeType(call.callee)
    if signature != nil and signature.abi == "runtime.memory" and
        callName(call.callee) in ["allocate", "reserve", "expand"] and
        call.args.len > 0:
      result = visitExpr(call.args[0], bindings, invalid)

  proc visitBlock(bodyNode: ast.Block; outer: var Table[string, HashSet[int]];
      invalid: var HashSet[int]) =
    var bindings = outer
    let firstReturn = returned.len
    var deferredActions: seq[ast.Expression]
    var deferredBlocks: seq[ast.Block]
    for statement in bodyNode.stmts:
      case statement.tag
      of "constant", "mutable":
        let value = if statement.tag == "constant":
          ast.Constant(statement).value else: ast.Mutable(statement).value
        let name = if statement.tag == "constant":
          ast.Constant(statement).name.text else: ast.Mutable(statement).name.text
        var owners = visitExpr(value, bindings, invalid)
        if owners.len == 0 and storage(nodeType(types, value)):
          owners = fresh()
          let parent = allocationParent(value, bindings, invalid)
          if parent.len > 0:
            for owner in owners: parents[owner] = parent
        bindings[name] = owners
      of "assignment":
        let assignment = ast.Assignment(statement)
        let owners = visitExpr(assignment.value, bindings, invalid)
        discard visitExpr(assignment.target, bindings, invalid)
        if assignment.target.tag == "name":
          bindings[ast.Name(assignment.target).text] = owners
      of "destructure":
        let declaration = ast.Destructure(statement)
        let owners = visitExpr(declaration.value, bindings, invalid)
        for name in declaration.bindings: bindings[name.text] = owners
      of "action":
        let action = ast.Action(statement)
        if action.value != nil:
          discard visitExpr(action.value, bindings, invalid)
        else:
          discard visitExpr(action.name, bindings, invalid)
          for argument in action.args:
            discard visitExpr(argument, bindings, invalid)
      of "give":
        let value = ast.Give(statement).value
        let owners = visitExpr(value, bindings, invalid)
        if storage(nodeType(types, value)) and owners.len > 0:
          returned.add((owners, value.span))
      of "defer":
        let deferred = ast.`Defer`(statement)
        if deferred.error: continue
        if deferred.body != nil and deferred.body.tag == "block":
          deferredBlocks.add(ast.Block(deferred.body))
        else:
          deferredActions.add(ast.Expression(deferred.body))
      of "when":
        let branch = ast.`When`(statement)
        discard visitExpr(branch.cond, bindings, invalid)
        var yes = bindings
        var yesInvalid = invalid
        visitBlock(branch.then, yes, yesInvalid)
        var noInvalid = invalid
        if branch.else != nil:
          var no = bindings
          if branch.else.tag == "block":
            visitBlock(ast.Block(branch.else), no, noInvalid)
          elif branch.else.tag == "when":
            visitBlock(ast.Block(tag: "block", span: branch.else.span,
              stmts: @[ast.Statement(branch.else)]), no, noInvalid)
        invalid = merge(yesInvalid, noInvalid)
      of "match":
        let matchNode = ast.Match(statement)
        let owners = visitExpr(matchNode.scrutinee, bindings, invalid)
        var combined = invalid
        for arm in matchNode.cases:
          var local = bindings
          var armInvalid = invalid
          if arm.pattern != nil and arm.pattern.tag == "variant-pattern":
            let pattern = ast.VariantPattern(arm.pattern)
            if pattern.binding != nil: local[pattern.binding.text] = owners
          discard visitExpr(arm.guard, local, armInvalid)
          visitBlock(arm.body, local, armInvalid)
          combined = merge(combined, armInvalid)
        invalid = combined
      of "while":
        let loop = ast.`While`(statement)
        discard visitExpr(loop.cond, bindings, invalid)
        visitBlock(loop.body, bindings, invalid)
      of "for":
        let loop = ast.`For`(statement)
        var local = bindings
        local[loop.bind.text] = visitExpr(loop.iter, bindings, invalid)
        visitBlock(loop.body, local, invalid)
      of "unsafe": visitBlock(ast.Unsafe(statement).body, bindings, invalid)
      else: discard
    let beforeCleanup = invalid
    for index in countdown(deferredBlocks.high, 0):
      visitBlock(deferredBlocks[index], bindings, invalid)
    for index in countdown(deferredActions.high, 0):
      discard visitExpr(deferredActions[index], bindings, invalid)
    var cleanupInvalid = initHashSet[int]()
    for owner in invalid:
      if owner notin beforeCleanup: cleanupInvalid.incl(owner)
    for index in firstReturn ..< returned.len:
      var seen = initHashSet[int]()
      if includesInvalid(returned[index].owners, cleanupInvalid, seen):
        diag.emit(Code.ScopeEscape, returned[index].span,
          "Returned storage is released by cleanup before the caller can use it")
    for name in outer.keys:
      if bindings.hasKey(name): outer[name] = bindings[name]

  var bindings = initTable[string, HashSet[int]]()
  for parameter in parameters:
    if storage(environment.lookup(parameter)):
      bindings[parameter] = fresh()
  let parameterOwners = bindings
  var invalid = initHashSet[int]()
  visitBlock(body, bindings, invalid)
  for index, parameter in parameters:
    if index notin releases and parameterOwners.hasKey(parameter):
      for owner in parameterOwners[parameter]:
        if owner in invalid:
          diag.emit(Code.ScopeEscape, body.span,
            "Function releases parameter '" & parameter &
              "' without declaring 'releasing " & parameter & "'")
