import std/tables
import ../ast/node as ast
import ./module

proc key(node: ast.Node): pointer = cast[pointer](node)

proc linked(node: ast.Node; resolution: Resolution;
    names: Table[pointer, string]): string =
  if node != nil and resolution.resolutions.hasKey(key(node)):
    let symbol = resolution.resolutions[key(node)]
    if names.hasKey(key(symbol.node)): return names[key(symbol.node)]

proc typed(node: ast.`Type`; resolution: Resolution;
    names: Table[pointer, string])
proc expression(node: ast.Expression; resolution: Resolution;
    names: Table[pointer, string]): ast.Expression
proc body(node: ast.Block; resolution: Resolution;
    names: Table[pointer, string])

proc pattern(node: ast.Pattern; resolution: Resolution;
    names: Table[pointer, string]) =
  if node == nil: return
  case node.tag
  of "name":
    let replacement = linked(node, resolution, names)
    if replacement.len > 0: ast.Name(node).text = replacement
  of "variant-pattern":
    let pattern = ast.Arm(node)
    let replacement = linked(pattern.name, resolution, names)
    if replacement.len > 0: pattern.name.text = replacement
  else: discard

proc typed(node: ast.`Type`; resolution: Resolution;
    names: Table[pointer, string]) =
  if node == nil: return
  let replacement = linked(node, resolution, names)
  case node.tag
  of "named":
    if replacement.len > 0: ast.Named(node).name.text = replacement
  of "generic-inst":
    let generic = ast.Instantiation(node)
    if replacement.len > 0: generic.name.text = replacement
    for argument in generic.args: typed(argument, resolution, names)
  of "sequence": typed(ast.Sequence(node).elem, resolution, names)
  of "optional": typed(ast.Optional(node).elem, resolution, names)
  of "error": typed(ast.Error(node).elem, resolution, names)
  of "pointer": typed(ast.Pointer(node).elem, resolution, names)
  of "vector": typed(ast.Vector(node).elem, resolution, names)
  of "function-type":
    let representation = ast.Signature(node)
    for parameter in representation.params: typed(parameter, resolution, names)
    typed(representation.ret, resolution, names)
  else: discard

proc expression(node: ast.Expression; resolution: Resolution;
    names: Table[pointer, string]): ast.Expression =
  if node == nil: return nil
  let replacement = linked(node, resolution, names)
  if replacement.len > 0:
    if node.tag == "field":
      return ast.Name(tag: "name", span: node.span, text: replacement)
    if node.tag == "name": ast.Name(node).text = replacement
  case node.tag
  of "call":
    let call = ast.Call(node)
    call.callee = expression(call.callee, resolution, names)
    for index in 0 ..< call.args.len:
      call.args[index] = expression(call.args[index], resolution, names)
    for argument in call.types: typed(argument, resolution, names)
  of "sequence-value":
    let sequence = ast.Values(node)
    for index in 0 ..< sequence.items.len:
      sequence.items[index] = expression(sequence.items[index], resolution, names)
  of "closure":
    let closure = ast.Closure(node)
    for parameter in closure.params: typed(parameter.type, resolution, names)
    typed(closure.returns, resolution, names)
    for index in 0 ..< closure.captures.len:
      closure.captures[index] = ast.Name(expression(closure.captures[index], resolution, names))
    body(closure.body, resolution, names)
  of "allocation":
    let allocation = ast.Allocation(node)
    allocation.size = expression(allocation.size, resolution, names)
    allocation.owner = expression(allocation.owner, resolution, names)
  of "unary":
    let unary = ast.Unary(node)
    unary.operand = expression(unary.operand, resolution, names)
  of "binary":
    let binary = ast.Binary(node)
    binary.left = expression(binary.left, resolution, names)
    binary.right = expression(binary.right, resolution, names)
  of "group":
    let group = ast.Group(node)
    group.expr = expression(group.expr, resolution, names)
  of "field":
    let field = ast.Field(node)
    field.object = expression(field.object, resolution, names)
  of "index":
    let index = ast.Index(node)
    index.object = expression(index.object, resolution, names)
    index.index = expression(index.index, resolution, names)
  of "machine":
    let machine = ast.Machine(node)
    machine.target = expression(machine.target, resolution, names)
    machine.value = expression(machine.value, resolution, names)
    for index in 0 ..< machine.args.len:
      machine.args[index] = expression(machine.args[index], resolution, names)
  of "reflect": typed(ast.Reflect(node).type, resolution, names)
  of "embed": typed(ast.Embed(node).type, resolution, names)
  else: discard
  node

