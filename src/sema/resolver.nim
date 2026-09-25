import std/[json, os, sets, strutils, tables]
import ../ast/node as ast
import ../diag/[code, engine, span]
import ../lex/lexer
import ../parse/parser
import ./[form, module, scope, symbol]

type
  ReadResult* = tuple[found: bool, source: string]
  ReadProc* = proc(path: string): ReadResult {.closure.}
  ParseProc* = proc(path, source: string; diagnostics: Engine): ast.Program {.closure.}

  Resolver* = ref object
    diag: Engine
    root: string
    stdRoot: string
    units: Table[string, module.Unit]
    order: seq[string]
    resolutions: Table[pointer, Symbol]
    cache: Table[string, ast.Program]
    loading: HashSet[string]
    importedSymbols: Table[string, HashSet[string]]
    read: ReadProc
    parseInput: ParseProc

proc defaultRead(path: string): ReadResult =
  if fileExists(path): (true, readFile(path)) else: (false, "")

proc bundledStdRoot(): string =
  let configured = getEnv("FOO_STD")
  if configured.len > 0 and dirExists(configured): return absolutePath(configured)
  for candidate in [getAppDir().parentDir / "std",
      getAppDir().parentDir.parentDir / "std",
      currentSourcePath.parentDir.parentDir.parentDir / "std"]:
    if dirExists(candidate): return absolutePath(candidate)
  absolutePath(getCurrentDir() / "std")

proc newResolver*(diag: Engine; root: string; stdRoot = "";
    read: ReadProc = nil; parse: ParseProc = nil): Resolver =
  let absoluteRoot = absolutePath(root)
  Resolver(
    diag: diag,
    root: absoluteRoot,
    stdRoot: if stdRoot.len > 0: absolutePath(stdRoot) else: bundledStdRoot(),
    units: initTable[string, module.Unit](),
    resolutions: initTable[pointer, Symbol](),
    cache: initTable[string, ast.Program](),
    loading: initHashSet[string](),
    importedSymbols: initTable[string, HashSet[string]](),
    read: if read == nil: defaultRead else: read,
    parseInput: parse)

proc key(node: ast.Node): pointer = cast[pointer](node)

proc insert(resolver: Resolver; target: Scope; name: string; form: Form;
    visible: bool; node: ast.Node; moduleName: string) =
  let item = Symbol(name: name, form: form, visible: visible, node: node,
    module: moduleName, qualified: moduleName & "::" & name)
  if not target.insert(name, item):
    resolver.diag.emit(Code.Duplicate, node.span, "duplicate symbol '" & name & "'")
    let original = target.lookupLocal(name)
    if original.found:
      resolver.diag.related(original.symbol.node.span, "First declared here")

proc resolveType(resolver: Resolver; node: ast.`Type`; target: Scope;
    moduleName: string)
proc expression(resolver: Resolver; node: ast.Expression; target: Scope;
    moduleName: string)
proc statement(resolver: Resolver; node: ast.Statement; target: Scope;
    moduleName: string)
proc resolveBlock(resolver: Resolver; node: ast.Block; target: Scope;
    moduleName: string; child = true)
proc load(resolver: Resolver; name, path: string): ast.Program
proc resolveUnit(resolver: Resolver; node: ast.Unit; name, file: string)

proc missing(resolver: Resolver; name: string; node: ast.Node) =
  resolver.diag.emit(Code.Missing, node.span, "undefined symbol '" & name & "'")

proc resolveType(resolver: Resolver; node: ast.`Type`; target: Scope;
    moduleName: string) =
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
    let generic = ast.GenericInst(node)
    let found = target.lookup(generic.name.text)
    if not found.found or found.symbol.form != Form.Type:
      resolver.diag.emit(Code.Missing, node.span,
        "Undefined type '" & generic.name.text & "'")
    else:
      resolver.resolutions[key(node)] = found.symbol
    for argument in generic.args:
      resolver.resolveType(argument, target, moduleName)
  of "optional": resolver.resolveType(ast.Optional(node).elem, target, moduleName)
  of "error": resolver.resolveType(ast.Error(node).elem, target, moduleName)
  of "pointer": resolver.resolveType(ast.Pointer(node).elem, target, moduleName)
  of "array": resolver.resolveType(ast.Array(node).elem, target, moduleName)
  of "sequence": resolver.resolveType(ast.Sequence(node).elem, target, moduleName)
  of "vector": resolver.resolveType(ast.Vector(node).elem, target, moduleName)
  of "function-type":
    let functionType = ast.FunctionType(node)
    for parameter in functionType.params:
      resolver.resolveType(parameter, target, moduleName)
    resolver.resolveType(functionType.ret, target, moduleName)
  else: discard

