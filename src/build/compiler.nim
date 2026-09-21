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
import ../ir/node
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

proc program*(compiler: Compiler; file: string): Program =
  let path = absolutePath(file)
  if not fileExists(path): raise newException(IOError, "File not found: " & path)
  let source = readFile(path)
  let diag = newEngine()
  var parsed = compiler.parseSource(path, source, diag)
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
