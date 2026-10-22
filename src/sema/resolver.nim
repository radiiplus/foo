import std/[json, os, sets, strutils, tables]
import ../ast/node as ast
import ../diag/[code, engine]
import ../lex/lexer
import ../ast/parser
import ./[form, module, scope, symbol]
import ../config/project as configuration

type
  Reading* = tuple[found: bool, source: string]
  Reader* = proc(path: string): Reading {.closure.}
  Parser* = proc(path, source: string; diagnostics: Engine): ast.Program {.closure.}

  Resolver* = ref object
    diag: Engine
    root: string
    directory: string
    library: string
    units: Table[string, module.Unit]
    order: seq[string]
    resolutions: Table[pointer, Symbol]
    cache: Table[string, ast.Program]
    loading: HashSet[string]
    imported: Table[string, HashSet[string]]
    read: Reader
    decoder: Parser

proc fallback(path: string): Reading =
  if fileExists(path): (true, readFile(path)) else: (false, "")

proc bundled(): string =
  let configured = getEnv("FOO_LIB")
  if configured.len > 0 and dirExists(configured): return absolutePath(configured)
  for candidate in [getAppDir().parentDir / "lib",
      getAppDir().parentDir.parentDir / "lib",
      currentSourcePath.parentDir.parentDir.parentDir / "lib"]:
    if dirExists(candidate): return absolutePath(candidate)
  absolutePath(getCurrentDir() / "lib")

proc resolver*(diag: Engine; root: string; library = "";
    read: Reader = nil; parse: Parser = nil): Resolver =
  let absolute = absolutePath(root)
  var source = "src"
  try:
    let manifest = configuration.readProject(absolute)
    let configured = manifest.getOrDefault("source").getStr()
    if configured.len > 0: source = configured
  except CatchableError:
    discard
  Resolver(
    diag: diag,
    root: absolute,
    directory: absolutePath(absolute / source),
    library: if library.len > 0: absolutePath(library) else: bundled(),
    units: initTable[string, module.Unit](),
    resolutions: initTable[pointer, Symbol](),
    cache: initTable[string, ast.Program](),
    loading: initHashSet[string](),
    imported: initTable[string, HashSet[string]](),
    read: if read == nil: fallback else: read,
    decoder: parse)

proc key(node: ast.Node): pointer = cast[pointer](node)

proc insert(resolver: Resolver; target: Scope; name: string; form: Form;
    visible: bool; node: ast.Node; module: string) =
  let item = Symbol(name: name, form: form, visible: visible, node: node,
    module: module, qualified: module & "::" & name)
  if not target.insert(name, item):
    let original = target.local(name)
    if form == Form.Function and original.found and
        original.symbol.form == Form.Function:
      return
    resolver.diag.emit(Code.Duplicate, node.span, "duplicate symbol '" & name & "'")
    if original.found:
      resolver.diag.related(original.symbol.node.span, "First declared here")

proc typed(resolver: Resolver; node: ast.`Type`; target: Scope;
    module: string)
proc expression(resolver: Resolver; node: ast.Expression; target: Scope;
    module: string)
proc statement(resolver: Resolver; node: ast.Statement; target: Scope;
    module: string)
proc body(resolver: Resolver; node: ast.Block; target: Scope;
    module: string; child = true)
proc load(resolver: Resolver; name, path: string): ast.Program
proc unit(resolver: Resolver; node: ast.Unit; name, file: string)

proc missing(resolver: Resolver; name: string; node: ast.Node) =
  resolver.diag.emit(Code.Missing, node.span, "undefined symbol '" & name & "'")