proc expression(resolver: Resolver; node: ast.Expression; target: Scope;
    moduleName: string) =
  if node == nil: return
  case node.tag
  of "name":
    let name = ast.Name(node)
    let found = target.lookup(name.text)
    if found.found: resolver.resolutions[key(node)] = found.symbol
    else: resolver.missing(name.text, node)
  of "call":
    let call = ast.Call(node)
    for typ in call.types: resolver.resolveType(typ, target, moduleName)
    if call.callee.tag != "name" or ast.Name(call.callee).text notin ["splat", "shuffle", "select", "reduce", "fail"]:
      resolver.expression(call.callee, target, moduleName)
    for argument in call.args: resolver.expression(argument, target, moduleName)
  of "unary": resolver.expression(ast.Unary(node).operand, target, moduleName)
  of "binary":
    resolver.expression(ast.Binary(node).left, target, moduleName)
    resolver.expression(ast.Binary(node).right, target, moduleName)
  of "group": resolver.expression(ast.Group(node).expr, target, moduleName)
  of "field":
    let field = ast.Field(node)
    if field.object.tag == "name":
      let qualifier = ast.Name(field.object).text
      let qualified = target.lookup(qualifier & "." & field.field.text)
      if qualified.found:
        resolver.resolutions[key(node)] = qualified.symbol
        return
      if qualifier == "Error" and not target.lookup("Error").found: return
    resolver.expression(field.object, target, moduleName)
  of "index":
    resolver.expression(ast.Index(node).object, target, moduleName)
    resolver.expression(ast.Index(node).index, target, moduleName)
  of "allocation":
    resolver.expression(ast.Allocation(node).size, target, moduleName)
    resolver.expression(ast.Allocation(node).owner, target, moduleName)
  of "error-chain":
    resolver.expression(ast.ErrorChain(node).expr, target, moduleName)
    resolver.expression(ast.ErrorChain(node).context, target, moduleName)
  of "machine":
    let machine = ast.Machine(node)
    resolver.expression(machine.target, target, moduleName)
    resolver.expression(machine.value, target, moduleName)
    for argument in machine.args: resolver.expression(argument, target, moduleName)
  of "reflect": resolver.resolveType(ast.Reflect(node).type, target, moduleName)
  of "embed": resolver.resolveType(ast.Embed(node).type, target, moduleName)
  else: discard

proc declare(resolver: Resolver; node: ast.Statement; target: Scope;
    moduleName: string) =
  case node.tag
  of "constant":
    let declaration = ast.Constant(node)
    resolver.insert(target, declaration.name.text, Form.Constant,
      declaration.public, node, moduleName)
  of "mutable":
    let declaration = ast.Mutable(node)
    resolver.insert(target, declaration.name.text, Form.Mutable,
      declaration.public, node, moduleName)
  of "function":
    let declaration = ast.Function(node)
    for attribute in declaration.attributes:
      if attribute notin ["start", "interrupt", "naked"] and not attribute.startsWith("target_feature(\""):
        resolver.diag.emit(Code.Invalid, node.span,
          "unknown function attribute '#[" & attribute & "]'")
    if "start" in declaration.attributes and declaration.params.len > 0:
      resolver.diag.emit(Code.Invalid, node.span,
        "#[start] functions cannot take parameters")
    resolver.insert(target, declaration.name.text, Form.Function,
      declaration.public, node, moduleName)
  of "extern-function":
    let declaration = ast.ExternFunction(node)
    resolver.insert(target, declaration.name.text, Form.Function,
      declaration.public, node, moduleName)
  of "alias":
    let declaration = ast.Alias(node)
    resolver.insert(target, declaration.name.text, Form.Type,
      declaration.public, node, moduleName)
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
          declaration.public, variant, moduleName)
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
    moduleName: string) =
  case node.tag
  of "constant":
    resolver.insert(target, ast.Constant(node).name.text, Form.Constant,
      false, node, moduleName)
  of "mutable":
    resolver.insert(target, ast.Mutable(node).name.text, Form.Mutable,
      false, node, moduleName)
  else: discard

