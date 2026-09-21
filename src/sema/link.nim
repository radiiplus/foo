import std/tables
import ../ast/node as ast
import ./module

proc key(node: ast.Node): pointer = cast[pointer](node)

proc linkedName(node: ast.Node; resolution: Resolution;
    names: Table[pointer, string]): string =
  if node != nil and resolution.resolutions.hasKey(key(node)):
    let symbol = resolution.resolutions[key(node)]
    if names.hasKey(key(symbol.node)): return names[key(symbol.node)]

proc rewriteType(node: ast.`Type`; resolution: Resolution;
    names: Table[pointer, string])
proc rewriteExpression(node: ast.Expression; resolution: Resolution;
    names: Table[pointer, string]): ast.Expression
proc rewriteBlock(node: ast.Block; resolution: Resolution;
    names: Table[pointer, string])

proc rewriteType(node: ast.`Type`; resolution: Resolution;
    names: Table[pointer, string]) =
  if node == nil: return
  let replacement = linkedName(node, resolution, names)
  case node.tag
  of "named":
    if replacement.len > 0: ast.Named(node).name.text = replacement
  of "generic-inst":
    let generic = ast.GenericInst(node)
    if replacement.len > 0: generic.name.text = replacement
    for argument in generic.args: rewriteType(argument, resolution, names)
  of "array": rewriteType(ast.Array(node).elem, resolution, names)
  of "sequence": rewriteType(ast.Sequence(node).elem, resolution, names)
  of "optional": rewriteType(ast.Optional(node).elem, resolution, names)
  of "error": rewriteType(ast.Error(node).elem, resolution, names)
  of "pointer": rewriteType(ast.Pointer(node).elem, resolution, names)
  of "vector": rewriteType(ast.Vector(node).elem, resolution, names)
  of "function-type":
    let functionType = ast.FunctionType(node)
    for parameter in functionType.params: rewriteType(parameter, resolution, names)
    rewriteType(functionType.ret, resolution, names)
  else: discard

proc rewriteExpression(node: ast.Expression; resolution: Resolution;
    names: Table[pointer, string]): ast.Expression =
  if node == nil: return nil
  let replacement = linkedName(node, resolution, names)
  if replacement.len > 0:
    if node.tag == "field":
      return ast.Name(tag: "name", span: node.span, text: replacement)
    if node.tag == "name": ast.Name(node).text = replacement
  case node.tag
  of "call":
    let call = ast.Call(node)
    call.callee = rewriteExpression(call.callee, resolution, names)
    for index in 0 ..< call.args.len:
      call.args[index] = rewriteExpression(call.args[index], resolution, names)
    for argument in call.types: rewriteType(argument, resolution, names)
  of "allocation":
    let allocation = ast.Allocation(node)
    allocation.size = rewriteExpression(allocation.size, resolution, names)
    allocation.owner = rewriteExpression(allocation.owner, resolution, names)
  of "unary":
    let unary = ast.Unary(node)
    unary.operand = rewriteExpression(unary.operand, resolution, names)
  of "binary":
    let binary = ast.Binary(node)
    binary.left = rewriteExpression(binary.left, resolution, names)
    binary.right = rewriteExpression(binary.right, resolution, names)
  of "group":
    let group = ast.Group(node)
    group.expr = rewriteExpression(group.expr, resolution, names)
  of "field":
    let field = ast.Field(node)
    field.object = rewriteExpression(field.object, resolution, names)
  of "index":
    let index = ast.Index(node)
    index.object = rewriteExpression(index.object, resolution, names)
    index.index = rewriteExpression(index.index, resolution, names)
  of "error-chain":
    let chain = ast.ErrorChain(node)
    chain.expr = rewriteExpression(chain.expr, resolution, names)
    chain.context = rewriteExpression(chain.context, resolution, names)
  of "machine":
    let machine = ast.Machine(node)
    machine.target = rewriteExpression(machine.target, resolution, names)
    machine.value = rewriteExpression(machine.value, resolution, names)
    for index in 0 ..< machine.args.len:
      machine.args[index] = rewriteExpression(machine.args[index], resolution, names)
  of "reflect": rewriteType(ast.Reflect(node).type, resolution, names)
  of "embed": rewriteType(ast.Embed(node).type, resolution, names)
  else: discard
  node

