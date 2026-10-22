import std/[algorithm, json, os, sequtils, sets, strutils, tables]
import ../diag/engine
import ../lex/lexer
import ../ast/parser
import ../sema/resolver
import ../sema/link
import ../sema/module as modules
import ../sema/symbol as symbol
import ../types/checker
import ../types/type as semantic
import ../ir/lower
import ../ir/eval as eval
import ../ir/monomorph
from ../ir/node import Module
import ../ir/valid
import ../ast/node
import ../pkg/hash
import ../config/project as configuration
import ../pkg/lint
import ../opt/profile as profiling
import ../interop/expand as expansion
import "../interop/bind.nim" as foreign
import ./query as dependencies

type
  Diagnostics* = ref object of CatchableError
    diagnostics*: Engine
  Checks* = object
    cached*: bool
  Analysis* = object
    program*: Program
    resolution*: modules.Resolution
    types*: Table[pointer, semantic.Type]
  Compiler* = ref object
    root*: string
    backend*: string
    includes*: seq[string]
    sysroot*: string
    mode*: string
    optimization*: bool
    target*: string
    cpu*: string
    runtime*: string
    hot*: HashSet[string]
    inputs: Table[string, string]
    checked*: Table[string, string]
    verified: Table[string, seq[tuple[path: string, digest: string]]]
    queries: dependencies.Queries
    programs*: Table[string, Program]
    typings*: Table[string, Table[pointer, semantic.Type]]

proc compiler*(root: string; backend = "qbe"; includes: seq[string] = @[];
    mode = "dev"; optimization = false; target = ""; cpu = "";
    profile = ""; runtime = ""; sysroot = ""): Compiler =
  let counts = profiling.load(profile)
  Compiler(root: absolutePath(root), backend: backend, includes: includes,
    sysroot: sysroot, mode: mode,
    optimization: optimization, target: target, cpu: cpu, runtime: runtime,
    hot: profiling.hot(counts),
    checked: initTable[string, string](), programs: initTable[string, Program](),
    typings: initTable[string, Table[pointer, semantic.Type]](),
    verified: initTable[string, seq[tuple[path: string, digest: string]]](),
    queries: dependencies.queries())

proc parse(compiler: Compiler; file, source: string; diag: Engine): Program =
  # Capture the bytes actually parsed, including every transitive resolver import.
  compiler.inputs[absolutePath(file).replace('\\', '/')] = digest(source)
  diag.source(source, file)
  let tokens = lexer(source, diag).lex()
  result = parser(tokens, diag).parse()
  if not diag.failed: eval.expand(result, compiler.target)
  if not diag.failed:
    expansion.expand(result, diag, compiler.root,
      foreign.Binding(includes: compiler.includes, target: compiler.target,
        sysroot: compiler.sysroot), proc(path: string) =
          let location = absolutePath(path).replace('\\', '/')
          compiler.inputs[location] = digest(readFile(path)))