proc resolveBlock(resolver: Resolver; node: ast.Block; target: Scope;
    moduleName: string; child = true) =
  if node == nil: return
  let blockScope = if child: newScope(target) else: target
  for childNode in node.stmts:
    if childNode.tag == "alias": resolver.declare(childNode, blockScope, moduleName)
  for childNode in node.stmts:
    resolver.statement(childNode, blockScope, moduleName)
    if childNode.tag in ["constant", "mutable"]:
      resolver.collect(childNode, blockScope, moduleName)

proc functionBody(resolver: Resolver; node: ast.Function; parent: Scope;
    moduleName: string) =
  let functionScope = newScope(parent)
  for parameter in node.typeParams:
    resolver.insert(functionScope, parameter.name.text, Form.Type,
      false, parameter, moduleName)
  for parameter in node.params:
    resolver.insert(functionScope, parameter.name.text, Form.Parameter,
      false, parameter, moduleName)
    resolver.resolveType(parameter.type, functionScope, moduleName)
  resolver.resolveType(node.returnType, functionScope, moduleName)
  resolver.resolveBlock(node.body, functionScope, moduleName, false)

proc moduleName(resolver: Resolver; path: string): string =
  var relative = relativePath(absolutePath(path), resolver.root)
  if relative.endsWith(".iv"): relative.setLen(relative.len - 3)
  relative = relative.replace('\\', ':').replace('/', ':')
  while "::" in relative: relative = relative.replace("::", ":")
  let packageName = lastPathPart(resolver.root)
  packageName & "::" & relative.replace(":", "::")

proc packagePath(resolver: Resolver; name: string): string =
  let packageRoot = resolver.root / ".foo" / "packages" / name
  let manifestInput = resolver.read(packageRoot / "project.json")
  if not manifestInput.found: return
  try:
    let manifest = parseJson(manifestInput.source)
    var relative = manifest.getOrDefault("entry").getStr()
    if relative.len == 0:
      let source = manifest.getOrDefault("source").getStr()
      relative = if source.len > 0: source / "main.iv" else: "main.iv"
    if not relative.endsWith(".iv"): relative.add(".iv")
    let candidate = absolutePath(packageRoot / relative)
    let confined = relativePath(candidate, packageRoot).replace('\\', '/')
    if confined == ".." or confined.startsWith("../") or confined.isAbsolute: return
    if resolver.read(candidate).found: return candidate
  except CatchableError:
    discard

proc modulePath(resolver: Resolver; useNode: ast.Use; current: string): string =
  let currentFile = if resolver.units.hasKey(current): resolver.units[current].file else: resolver.root / "main.iv"
  if useNode.path.len > 0:
    var path = useNode.path
    if not path.endsWith(".iv"): path.add(".iv")
    if path.isAbsolute: path else: absolutePath(parentDir(currentFile) / path)
  else:
    let local = parentDir(currentFile) / (useNode.name.text & ".iv")
    if resolver.read(local).found: return local
    let package = resolver.packagePath(useNode.name.text)
    if package.len > 0: return package
    resolver.stdRoot / (useNode.name.text & ".iv")

proc symbols(resolver: Resolver; name: string): seq[Symbol] =
  if not resolver.units.hasKey(name): return
  let semanticUnit = resolver.units[name]
  for node in semanticUnit.node.body.stmts:
    let found = case node.tag
      of "constant": semanticUnit.scope.lookupLocal(ast.Constant(node).name.text)
      of "mutable": semanticUnit.scope.lookupLocal(ast.Mutable(node).name.text)
      of "function": semanticUnit.scope.lookupLocal(ast.Function(node).name.text)
      of "extern-function": semanticUnit.scope.lookupLocal(ast.ExternFunction(node).name.text)
      of "alias": semanticUnit.scope.lookupLocal(ast.Alias(node).name.text)
      else: (found: false, symbol: Symbol())
    if found.found: result.add(found.symbol)

