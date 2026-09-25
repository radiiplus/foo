import std/[json, os, sequtils, strutils, tables]
import ../diag/engine
import ../lex/lexer
import ../parse/parser
import ../sema/resolver
import ../sema/link
import ../sema/module as semaModule
import ../types/checker
import ../types/type as semantic
import ../ir/lower
import ../ir/eval as eval
import ../ir/monomorph
from ../ir/node import Module
import ../ir/valid
import ../ast/node
import ../pkg/hash
import ../pkg/lint
import ../interop/expand as interopExpand
import "../interop/bind.nim" as cBinding

type
  Diagnostics* = ref object of CatchableError
    diagnostics*: Engine
  CheckResult* = object
    cached*: bool
  Compiler* = ref object
    root*: string
    backend*: string
    includes*: seq[string]
    mode*: string
    optimization*: bool
    target*: string
    cpu*: string
    checked*: Table[string, string]
    programs*: Table[string, Program]
    typings*: Table[string, Table[pointer, semantic.Type]]

proc newCompiler*(root: string; backend = "zig"; includes: seq[string] = @[];
    mode = "dev"; optimization = false; target = ""; cpu = ""): Compiler =
  Compiler(root: absolutePath(root), backend: backend, includes: includes, mode: mode,
    optimization: optimization, target: target, cpu: cpu,
    checked: initTable[string, string](), programs: initTable[string, Program](),
    typings: initTable[string, Table[pointer, semantic.Type]]())

proc parseSource(compiler: Compiler; file, source: string; diag: Engine): Program =
  diag.setSource(source, file)
  let tokens = newLexer(source, diag).lex()
  result = newParser(tokens, diag).parse()
  if not diag.failed: eval.expand(result)
  if not diag.failed:
    interopExpand.expand(result, diag, compiler.root,
      cBinding.BindOptions(includePaths: compiler.includes))