proc prepare*(program: Program) =
  if program == nil or program.units.len == 0: return
  let unit = program.units[0]
  var console, log: string
  var labels = initHashSet[string]()
  for statement in unit.body.stmts:
    case statement.tag
    of "function": labels.incl(Function(statement).name.text)
    of "extern-function": labels.incl(External(statement).name.text)
    of "constant": labels.incl(Constant(statement).name.text)
    of "mutable": labels.incl(Mutable(statement).name.text)
    of "use":
      let imported = Use(statement)
      if imported.path.len == 0:
        let qualifier = if imported.alias != nil: imported.alias.text else: imported.name.text
        if imported.name.text == "io": console = qualifier
        elif imported.name.text == "log": log = qualifier
    else: discard

  var needs, needsLog, found, provider: bool
  var top = initTable[pointer, bool]()
  var services = initTable[pointer, bool]()
  proc inspect(expression: Expression)
  proc visit(body: Block)
  proc scan(statement: Statement)
  proc inspect(expression: Expression) =
    if expression == nil: return
    case expression.tag
    of "name":
      let name = Name(expression).text
      if name == "input" and name notin labels:
        needs = true
        provider = true
    of "call":
      provider = true
      let call = Call(expression)
      if call.callee.tag == "name":
        let name = Name(call.callee).text
        if name in ["display", "input", "report"] and name notin labels:
          needs = true
        elif name in ["__bare_log.message", "__bare_log.error"]: needsLog = true
      inspect(call.callee)
      for argument in call.args: inspect(argument)
    of "sequence-value":
      for item in Values(expression).items: inspect(item)
    of "closure": visit(Closure(expression).body)
    of "unary":
      if Unary(expression).op == "try": found = true
      inspect(Unary(expression).operand)
    of "binary": inspect(Binary(expression).left); inspect(Binary(expression).right)
    of "group": inspect(Group(expression).expr)
    of "field":
      provider = true
      inspect(Field(expression).object)
    of "index": inspect(Index(expression).object); inspect(Index(expression).index)
    of "allocation":
      provider = true
      inspect(Allocation(expression).size)
      inspect(Allocation(expression).owner)
    else: discard
  proc scan(statement: Statement) =
    if statement == nil: return
    case statement.tag
    of "constant": inspect(Constant(statement).value)
    of "mutable": inspect(Mutable(statement).value)
    of "destructure": inspect(Destructure(statement).value)
    of "function": inspect(Function(statement).guard); visit(Function(statement).body)
    of "give": inspect(Give(statement).value)
    of "assignment": inspect(Assignment(statement).target); inspect(Assignment(statement).value)
    of "when":
      inspect(`When`(statement).cond); visit(`When`(statement).then)
      if `When`(statement).else != nil:
        if `When`(statement).else.tag == "block": visit(Block(`When`(statement).else))
        else: inspect(Statement(`When`(statement).else))
    of "while": inspect(`While`(statement).cond); visit(`While`(statement).body)
    of "for": inspect(`For`(statement).iter); visit(`For`(statement).body)
    of "match":
      inspect(Match(statement).scrutinee)
      for branch in Match(statement).cases: inspect(branch.guard); visit(branch.body)
    of "defer":
      if `Defer`(statement).body.tag == "block": visit(Block(`Defer`(statement).body))
      else: inspect(Expression(`Defer`(statement).body))
    of "unsafe": visit(Unsafe(statement).body)
    of "action":
      let action = Action(statement)
      if action.value != nil: inspect(action.value)
      elif action.name.text in ["display", "report"] and
          action.name.text notin labels:
        needs = true
      for argument in action.args: inspect(argument)
    else: discard
  proc visit(body: Block) =
    if body != nil:
      for statement in body.stmts: scan(statement)
  for statement in unit.body.stmts:
    found = false
    provider = false
    scan(statement)
    if found: top[cast[pointer](statement)] = true
    if provider: services[cast[pointer](statement)] = true

  if needs and console.len == 0: console = "__prelude_io"
  if needsLog and log.len == 0: log = "__prelude_log"

  proc rewrite(expression: Expression): Expression
  proc transform(body: Block)
  proc replace(statement: Statement)
  proc rewrite(expression: Expression): Expression =
    if expression == nil: return nil
    result = expression
    case expression.tag
    of "name":
      let name = Name(expression)
      if name.text == "input" and name.text notin labels:
        result = Call(tag: "call", span: expression.span,
          callee: Name(tag: "name", span: expression.span,
            text: console & ".line"),
          args: @[Expression(Call(tag: "call", span: expression.span,
            callee: Name(tag: "name", span: expression.span,
              text: console & ".input"), args: @[], names: @[]))],
          names: @[""])
    of "call":
      let call = Call(expression)
      if call.callee.tag == "name":
        let name = Name(call.callee)
        if name.text == "display" and name.text notin labels:
          name.text = console & ".display"
        elif name.text == "report" and name.text notin labels:
          name.text = console & ".diagnose"
        elif name.text == "input" and name.text notin labels:
          name.text = console & ".line"
          call.args.add(Call(tag: "call", span: call.span,
            callee: Name(tag: "name", span: call.span,
              text: console & ".input"), args: @[], names: @[]))
          call.names.add("")
        elif name.text == "__bare_log.message": name.text = log & ".note"
        elif name.text == "__bare_log.error": name.text = log & ".alert"
      call.callee = rewrite(call.callee)
      for index in 0 ..< call.args.len:
        call.args[index] = rewrite(call.args[index])
    of "sequence-value":
      for index in 0 ..< Values(expression).items.len:
        Values(expression).items[index] = rewrite(Values(expression).items[index])
    of "closure": transform(Closure(expression).body)
    of "unary": Unary(expression).operand = rewrite(Unary(expression).operand)
    of "binary":
      Binary(expression).left = rewrite(Binary(expression).left)
      Binary(expression).right = rewrite(Binary(expression).right)
    of "group": Group(expression).expr = rewrite(Group(expression).expr)
    of "field": Field(expression).object = rewrite(Field(expression).object)
    of "index":
      Index(expression).object = rewrite(Index(expression).object)
      Index(expression).index = rewrite(Index(expression).index)
    of "allocation":
      Allocation(expression).size = rewrite(Allocation(expression).size)
      Allocation(expression).owner = rewrite(Allocation(expression).owner)
    else: discard
  proc replace(statement: Statement) =
    if statement == nil: return
    case statement.tag
    of "constant": Constant(statement).value = rewrite(Constant(statement).value)
    of "mutable": Mutable(statement).value = rewrite(Mutable(statement).value)
    of "destructure": Destructure(statement).value = rewrite(Destructure(statement).value)
    of "function":
      Function(statement).guard = rewrite(Function(statement).guard)
      transform(Function(statement).body)
    of "give": Give(statement).value = rewrite(Give(statement).value)
    of "assignment":
      Assignment(statement).target = rewrite(Assignment(statement).target)
      Assignment(statement).value = rewrite(Assignment(statement).value)
    of "when":
      `When`(statement).cond = rewrite(`When`(statement).cond)
      transform(`When`(statement).then)
      if `When`(statement).else != nil:
        if `When`(statement).else.tag == "block": transform(Block(`When`(statement).else))
        else: replace(Statement(`When`(statement).else))
    of "while":
      `While`(statement).cond = rewrite(`While`(statement).cond)
      transform(`While`(statement).body)
    of "for":
      `For`(statement).iter = rewrite(`For`(statement).iter)
      transform(`For`(statement).body)
    of "match":
      Match(statement).scrutinee = rewrite(Match(statement).scrutinee)
      for branch in Match(statement).cases:
        branch.guard = rewrite(branch.guard)
        transform(branch.body)
    of "defer":
      if `Defer`(statement).body.tag == "block": transform(Block(`Defer`(statement).body))
      else: `Defer`(statement).body = rewrite(Expression(`Defer`(statement).body))
    of "unsafe": transform(Unsafe(statement).body)
    of "action":
      let action = Action(statement)
      if action.value != nil: action.value = rewrite(action.value)
      elif action.name.text in ["display", "report"] and
          action.name.text notin labels:
        action.name.text = console & "." &
          (if action.name.text == "report": "diagnose" else: "display")
      for index in 0 ..< action.args.len:
        action.args[index] = rewrite(action.args[index])
    else: discard
  proc transform(body: Block) =
    if body != nil:
      for statement in body.stmts: replace(statement)

  transform(unit.body)
  var prefix: seq[Statement]
  if needs and not unit.body.stmts.anyIt(it.tag == "use" and Use(it).path.len == 0 and Use(it).name.text == "io"):
    prefix.add(Use(tag: "use", span: unit.span,
      name: Name(tag: "name", span: unit.span, text: "io"),
      alias: Name(tag: "name", span: unit.span, text: console)))
  if needsLog and not unit.body.stmts.anyIt(it.tag == "use" and Use(it).path.len == 0 and Use(it).name.text == "log"):
    prefix.add(Use(tag: "use", span: unit.span,
      name: Name(tag: "name", span: unit.span, text: "log"),
      alias: Name(tag: "name", span: unit.span, text: log)))
  if prefix.len > 0: unit.body.stmts = prefix & unit.body.stmts

  let start = unit.body.stmts.anyIt(it.tag == "function" and Function(it).name.text == "start")
  if start: return
  const executable = ["give", "when", "while", "for", "match",
    "assignment", "break", "continue", "defer", "unsafe", "action",
    "machine", "unreachable-statement"]
  var declarations, body: seq[Statement]
  var started, entry: bool
  for statement in unit.body.stmts:
    let failable = top.getOrDefault(cast[pointer](statement))
    let binding = statement.tag in ["constant", "mutable"] and
      services.getOrDefault(cast[pointer](statement))
    let hosted = started and
      statement.tag in ["constant", "mutable"]
    if statement.tag in executable or binding or hosted:
      body.add(statement)
      started = true
      if failable: entry = true
    else:
      declarations.add(statement)
  if body.len == 0: return
  declarations.add(Function(tag: "function", span: body[0].span,
    name: Name(tag: "name", span: body[0].span, text: "start"), params: @[],
    returns: if entry:
      Error(tag: "error", span: body[0].span,
        elem: Primitive(tag: "primitive", span: body[0].span,
          name: "nothing"))
    else: nil,
    body: Block(tag: "block", span: body[0].span, stmts: body)))
  unit.body.stmts = declarations