proc useModule(resolver: Resolver; useNode: ast.Use; target: Scope;
    current: string) =
  let path = resolver.modulePath(useNode, current)
  let importedName = resolver.moduleName(path)
  if importedName in resolver.importedSymbols[current]:
    resolver.diag.emit(Code.Duplicate, useNode.name.span,
      "module '" & importedName & "' already imported")
    return
  resolver.importedSymbols[current].incl(importedName)
  if importedName in resolver.loading:
    resolver.diag.emit(Code.Circular, useNode.span,
      "Circular use dependency: " & importedName)
    return
  let source = resolver.read(path)
  if not source.found:
    resolver.diag.emit(Code.Absent, useNode.span,
      "Use target '" & (if useNode.path.len > 0: useNode.path else: useNode.name.text) & "' was not found")
    return
  let qualifier = if useNode.alias != nil: useNode.alias.text else: useNode.name.text
  if resolver.units[current].imports.hasKey(qualifier) or target.lookupLocal(qualifier).found:
    resolver.diag.emit(Code.Duplicate, useNode.span,
      "Import name '" & qualifier & "' is already declared")
    return
  resolver.units[current].imports[qualifier] = importedName
  discard resolver.load(importedName, path)
  for imported in resolver.symbols(importedName):
    if imported.visible:
      let locals = if useNode.alias != nil: @[qualifier & "." & imported.name]
        else: @[imported.name, qualifier & "." & imported.name]
      for local in locals:
        if not target.insert(local, imported):
          resolver.diag.emit(Code.Duplicate, useNode.name.span,
            "symbol '" & local & "' conflicts with existing symbol")
          resolver.diag.suggestion("Use 'as name' to qualify this import")

proc statement(resolver: Resolver; node: ast.Statement; target: Scope;
    moduleName: string) =
  if node == nil: return
  case node.tag
  of "constant":
    resolver.resolveType(ast.Constant(node).type, target, moduleName)
    resolver.expression(ast.Constant(node).value, target, moduleName)
  of "mutable":
    resolver.resolveType(ast.Mutable(node).type, target, moduleName)
    resolver.expression(ast.Mutable(node).value, target, moduleName)
  of "function": resolver.functionBody(ast.Function(node), target, moduleName)
  of "extern-function":
    let function = ast.ExternFunction(node)
    let functionScope = newScope(target)
    for parameter in function.typeParams:
      resolver.insert(functionScope, parameter.name.text, Form.Type, false, parameter, moduleName)
    for parameter in function.params: resolver.resolveType(parameter.type, functionScope, moduleName)
    resolver.resolveType(function.returnType, functionScope, moduleName)
  of "alias":
    let alias = ast.Alias(node)
    let aliasScope = newScope(target)
    for parameter in alias.typeParams:
      resolver.insert(aliasScope, parameter.name.text, Form.Type, false, parameter, moduleName)
    if alias.body != nil:
      case alias.body.tag
      of "record":
        for field in ast.Record(alias.body).fields: resolver.resolveType(field.type, aliasScope, moduleName)
      of "union":
        for field in ast.Union(alias.body).fields: resolver.resolveType(field.type, aliasScope, moduleName)
      of "choice":
        for variant in ast.Choice(alias.body).variants: resolver.resolveType(variant.payload, aliasScope, moduleName)
      of "opaque": discard
      else: resolver.resolveType(alias.body, aliasScope, moduleName)
  of "use": resolver.useModule(ast.Use(node), target, moduleName)
  of "give": resolver.expression(ast.Give(node).value, target, moduleName)
  of "when":
    let branch = ast.`When`(node)
    resolver.expression(branch.cond, target, moduleName)
    resolver.resolveBlock(branch.then, target, moduleName)
    if branch.else != nil:
      if branch.else.tag == "when": resolver.statement(branch.else, target, moduleName)
      else: resolver.resolveBlock(ast.Block(branch.else), target, moduleName)
  of "while":
    resolver.expression(ast.`While`(node).cond, target, moduleName)
    resolver.resolveBlock(ast.`While`(node).body, target, moduleName)
  of "repeat":
    resolver.expression(ast.Repeat(node).target, target, moduleName)
    resolver.expression(ast.Repeat(node).limit, target, moduleName)
    resolver.resolveBlock(ast.Repeat(node).body, target, moduleName)
  of "for":
    let loop = ast.`For`(node)
    resolver.expression(loop.iter, target, moduleName)
    let loopScope = newScope(target)
    resolver.insert(loopScope, loop.bind.text, Form.Parameter, false, node, moduleName)
    resolver.resolveBlock(loop.body, loopScope, moduleName)
  of "match":
    let matchNode = ast.Match(node)
    resolver.expression(matchNode.scrutinee, target, moduleName)
    for arm in matchNode.cases:
      let caseScope = newScope(target)
      if arm.pattern != nil and arm.pattern.tag == "name" and ast.Name(arm.pattern).text != "_":
        resolver.expression(arm.pattern, caseScope, moduleName)
      elif arm.pattern != nil and arm.pattern.tag == "variant-pattern":
        let pattern = ast.VariantPattern(arm.pattern)
        if pattern.binding != nil:
          resolver.insert(caseScope, pattern.binding.text, Form.Parameter, false, pattern.binding, moduleName)
      resolver.expression(arm.guard, caseScope, moduleName)
      resolver.resolveBlock(arm.body, caseScope, moduleName)
  of "assignment":
    resolver.expression(ast.Assignment(node).target, target, moduleName)
    resolver.expression(ast.Assignment(node).value, target, moduleName)
  of "try": resolver.expression(ast.`Try`(node).expr, target, moduleName)
  of "defer":
    let deferred = ast.`Defer`(node)
    if deferred.body != nil and deferred.body.tag == "block": resolver.resolveBlock(ast.Block(deferred.body), target, moduleName)
    else: resolver.expression(deferred.body, target, moduleName)
  of "unsafe": resolver.resolveBlock(ast.Unsafe(node).body, target, moduleName)
  of "test": resolver.resolveBlock(ast.TestBlock(node).body, target, moduleName)
  of "eval": resolver.resolveBlock(ast.EvalBlock(node).body, target, moduleName)
  of "action":
    let action = ast.Action(node)
    if action.value != nil: resolver.expression(action.value, target, moduleName)
    else:
      resolver.expression(action.name, target, moduleName)
      for argument in action.args: resolver.expression(argument, target, moduleName)
  of "machine": resolver.expression(node, target, moduleName)
  of "advance": resolver.expression(ast.AdvanceStatement(node).target, target, moduleName)
  else: discard