proc rewriteStatement(node: ast.Statement; resolution: Resolution;
    names: Table[pointer, string]) =
  if node == nil: return
  if names.hasKey(key(node)):
    let replacement = names[key(node)]
    case node.tag
    of "constant": ast.Constant(node).name.text = replacement
    of "mutable": ast.Mutable(node).name.text = replacement
    of "function": ast.Function(node).name.text = replacement
    of "extern-function":
      let function = ast.ExternFunction(node)
      if function.symbol.len == 0: function.symbol = function.name.text
      function.name.text = replacement
    of "alias": ast.Alias(node).name.text = replacement
    else: discard
  case node.tag
  of "constant":
    let declaration = ast.Constant(node)
    rewriteType(declaration.type, resolution, names)
    declaration.value = rewriteExpression(declaration.value, resolution, names)
  of "mutable":
    let declaration = ast.Mutable(node)
    rewriteType(declaration.type, resolution, names)
    declaration.value = rewriteExpression(declaration.value, resolution, names)
  of "function":
    let function = ast.Function(node)
    for parameter in function.params: rewriteType(parameter.type, resolution, names)
    rewriteType(function.returnType, resolution, names)
    rewriteBlock(function.body, resolution, names)
  of "extern-function":
    let function = ast.ExternFunction(node)
    for parameter in function.params: rewriteType(parameter.type, resolution, names)
    rewriteType(function.returnType, resolution, names)
  of "alias":
    let alias = ast.Alias(node)
    if alias.body != nil:
      case alias.body.tag
      of "record":
        for field in ast.Record(alias.body).fields: rewriteType(field.type, resolution, names)
      of "union":
        for field in ast.Union(alias.body).fields: rewriteType(field.type, resolution, names)
      of "choice":
        for variant in ast.Choice(alias.body).variants: rewriteType(variant.payload, resolution, names)
      of "opaque": discard
      else: rewriteType(alias.body, resolution, names)
  of "give":
    let statement = ast.Give(node)
    statement.value = rewriteExpression(statement.value, resolution, names)
  of "when":
    let statement = ast.`When`(node)
    statement.cond = rewriteExpression(statement.cond, resolution, names)
    rewriteBlock(statement.then, resolution, names)
    if statement.else != nil:
      if statement.else.tag == "block": rewriteBlock(ast.Block(statement.else), resolution, names)
      else: rewriteStatement(statement.else, resolution, names)
  of "while":
    let statement = ast.`While`(node)
    statement.cond = rewriteExpression(statement.cond, resolution, names)
    rewriteBlock(statement.body, resolution, names)
  of "repeat":
    let statement = ast.Repeat(node)
    statement.target = ast.Name(rewriteExpression(statement.target, resolution, names))
    statement.limit = rewriteExpression(statement.limit, resolution, names)
    rewriteBlock(statement.body, resolution, names)
  of "for":
    let statement = ast.`For`(node)
    statement.iter = rewriteExpression(statement.iter, resolution, names)
    rewriteBlock(statement.body, resolution, names)
  of "match":
    let statement = ast.Match(node)
    statement.scrutinee = rewriteExpression(statement.scrutinee, resolution, names)
    for arm in statement.cases:
      arm.guard = rewriteExpression(arm.guard, resolution, names)
      rewriteBlock(arm.body, resolution, names)
  of "assignment":
    let statement = ast.Assignment(node)
    statement.target = rewriteExpression(statement.target, resolution, names)
    statement.value = rewriteExpression(statement.value, resolution, names)
  of "try":
    let statement = ast.`Try`(node)
    statement.expr = rewriteExpression(statement.expr, resolution, names)
  of "defer":
    let statement = ast.`Defer`(node)
    if statement.body != nil:
      if statement.body.tag == "block": rewriteBlock(ast.Block(statement.body), resolution, names)
      else: statement.body = rewriteExpression(statement.body, resolution, names)
  of "unsafe": rewriteBlock(ast.Unsafe(node).body, resolution, names)
  of "test": rewriteBlock(ast.TestBlock(node).body, resolution, names)
  of "eval": rewriteBlock(ast.EvalBlock(node).body, resolution, names)
  of "action":
    let statement = ast.Action(node)
    if statement.value != nil:
      statement.value = rewriteExpression(statement.value, resolution, names)
    else:
      statement.name = ast.Name(rewriteExpression(statement.name, resolution, names))
      for index in 0 ..< statement.args.len:
        statement.args[index] = rewriteExpression(statement.args[index], resolution, names)
  of "machine": discard rewriteExpression(node, resolution, names)
  of "advance":
    let statement = ast.AdvanceStatement(node)
    statement.target = ast.Name(rewriteExpression(statement.target, resolution, names))
  else: discard

proc rewriteBlock(node: ast.Block; resolution: Resolution;
    names: Table[pointer, string]) =
  if node == nil: return
  for statement in node.stmts: rewriteStatement(statement, resolution, names)

proc link*(entry: Program; resolution: Resolution): Program =
  if entry.units.len == 0: return entry
  var names = initTable[pointer, string]()
  var importedIndex = 0
  for moduleName in resolution.order:
    if not resolution.units.hasKey(moduleName): continue
    let semanticUnit = resolution.units[moduleName]
    var isEntry = false
    for unit in entry.units:
      if unit == semanticUnit.node: isEntry = true
    let prefix = if isEntry: "" else: "import_" & $importedIndex & "_"
    if not isEntry: inc importedIndex
    for statement in semanticUnit.node.body.stmts:
      case statement.tag
      of "constant": names[key(statement)] = prefix & ast.Constant(statement).name.text
      of "mutable": names[key(statement)] = prefix & ast.Mutable(statement).name.text
      of "function": names[key(statement)] = prefix & ast.Function(statement).name.text
      of "extern-function": names[key(statement)] = prefix & ast.ExternFunction(statement).name.text
      of "alias": names[key(statement)] = prefix & ast.Alias(statement).name.text
      else: discard

  var modules: seq[ast.Unit]
  for moduleName in resolution.order:
    if resolution.units.hasKey(moduleName): modules.add(resolution.units[moduleName].node)
  for unit in entry.units:
    if unit notin modules: modules.add(unit)
  var statements: seq[Statement]
  for unit in modules:
    for statement in unit.body.stmts:
      if statement.tag != "use":
        rewriteStatement(statement, resolution, names)
        var imported = true
        for entryUnit in entry.units:
          if unit == entryUnit: imported = false
        if imported:
          case statement.tag
          of "constant": ast.Constant(statement).public = false
          of "mutable": ast.Mutable(statement).public = false
          of "function": ast.Function(statement).public = false
          of "extern-function": ast.ExternFunction(statement).public = false
          of "alias": ast.Alias(statement).public = false
          else: discard
        statements.add(statement)
  let first = entry.units[0]
  Program(tag: "program", span: entry.span, units: @[
    ast.Unit(tag: "unit", span: first.span, name: first.name, file: first.file,
      body: Block(tag: "block", span: first.body.span, stmts: statements))
  ])