proc analyze*(compiler: Compiler; file, source: string;
    diag: Engine): Analysis =
  let path = absolutePath(file)
  var parsed = compiler.parse(path, source, diag)
  var resolution = modules.Resolution(
    units: initTable[string, modules.Unit](),
    resolutions: initTable[pointer, symbol.Symbol]())
  var types = initTable[pointer, semantic.Type]()
  if not diag.failed: prepare(parsed)
  if not diag.failed:
    let resolver = resolver(diag, compiler.root, parse =
      proc(importedFile, input: string; diagnostics: Engine): Program =
        result = compiler.parse(importedFile, input, diagnostics)
        if not diagnostics.failed: prepare(result))
    resolution = resolver.resolve(parsed, path)
    if not diag.failed: parsed = link(parsed, resolution)
  if not diag.failed: lint(parsed, diag, compiler.backend)
  if not diag.failed:
    let checker = checker(diag)
    checker.check(parsed)
    types = checker.types
  if not diag.failed:
    for location in configuration.manifestFiles(compiler.root):
      compiler.inputs[absolutePath(location).replace('\\', '/')] =
        digest(readFile(location))
    let manifest = configuration.readProject(compiler.root)
    let level = if manifest.hasKey("requires") and
        manifest["requires"].kind == JString: manifest["requires"].getStr()
      else: "base"
    capabilities(parsed, diag, level)
  Analysis(program: parsed, resolution: resolution, types: types)