proc typed(resolver: Resolver; node: ast.`Type`; target: Scope;
    module: string) =
  if node == nil: return
  case node.tag
  of "named":
    let named = ast.Named(node)
    if named.name.text in ["Error", "Allocator"] and not target.lookup(named.name.text).found:
      return
    let found = target.lookup(named.name.text)
    if not found.found:
      resolver.diag.emit(Code.Missing, named.name.span,
        "undefined type '" & named.name.text & "'")
    elif found.symbol.form != Form.Type:
      resolver.diag.emit(Code.Missing, named.name.span,
        "'" & named.name.text & "' is not a type")
    else:
      resolver.resolutions[key(node)] = found.symbol
  of "generic-inst":
    let generic = ast.Instantiation(node)
    let found = target.lookup(generic.name.text)
    if not found.found or found.symbol.form != Form.Type:
      resolver.diag.emit(Code.Missing, node.span,
        "Undefined type '" & generic.name.text & "'")
    else:
      resolver.resolutions[key(node)] = found.symbol
    for argument in generic.args:
      resolver.typed(argument, target, module)
  of "optional": resolver.typed(ast.Optional(node).elem, target, module)
  of "error": resolver.typed(ast.Error(node).elem, target, module)
  of "pointer": resolver.typed(ast.Pointer(node).elem, target, module)
  of "sequence": resolver.typed(ast.Sequence(node).elem, target, module)
  of "vector": resolver.typed(ast.Vector(node).elem, target, module)
  of "function-type":
    let representation = ast.Signature(node)
    for parameter in representation.params:
      resolver.typed(parameter, target, module)
    resolver.typed(representation.ret, target, module)
  else: discard

proc expression(resolver: Resolver; node: ast.Expression; target: Scope;
    module: string) =
  if node == nil: return
  case node.tag
  of "name":
    let name = ast.Name(node)
    let found = target.lookup(name.text)
    if found.found: resolver.resolutions[key(node)] = found.symbol
    else: resolver.missing(name.text, node)
  of "call":
    let call = ast.Call(node)
    for typ in call.types: resolver.typed(typ, target, module)
    if call.callee.tag != "name" or ast.Name(call.callee).text notin ["splat", "shuffle", "permute", "gather", "scatter", "select", "reduce", "fail", "bit", "lengthof"]:
      resolver.expression(call.callee, target, module)
    for argument in call.args: resolver.expression(argument, target, module)
  of "sequence-value":
    for item in ast.Values(node).items:
      resolver.expression(item, target, module)
  of "closure":
    let closure = ast.Closure(node)
    let frame = scope(target)
    for capture in closure.captures:
      resolver.expression(capture, target, module)
    for parameter in closure.params:
      resolver.typed(parameter.type, frame, module)
      resolver.insert(frame, parameter.name.text, Form.Parameter,
        false, parameter, module)
    resolver.typed(closure.returns, frame, module)
    resolver.body(closure.body, frame, module, false)
  of "unary": resolver.expression(ast.Unary(node).operand, target, module)
  of "binary":
    resolver.expression(ast.Binary(node).left, target, module)
    resolver.expression(ast.Binary(node).right, target, module)
  of "group": resolver.expression(ast.Group(node).expr, target, module)
  of "field":
    let field = ast.Field(node)
    if field.object.tag == "name":
      let qualifier = ast.Name(field.object).text
      let qualified = target.lookup(qualifier & "." & field.field.text)
      if qualified.found:
        resolver.resolutions[key(node)] = qualified.symbol
        return
      if qualifier == "Error" and not target.lookup("Error").found: return
    resolver.expression(field.object, target, module)
  of "index":
    resolver.expression(ast.Index(node).object, target, module)
    resolver.expression(ast.Index(node).index, target, module)
  of "allocation":
    resolver.expression(ast.Allocation(node).size, target, module)
    resolver.expression(ast.Allocation(node).owner, target, module)
  of "machine":
    let machine = ast.Machine(node)
    resolver.expression(machine.target, target, module)
    resolver.expression(machine.value, target, module)
    for argument in machine.args: resolver.expression(argument, target, module)
  of "reflect": resolver.typed(ast.Reflect(node).type, target, module)
  of "embed": resolver.typed(ast.Embed(node).type, target, module)
  else: discard