proc resolveUnit(resolver: Resolver; node: ast.Unit; name, file: string) =
  if resolver.units.hasKey(name):
    if absolutePath(resolver.units[name].file) != absolutePath(file):
      resolver.diag.emit(Code.Clash, node.span,
        "Files claim the same namespace '" & name & "'")
    return
  let target = newScope()
  resolver.units[name] = module.Unit(name: name, package: lastPathPart(resolver.root),
    path: relativePath(file, resolver.root).replace('\\', '/'), file: absolutePath(file),
    imports: initTable[string, string](), scope: target, node: node)
  resolver.importedSymbols[name] = initHashSet[string]()
  for child in node.body.stmts: resolver.declare(child, target, name)
  for child in node.body.stmts:
    if child.tag == "use": resolver.useModule(ast.Use(child), target, name)
  for child in node.body.stmts:
    if child.tag != "use": resolver.statement(child, target, name)
  resolver.order.add(name)

proc load(resolver: Resolver; name, path: string): ast.Program =
  if resolver.cache.hasKey(name): return resolver.cache[name]
  let input = resolver.read(path)
  if not input.found: return nil
  resolver.loading.incl(name)
  let previousSource = resolver.diag.getSource
  let previousFile = resolver.diag.getFile
  resolver.diag.setSource(input.source, path)
  let before = resolver.diag.messages.len
  if resolver.parseInput != nil:
    result = resolver.parseInput(path, input.source, resolver.diag)
  else:
    let tokens = newLexer(input.source, resolver.diag).lex()
    result = newParser(tokens, resolver.diag).parse()
  if resolver.diag.messages.len == before and result != nil:
    for child in result.units: resolver.resolveUnit(child, name, path)
  resolver.diag.setSource(previousSource, previousFile)
  resolver.cache[name] = result
  resolver.loading.excl(name)

proc resolve*(resolver: Resolver; entry: ast.Program; entryName: string): Resolution =
  for child in entry.units:
    var file = child.file
    if file.len == 0: file = resolver.diag.getFile
    if file.len == 0:
      file = if entryName.endsWith(".iv") or entryName.isAbsolute:
        absolutePath(entryName, resolver.root)
      else:
        resolver.root / (entryName & ".iv")
    let name = resolver.moduleName(file)
    resolver.loading.incl(name)
    resolver.resolveUnit(child, name, file)
    resolver.loading.excl(name)
    resolver.cache[name] = entry
  Resolution(units: resolver.units, resolutions: resolver.resolutions,
    order: resolver.order)