proc program*(compiler: Compiler; file: string): Program =
  compiler.inputs.clear()
  let path = absolutePath(file)
  if not fileExists(path): raise newException(IOError, "File not found: " & path)
  let source = readFile(path)
  let diag = engine()
  let analysis = compiler.analyze(path, source, diag)
  if diag.failed:
    var error: Diagnostics
    new(error)
    error.msg = "Check failed"
    error.diagnostics = diag
    raise error
  compiler.typings[path] = analysis.types
  compiler.programs[path] = analysis.program
  analysis.program

proc check*(compiler: Compiler; file: string): Checks =
  let path = absolutePath(file)
  if not fileExists(path): raise newException(IOError, "File not found: " & path)
  let digest = digest(readFile(path))
  if compiler.checked.getOrDefault(path) == digest and
      compiler.verified.hasKey(path) and
      compiler.queries.valid(compiler.verified[path]):
    return Checks(cached: true)
  discard compiler.program(path)
  compiler.checked[path] = digest
  var inputs: seq[tuple[path: string, digest: string]]
  for path, content in compiler.inputs.pairs:
    inputs.add((path: path, digest: content))
  compiler.verified[path] = inputs
  Checks(cached: false)

proc ir*(compiler: Compiler; file: string): Module =
  let program = compiler.program(file)
  let path = absolutePath(file)
  let base = lower(program, compiler.typings.getOrDefault(path))
  base.path = relativePath(path, compiler.root).replace('\\', '/')
  if configuration.manifestExists(compiler.root):
    for location in configuration.manifestFiles(compiler.root):
      compiler.inputs[absolutePath(location).replace('\\', '/')] =
        digest(readFile(location))
    let manifest = configuration.readProject(compiler.root)
    if manifest.hasKey("name") and manifest["name"].kind == JString:
      base.package = manifest["name"].getStr
    if manifest.hasKey("requires") and manifest["requires"].kind == JString:
      base.requires = manifest["requires"].getStr
  let lowered = monomorphize(base)
  var paths: seq[string]
  for path in compiler.inputs.keys: paths.add(path)
  paths.sort()
  for path in paths: lowered.inputs.add((path, compiler.inputs[path]))
  let errors = validate(lowered)
  if errors.len > 0: raise newException(ValueError, errors.mapIt(it.msg).join("\n"))
  if compiler.optimization or compiler.mode == "release":
    let optimized = optimize(lowered, Policy(inline: compiler.mode == "release",
      target: compiler.target, cpu: compiler.cpu, backend: compiler.backend,
      mode: compiler.mode, vectorize: compiler.mode == "release" and
        compiler.runtime != "none", hot: compiler.hot)).module
    let invalid = validate(optimized)
    if invalid.len > 0: raise newException(ValueError, invalid.mapIt(it.msg).join("\n"))
    return optimized
  lowered

proc graph*(compiler: Compiler; files: seq[string]): JsonNode =
  var resolution: modules.Resolution
  var initialized = false
  for file in files:
    let path = absolutePath(file)
    if not fileExists(path): raise newException(IOError, "File not found: " & path)
    let diag = engine()
    let parsed = compiler.parse(path, readFile(path), diag)
    if diag.failed:
      var error: Diagnostics
      new(error); error.msg = "Check failed"; error.diagnostics = diag
      raise error
    let current = resolver(diag, compiler.root, parse =
      proc(importedFile, input: string; diagnostics: Engine): Program =
        result = compiler.parse(importedFile, input, diagnostics)
        if not diagnostics.failed: prepare(result)).resolve(parsed, path)
    if diag.failed:
      var error: Diagnostics
      new(error); error.msg = "Check failed"; error.diagnostics = diag
      raise error
    if not initialized:
      resolution = current
      initialized = true
    else:
      for name, unit in current.units: resolution.units[name] = unit
      for name in current.order:
        if name notin resolution.order: resolution.order.add(name)
  modules.graph(resolution)