proc declare(resolver: Resolver; node: ast.Statement; target: Scope;
    module: string) =
  case node.tag
  of "constant":
    let declaration = ast.Constant(node)
    resolver.insert(target, declaration.name.text, Form.Constant,
      declaration.public, node, module)
  of "mutable":
    let declaration = ast.Mutable(node)
    resolver.insert(target, declaration.name.text, Form.Mutable,
      declaration.public, node, module)
  of "destructure":
    for binding in ast.Destructure(node).bindings:
      resolver.insert(target, binding.text, Form.Constant,
        false, binding, module)
  of "function":
    let declaration = ast.Function(node)
    for attribute in declaration.attributes:
      if attribute notin ["start", "interrupt", "naked", "noinline"] and
          not attribute.startsWith("target_feature(\"") and
          not attribute.startsWith("borrows(") and
          not attribute.startsWith("releases("):
        resolver.diag.emit(Code.Invalid, node.span,
          "unknown function option '" & attribute & "'")
    if "start" in declaration.attributes and declaration.params.len > 0:
      resolver.diag.emit(Code.Invalid, node.span,
        "A function used for startup cannot take parameters")
    resolver.insert(target, declaration.name.text, Form.Function,
      declaration.public, node, module)
  of "extern-function":
    let declaration = ast.External(node)
    resolver.insert(target, declaration.name.text, Form.Function,
      declaration.public, node, module)
  of "alias":
    let declaration = ast.Alias(node)
    resolver.insert(target, declaration.name.text, Form.Type,
      declaration.public, node, module)
    if declaration.body != nil and declaration.body.tag == "record":
      var seen = initHashSet[string]()
      for field in ast.Record(declaration.body).fields:
        if field.name.text in seen:
          resolver.diag.emit(Code.Clash, field.name.span,
            "duplicate field '" & field.name.text & "' in record")
        seen.incl(field.name.text)
    elif declaration.body != nil and declaration.body.tag == "choice":
      var names = initHashSet[string]()
      var values = initHashSet[string]()
      for variant in ast.Choice(declaration.body).variants:
        if variant.name.text in names:
          resolver.diag.emit(Code.Clash, variant.name.span,
            "duplicate variant '" & variant.name.text & "' in choice")
        names.incl(variant.name.text)
        resolver.insert(target, variant.name.text, Form.Variant,
          declaration.public, variant, module)
        if variant.value != nil:
          if variant.payload != nil:
            resolver.diag.emit(Code.Invalid, variant.span,
              "payload variant '" & variant.name.text & "' cannot also declare an integer discriminant")
          if variant.value.value in values:
            resolver.diag.emit(Code.Clash, variant.name.span,
              "duplicate value " & variant.value.value & " in choice")
          values.incl(variant.value.value)
  else: discard

proc collect(resolver: Resolver; node: ast.Statement; target: Scope;
    module: string) =
  case node.tag
  of "constant":
    resolver.insert(target, ast.Constant(node).name.text, Form.Constant,
      false, node, module)
  of "mutable":
    resolver.insert(target, ast.Mutable(node).name.text, Form.Mutable,
      false, node, module)
  of "destructure":
    for binding in ast.Destructure(node).bindings:
      resolver.insert(target, binding.text, Form.Constant,
        false, binding, module)
  else: discard

proc body(resolver: Resolver; node: ast.Block; target: Scope;
    module: string; child = true) =
  if node == nil: return
  let environment = if child: scope(target) else: target
  for descendant in node.stmts:
    if descendant.tag == "alias": resolver.declare(descendant, environment, module)
  for descendant in node.stmts:
    resolver.statement(descendant, environment, module)
    if descendant.tag in ["constant", "mutable", "destructure"]:
      resolver.collect(descendant, environment, module)

proc functionality(resolver: Resolver; node: ast.Function; parent: Scope;
    module: string) =
  let activation = scope(parent)
  for parameter in node.generics:
    resolver.insert(activation, parameter.name.text, Form.Type,
      false, parameter, module)
  for parameter in node.params:
    resolver.insert(activation, parameter.name.text, Form.Parameter,
      false, parameter, module)
    resolver.typed(parameter.type, activation, module)
    resolver.expression(parameter.default, activation, module)
  resolver.typed(node.returns, activation, module)
  resolver.expression(node.guard, activation, module)
  resolver.body(node.body, activation, module, false)