proc statement(node: ast.Statement; resolution: Resolution;
    names: Table[pointer, string]) =
  if node == nil: return
  if names.hasKey(key(node)):
    let replacement = names[key(node)]
    case node.tag
    of "constant": ast.Constant(node).name.text = replacement
    of "mutable": ast.Mutable(node).name.text = replacement
    of "function": ast.Function(node).name.text = replacement
    of "extern-function":
      let function = ast.External(node)
      if function.symbol.len == 0: function.symbol = function.name.text
      function.name.text = replacement
    of "alias": ast.Alias(node).name.text = replacement
    else: discard
  case node.tag
  of "constant":
    let declaration = ast.Constant(node)
    typed(declaration.type, resolution, names)
    declaration.value = expression(declaration.value, resolution, names)
  of "mutable":
    let declaration = ast.Mutable(node)
    typed(declaration.type, resolution, names)
    declaration.value = expression(declaration.value, resolution, names)
  of "destructure":
    let declaration = ast.Destructure(node)
    typed(declaration.record, resolution, names)
    declaration.value = expression(declaration.value, resolution, names)
    for binding in declaration.bindings:
      if names.hasKey(key(binding)): binding.text = names[key(binding)]
  of "function":
    let function = ast.Function(node)
    for parameter in function.params: typed(parameter.type, resolution, names)
    typed(function.returns, resolution, names)
    function.guard = expression(function.guard, resolution, names)
    body(function.body, resolution, names)
  of "extern-function":
    let function = ast.External(node)
    for parameter in function.params: typed(parameter.type, resolution, names)
    typed(function.returns, resolution, names)
  of "alias":
    let alias = ast.Alias(node)
    if alias.body != nil:
      case alias.body.tag
      of "record":
        for field in ast.Record(alias.body).fields: typed(field.type, resolution, names)
      of "union":
        for field in ast.Union(alias.body).fields: typed(field.type, resolution, names)
      of "choice":
        for variant in ast.Choice(alias.body).variants:
          typed(variant.payload, resolution, names)
          if names.hasKey(key(variant)): variant.name.text = names[key(variant)]
      of "opaque": discard
      else: typed(alias.body, resolution, names)
  of "give":
    let statement = ast.Give(node)
    statement.value = expression(statement.value, resolution, names)
  of "when":
    let statement = ast.`When`(node)
    statement.cond = expression(statement.cond, resolution, names)
    body(statement.then, resolution, names)
    if statement.else != nil:
      if statement.else.tag == "block": body(ast.Block(statement.else), resolution, names)
      else: statement(statement.else, resolution, names)
  of "while":
    let statement = ast.`While`(node)
    statement.cond = expression(statement.cond, resolution, names)
    body(statement.body, resolution, names)
  of "for":
    let statement = ast.`For`(node)
    statement.iter = expression(statement.iter, resolution, names)
    body(statement.body, resolution, names)
  of "match":
    let statement = ast.Match(node)
    statement.scrutinee = expression(statement.scrutinee, resolution, names)
    for arm in statement.cases:
      pattern(arm.pattern, resolution, names)
      arm.guard = expression(arm.guard, resolution, names)
      body(arm.body, resolution, names)
  of "assignment":
    let statement = ast.Assignment(node)
    statement.target = expression(statement.target, resolution, names)
    statement.value = expression(statement.value, resolution, names)
  of "defer":
    let statement = ast.`Defer`(node)
    if statement.body != nil:
      if statement.body.tag == "block": body(ast.Block(statement.body), resolution, names)
      else: statement.body = expression(statement.body, resolution, names)
  of "unsafe": body(ast.Unsafe(node).body, resolution, names)
  of "test": body(ast.Test(node).body, resolution, names)
  of "eval": body(ast.Evaluation(node).body, resolution, names)
  of "action":
    let statement = ast.Action(node)
    if statement.value != nil:
      statement.value = expression(statement.value, resolution, names)
    else:
      statement.name = ast.Name(expression(statement.name, resolution, names))
      for index in 0 ..< statement.args.len:
        statement.args[index] = expression(statement.args[index], resolution, names)
  of "machine": discard expression(node, resolution, names)
  else: discard

proc body(node: ast.Block; resolution: Resolution;
    names: Table[pointer, string]) =
  if node == nil: return
  for statement in node.stmts: statement(statement, resolution, names)

proc link*(entry: Program; resolution: Resolution): Program =
  if entry.units.len == 0: return entry
  var names = initTable[pointer, string]()
  var position = 0
  for module in resolution.order:
    if not resolution.units.hasKey(module): continue
    let semantic = resolution.units[module]
    var starting = false
    for unit in entry.units:
      if unit == semantic.node: starting = true
    let prefix = if starting: "" else: "import_" & $position & "_"
    if not starting: inc position
    for statement in semantic.node.body.stmts:
      case statement.tag
      of "constant": names[key(statement)] = prefix & ast.Constant(statement).name.text
      of "mutable": names[key(statement)] = prefix & ast.Mutable(statement).name.text
      of "destructure":
        for binding in ast.Destructure(statement).bindings:
          names[key(binding)] = prefix & binding.text
      of "function": names[key(statement)] = prefix & ast.Function(statement).name.text
      of "extern-function": names[key(statement)] = prefix & ast.External(statement).name.text
      of "alias":
        let declaration = ast.Alias(statement)
        names[key(statement)] = prefix & declaration.name.text
        if declaration.body != nil and declaration.body.tag == "choice":
          for variant in ast.Choice(declaration.body).variants:
            names[key(variant)] = prefix & variant.name.text
      else: discard

  var modules: seq[ast.Unit]
  for module in resolution.order:
    if resolution.units.hasKey(module): modules.add(resolution.units[module].node)
  for unit in entry.units:
    if unit notin modules: modules.add(unit)
  var statements: seq[Statement]
  for unit in modules:
    for statement in unit.body.stmts:
      if statement.tag != "use":
        statement(statement, resolution, names)
        var imported = true
        for startup in entry.units:
          if unit == startup: imported = false
        if imported:
          case statement.tag
          of "constant": ast.Constant(statement).public = false
          of "mutable": ast.Mutable(statement).public = false
          of "function": ast.Function(statement).public = false
          of "extern-function": ast.External(statement).public = false
          of "alias": ast.Alias(statement).public = false
          else: discard
        statements.add(statement)
  let first = entry.units[0]
  Program(tag: "program", span: entry.span, units: @[
    ast.Unit(tag: "unit", span: first.span, name: first.name, file: first.file,
      body: Block(tag: "block", span: first.body.span, stmts: statements))
  ])