proc prepareEntry(program: Program) =
  if program == nil or program.units.len == 0: return
  let unit = program.units[0]
  var ioQualifier, logQualifier: string
  for statement in unit.body.stmts:
    if statement.tag != "use": continue
    let imported = Use(statement)
    if imported.path.len > 0: continue
    let qualifier = if imported.alias != nil: imported.alias.text else: imported.name.text
    if imported.name.text == "io": ioQualifier = qualifier
    elif imported.name.text == "log": logQualifier = qualifier

  var needsIo, needsLog: bool
  proc inspect(expression: Expression)
  proc inspectBlock(body: Block)
  proc inspectStatement(statement: Statement)
  proc inspect(expression: Expression) =
    if expression == nil: return
    case expression.tag
    of "call":
      let call = Call(expression)
      if call.callee.tag == "name":
        let name = Name(call.callee).text
        if name == "display": needsIo = true
        elif name in ["__bare_log.message", "__bare_log.error"]: needsLog = true
      inspect(call.callee)
      for argument in call.args: inspect(argument)
    of "unary": inspect(Unary(expression).operand)
    of "binary": inspect(Binary(expression).left); inspect(Binary(expression).right)
    of "group": inspect(Group(expression).expr)
    of "field": inspect(Field(expression).object)
    of "index": inspect(Index(expression).object); inspect(Index(expression).index)
    of "allocation": inspect(Allocation(expression).size); inspect(Allocation(expression).owner)
    of "error-chain": inspect(ErrorChain(expression).expr); inspect(ErrorChain(expression).context)
    else: discard
  proc inspectStatement(statement: Statement) =
    if statement == nil: return
    case statement.tag
    of "constant": inspect(Constant(statement).value)
    of "mutable": inspect(Mutable(statement).value)
    of "function": inspectBlock(Function(statement).body)
    of "give": inspect(Give(statement).value)
    of "assignment": inspect(Assignment(statement).target); inspect(Assignment(statement).value)
    of "when":
      inspect(`When`(statement).cond); inspectBlock(`When`(statement).then)
      if `When`(statement).else != nil:
        if `When`(statement).else.tag == "block": inspectBlock(Block(`When`(statement).else))
        else: inspectStatement(Statement(`When`(statement).else))
    of "while": inspect(`While`(statement).cond); inspectBlock(`While`(statement).body)
    of "repeat": inspect(Repeat(statement).limit); inspectBlock(Repeat(statement).body)
    of "for": inspect(`For`(statement).iter); inspectBlock(`For`(statement).body)
    of "match":
      inspect(Match(statement).scrutinee)
      for branch in Match(statement).cases: inspect(branch.guard); inspectBlock(branch.body)
    of "try": inspect(`Try`(statement).expr)
    of "defer":
      if `Defer`(statement).body.tag == "block": inspectBlock(Block(`Defer`(statement).body))
      else: inspect(Expression(`Defer`(statement).body))
    of "unsafe": inspectBlock(Unsafe(statement).body)
    of "action":
      let action = Action(statement)
      if action.value != nil: inspect(action.value)
      elif action.name.text == "display": needsIo = true
      for argument in action.args: inspect(argument)
    else: discard
  proc inspectBlock(body: Block) =
    if body != nil:
      for statement in body.stmts: inspectStatement(statement)
  inspectBlock(unit.body)

  if needsIo and ioQualifier.len == 0: ioQualifier = "__prelude_io"
  if needsLog and logQualifier.len == 0: logQualifier = "__prelude_log"

  proc rewrite(expression: Expression)
  proc rewriteBlock(body: Block)
  proc rewriteStatement(statement: Statement)
  proc rewrite(expression: Expression) =
    if expression == nil: return
    case expression.tag
    of "call":
      let call = Call(expression)
      if call.callee.tag == "name":
        let name = Name(call.callee)
        if name.text == "display": name.text = ioQualifier & ".show"
        elif name.text == "__bare_log.message": name.text = logQualifier & ".showMessage"
        elif name.text == "__bare_log.error": name.text = logQualifier & ".showError"
      rewrite(call.callee)
      for argument in call.args: rewrite(argument)
    of "unary": rewrite(Unary(expression).operand)
    of "binary": rewrite(Binary(expression).left); rewrite(Binary(expression).right)
    of "group": rewrite(Group(expression).expr)
    of "field": rewrite(Field(expression).object)
    of "index": rewrite(Index(expression).object); rewrite(Index(expression).index)
    of "allocation": rewrite(Allocation(expression).size); rewrite(Allocation(expression).owner)
    of "error-chain": rewrite(ErrorChain(expression).expr); rewrite(ErrorChain(expression).context)
    else: discard
  proc rewriteStatement(statement: Statement) =
    if statement == nil: return
    case statement.tag
    of "constant": rewrite(Constant(statement).value)
    of "mutable": rewrite(Mutable(statement).value)
    of "function": rewriteBlock(Function(statement).body)
    of "give": rewrite(Give(statement).value)
    of "assignment": rewrite(Assignment(statement).target); rewrite(Assignment(statement).value)
    of "when":
      rewrite(`When`(statement).cond); rewriteBlock(`When`(statement).then)
      if `When`(statement).else != nil:
        if `When`(statement).else.tag == "block": rewriteBlock(Block(`When`(statement).else))
        else: rewriteStatement(Statement(`When`(statement).else))
    of "while": rewrite(`While`(statement).cond); rewriteBlock(`While`(statement).body)
    of "repeat": rewrite(Repeat(statement).limit); rewriteBlock(Repeat(statement).body)
    of "for": rewrite(`For`(statement).iter); rewriteBlock(`For`(statement).body)
    of "match":
      rewrite(Match(statement).scrutinee)
      for branch in Match(statement).cases: rewrite(branch.guard); rewriteBlock(branch.body)
    of "try": rewrite(`Try`(statement).expr)
    of "defer":
      if `Defer`(statement).body.tag == "block": rewriteBlock(Block(`Defer`(statement).body))
      else: rewrite(Expression(`Defer`(statement).body))
    of "unsafe": rewriteBlock(Unsafe(statement).body)
    of "action":
      let action = Action(statement)
      if action.value != nil: rewrite(action.value)
      elif action.name.text == "display": action.name.text = ioQualifier & ".show"
      for argument in action.args: rewrite(argument)
    else: discard
  proc rewriteBlock(body: Block) =
    if body != nil:
      for statement in body.stmts: rewriteStatement(statement)

  rewriteBlock(unit.body)
  var prefix: seq[Statement]
  if needsIo and not unit.body.stmts.anyIt(it.tag == "use" and Use(it).path.len == 0 and Use(it).name.text == "io"):
    prefix.add(Use(tag: "use", span: unit.span,
      name: Name(tag: "name", span: unit.span, text: "io"),
      alias: Name(tag: "name", span: unit.span, text: ioQualifier)))
  if needsLog and not unit.body.stmts.anyIt(it.tag == "use" and Use(it).path.len == 0 and Use(it).name.text == "log"):
    prefix.add(Use(tag: "use", span: unit.span,
      name: Name(tag: "name", span: unit.span, text: "log"),
      alias: Name(tag: "name", span: unit.span, text: logQualifier)))
  if prefix.len > 0: unit.body.stmts = prefix & unit.body.stmts

  let hasStart = unit.body.stmts.anyIt(it.tag == "function" and Function(it).name.text == "start")
  if hasStart: return
  const executable = ["give", "when", "while", "repeat", "for", "match",
    "assignment", "break", "continue", "try", "defer", "unsafe", "action",
    "machine", "advance", "unreachable-statement"]
  var declarations, body: seq[Statement]
  for statement in unit.body.stmts:
    if statement.tag in executable: body.add(statement)
    else: declarations.add(statement)
  if body.len == 0: return
  declarations.add(Function(tag: "function", span: body[0].span,
    name: Name(tag: "name", span: body[0].span, text: "start"), params: @[],
    body: Block(tag: "block", span: body[0].span, stmts: body)))
  unit.body.stmts = declarations