proc module(resolver: Resolver; path: string): string =
  var relative = relativePath(absolutePath(path), resolver.root)
  if relative.endsWith(".iv"): relative.setLen(relative.len - 3)
  relative = relative.replace('\\', ':').replace('/', ':')
  while "::" in relative: relative = relative.replace("::", ":")
  let spelling = lastPathPart(resolver.root)
  spelling & "::" & relative.replace(":", "::")

proc package(resolver: Resolver; name: string): string =
  let workspace = resolver.root / ".foo" / "packages" / name
  if not configuration.manifestExists(workspace): return
  try:
    let manifest = configuration.readProject(workspace)
    var relative = manifest.getOrDefault("entry").getStr()
    if relative.len == 0:
      let source = manifest.getOrDefault("source").getStr()
      relative = if source.len > 0: source / "main.iv" else: "main.iv"
    if not relative.endsWith(".iv"): relative.add(".iv")
    let candidate = absolutePath(workspace / relative)
    let confined = relativePath(candidate, workspace).replace('\\', '/')
    if confined == ".." or confined.startsWith("../") or confined.isAbsolute: return
    if resolver.read(candidate).found: return candidate
  except CatchableError:
    discard

proc path(resolver: Resolver; use: ast.Use; current: string): string =
  let location = if resolver.units.hasKey(current): resolver.units[current].file else: resolver.root / "main.iv"
  if use.path.len > 0:
    var path = use.path
    if not path.endsWith(".iv"): path.add(".iv")
    if path.isAbsolute: path else: absolutePath(parentDir(location) / path)
  else:
    let local = parentDir(location) / (use.name.text & ".iv")
    if resolver.read(local).found and absolutePath(local) != absolutePath(location):
      return local
    let project = resolver.directory / (use.name.text & ".iv")
    if resolver.read(project).found and absolutePath(project) != absolutePath(location):
      return project
    let package = resolver.package(use.name.text)
    if package.len > 0: return package
    resolver.library / (use.name.text & ".iv")

proc symbols(resolver: Resolver; name: string): seq[Symbol] =
  if not resolver.units.hasKey(name): return
  let semantic = resolver.units[name]
  var seen = initHashSet[string]()
  for node in semantic.node.body.stmts:
    let found = case node.tag
      of "constant": semantic.scope.local(ast.Constant(node).name.text)
      of "mutable": semantic.scope.local(ast.Mutable(node).name.text)
      of "function": semantic.scope.local(ast.Function(node).name.text)
      of "extern-function": semantic.scope.local(ast.External(node).name.text)
      of "alias": semantic.scope.local(ast.Alias(node).name.text)
      else: (found: false, symbol: Symbol())
    if found.found and found.symbol.qualified notin seen:
      seen.incl(found.symbol.qualified)
      result.add(found.symbol)
    if node.tag == "alias":
      let declaration = ast.Alias(node)
      if declaration.public and declaration.body != nil and
          declaration.body.tag == "choice":
        for variant in ast.Choice(declaration.body).variants:
          let constructor = semantic.scope.local(variant.name.text)
          if constructor.found and constructor.symbol.qualified notin seen:
            seen.incl(constructor.symbol.qualified)
            result.add(constructor.symbol)
    if node.tag == "use" and ast.Use(node).public:
      let imported = ast.Use(node)
      if imported.alias == nil and
          semantic.imports.hasKey(imported.name.text):
        for symbol in resolver.symbols(semantic.imports[imported.name.text]):
          if symbol.visible and symbol.qualified notin seen:
            seen.incl(symbol.qualified)
            result.add(symbol)

proc imported(resolver: Resolver; use: ast.Use; target: Scope;
    current: string) =
  if use.public and use.alias != nil:
    resolver.diag.emit(Code.Invalid, use.span,
      "A public use cannot have an alias")
    resolver.diag.suggestion("Remove the alias or publish forwarding declarations")
    return
  let path = resolver.path(use, current)
  let identifier = resolver.module(path)
  if identifier in resolver.imported[current]:
    resolver.diag.emit(Code.Duplicate, use.name.span,
      "module '" & identifier & "' already imported")
    return
  resolver.imported[current].incl(identifier)
  if identifier in resolver.loading:
    resolver.diag.emit(Code.Circular, use.span,
      "Circular use dependency: " & identifier)
    return
  let source = resolver.read(path)
  if not source.found:
    resolver.diag.emit(Code.Absent, use.span,
      "Use target '" & (if use.path.len > 0: use.path else: use.name.text) & "' was not found")
    return
  let qualifier = if use.alias != nil: use.alias.text else: use.name.text
  if resolver.units[current].imports.hasKey(qualifier) or target.local(qualifier).found:
    resolver.diag.emit(Code.Duplicate, use.span,
      "Import name '" & qualifier & "' is already declared")
    return
  resolver.units[current].imports[qualifier] = identifier
  discard resolver.load(identifier, path)
  for imported in resolver.symbols(identifier):
    if imported.visible:
      let locals = if use.alias != nil: @[qualifier & "." & imported.name]
        else: @[imported.name, qualifier & "." & imported.name]
      for local in locals:
        if not target.insert(local, imported):
          resolver.diag.emit(Code.Duplicate, use.name.span,
            "symbol '" & local & "' conflicts with existing symbol")
          resolver.diag.suggestion("Use 'as name' to qualify this import")

proc statement(resolver: Resolver; node: ast.Statement; target: Scope;
    module: string) =
  if node == nil: return
  case node.tag
  of "constant":
    resolver.typed(ast.Constant(node).type, target, module)
    resolver.expression(ast.Constant(node).value, target, module)
  of "mutable":
    resolver.typed(ast.Mutable(node).type, target, module)
    resolver.expression(ast.Mutable(node).value, target, module)
  of "destructure":
    let destructure = ast.Destructure(node)
    resolver.typed(destructure.record, target, module)
    resolver.expression(destructure.value, target, module)
  of "function": resolver.functionality(ast.Function(node), target, module)
  of "extern-function":
    let function = ast.External(node)
    let activation = scope(target)
    for parameter in function.generics:
      resolver.insert(activation, parameter.name.text, Form.Type, false, parameter, module)
    for parameter in function.params: resolver.typed(parameter.type, activation, module)
    resolver.typed(function.returns, activation, module)
  of "alias":
    let alias = ast.Alias(node)
    let context = scope(target)
    for parameter in alias.generics:
      resolver.insert(context, parameter.name.text, Form.Type, false, parameter, module)
    if alias.body != nil:
      case alias.body.tag
      of "record":
        for field in ast.Record(alias.body).fields: resolver.typed(field.type, context, module)
      of "union":
        for field in ast.Union(alias.body).fields: resolver.typed(field.type, context, module)
      of "choice":
        for variant in ast.Choice(alias.body).variants: resolver.typed(variant.payload, context, module)
      of "opaque": discard
      else: resolver.typed(alias.body, context, module)
  of "use": resolver.imported(ast.Use(node), target, module)
  of "give": resolver.expression(ast.Give(node).value, target, module)
  of "when":
    let branch = ast.`When`(node)
    resolver.expression(branch.cond, target, module)
    resolver.body(branch.then, target, module)
    if branch.else != nil:
      if branch.else.tag == "when": resolver.statement(branch.else, target, module)
      else: resolver.body(ast.Block(branch.else), target, module)
  of "while":
    resolver.expression(ast.`While`(node).cond, target, module)
    resolver.body(ast.`While`(node).body, target, module)
  of "for":
    let loop = ast.`For`(node)
    resolver.expression(loop.iter, target, module)
    let iteration = scope(target)
    resolver.insert(iteration, loop.bind.text, Form.Parameter, false, node, module)
    resolver.body(loop.body, iteration, module)
  of "match":
    let match = ast.Match(node)
    resolver.expression(match.scrutinee, target, module)
    for arm in match.cases:
      let boundary = scope(target)
      if arm.pattern != nil and arm.pattern.tag == "name" and ast.Name(arm.pattern).text != "_":
        resolver.expression(arm.pattern, boundary, module)
      elif arm.pattern != nil and arm.pattern.tag == "variant-pattern":
        let pattern = ast.Arm(arm.pattern)
        resolver.expression(pattern.name, boundary, module)
        if pattern.binding != nil:
          resolver.insert(boundary, pattern.binding.text, Form.Parameter, false, pattern.binding, module)
      resolver.expression(arm.guard, boundary, module)
      resolver.body(arm.body, boundary, module)
  of "assignment":
    resolver.expression(ast.Assignment(node).target, target, module)
    resolver.expression(ast.Assignment(node).value, target, module)
  of "defer":
    let deferred = ast.`Defer`(node)
    if deferred.body != nil and deferred.body.tag == "block": resolver.body(ast.Block(deferred.body), target, module)
    else: resolver.expression(deferred.body, target, module)
  of "unsafe": resolver.body(ast.Unsafe(node).body, target, module)
  of "test": resolver.body(ast.Test(node).body, target, module)
  of "eval": resolver.body(ast.Evaluation(node).body, target, module)
  of "action":
    let action = ast.Action(node)
    if action.value != nil: resolver.expression(action.value, target, module)
    else:
      resolver.expression(action.name, target, module)
      for argument in action.args: resolver.expression(argument, target, module)
  of "machine": resolver.expression(node, target, module)
  else: discard