proc program*(compiler: Compiler; file: string): Program =
  let path = absolutePath(file)
  if not fileExists(path): raise newException(IOError, "File not found: " & path)
  let source = readFile(path)
  let diag = newEngine()
  var parsed = compiler.parseSource(path, source, diag)
  if not diag.failed: prepareEntry(parsed)
  if not diag.failed:
    let resolver = newResolver(diag, compiler.root, parse =
      proc(file, input: string; diagnostics: Engine): Program =
        compiler.parseSource(file, input, diagnostics))
    let resolution = resolver.resolve(parsed, "main")
    if not diag.failed: parsed = link(parsed, resolution)
  if not diag.failed: lint(parsed, diag, compiler.backend)
  if not diag.failed:
    let checker = newChecker(diag)
    checker.check(parsed)
    compiler.typings[path] = checker.types
  if not diag.failed:
    let manifestPath = compiler.root / "project.json"
    let manifest = parseJson(if fileExists(manifestPath):
      readFile(manifestPath) else: "{}")
    let level = if manifest.hasKey("requires") and
        manifest["requires"].kind == JString: manifest["requires"].getStr()
      else: "base"
    capabilities(parsed, diag, level)
  if diag.failed:
    var error: Diagnostics
    new(error)
    error.msg = "Check failed"
    error.diagnostics = diag
    raise error
  compiler.programs[path] = parsed
  parsed

proc check*(compiler: Compiler; file: string): CheckResult =
  let path = absolutePath(file)
  if not fileExists(path): raise newException(IOError, "File not found: " & path)
  let digest = sha256Hex(readFile(path))
  if compiler.checked.getOrDefault(path) == digest: return CheckResult(cached: true)
  discard compiler.program(path)
  compiler.checked[path] = digest
  CheckResult(cached: false)

proc ir*(compiler: Compiler; file: string): Module =
  let program = compiler.program(file)
  let path = absolutePath(file)
  let base = lower(program, compiler.typings.getOrDefault(path))
  base.unitPath = relativePath(path, compiler.root).replace('\\', '/')
  let manifestPath = compiler.root / "project.json"
  if fileExists(manifestPath):
    let manifest = parseJson(readFile(manifestPath))
    if manifest.hasKey("name") and manifest["name"].kind == JString:
      base.unitPackage = manifest["name"].getStr
    if manifest.hasKey("requires") and manifest["requires"].kind == JString:
      base.requires = manifest["requires"].getStr
  let lowered = monomorphize(base)
  let errors = validate(lowered)
  if errors.len > 0: raise newException(ValueError, errors.mapIt(it.msg).join("\n"))
  if compiler.optimization or compiler.mode == "release":
    let optimized = optimize(lowered, OptimizeOptions(inline: compiler.mode == "release",
      target: compiler.target, cpu: compiler.cpu)).module
    let invalid = validate(optimized)
    if invalid.len > 0: raise newException(ValueError, invalid.mapIt(it.msg).join("\n"))
    return optimized
  lowered

proc graph*(compiler: Compiler; files: seq[string]): JsonNode =
  var resolution: semaModule.Resolution
  var initialized = false
  for file in files:
    let path = absolutePath(file)
    if not fileExists(path): raise newException(IOError, "File not found: " & path)
    let diag = newEngine()
    let parsed = compiler.parseSource(path, readFile(path), diag)
    if diag.failed:
      var error: Diagnostics
      new(error); error.msg = "Check failed"; error.diagnostics = diag
      raise error
    let current = newResolver(diag, compiler.root, parse =
      proc(importedFile, input: string; diagnostics: Engine): Program =
        compiler.parseSource(importedFile, input, diagnostics)).resolve(parsed, path)
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
  semaModule.graph(resolution)