proc unit(resolver: Resolver; node: ast.Unit; name, file: string) =
  if resolver.units.hasKey(name):
    if absolutePath(resolver.units[name].file) != absolutePath(file):
      resolver.diag.emit(Code.Clash, node.span,
        "Files claim the same namespace '" & name & "'")
    return
  let target = scope()
  resolver.units[name] = module.Unit(name: name, package: lastPathPart(resolver.root),
    path: relativePath(file, resolver.root).replace('\\', '/'), file: absolutePath(file),
    imports: initTable[string, string](), scope: target, node: node)
  resolver.imported[name] = initHashSet[string]()
  for child in node.body.stmts: resolver.declare(child, target, name)
  for child in node.body.stmts:
    if child.tag == "use": resolver.imported(ast.Use(child), target, name)
  for child in node.body.stmts:
    if child.tag != "use": resolver.statement(child, target, name)
  resolver.order.add(name)

proc load(resolver: Resolver; name, path: string): ast.Program =
  if resolver.cache.hasKey(name): return resolver.cache[name]
  let input = resolver.read(path)
  if not input.found: return nil
  resolver.loading.incl(name)
  let origin = resolver.diag.content
  let document = resolver.diag.file
  resolver.diag.source(input.source, path)
  let before = resolver.diag.messages.len
  if resolver.decoder != nil:
    result = resolver.decoder(path, input.source, resolver.diag)
  else:
    let tokens = lexer(input.source, resolver.diag).lex()
    result = parser(tokens, resolver.diag).parse()
  if resolver.diag.messages.len == before and result != nil:
    for child in result.units: resolver.unit(child, name, path)
  resolver.diag.source(origin, document)
  resolver.cache[name] = result
  resolver.loading.excl(name)

proc resolve*(resolver: Resolver; entry: ast.Program; label: string): Resolution =
  for child in entry.units:
    var file = child.file
    if file.len == 0: file = resolver.diag.file
    if file.len == 0:
      file = if label.endsWith(".iv") or label.isAbsolute:
        absolutePath(label, resolver.root)
      else:
        resolver.root / (label & ".iv")
    let name = resolver.module(file)
    resolver.loading.incl(name)
    resolver.unit(child, name, file)
    resolver.loading.excl(name)
    resolver.cache[name] = entry
  Resolution(units: resolver.units, resolutions: resolver.resolutions,
    order: resolver.order)
