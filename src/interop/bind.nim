import std/[json, os, sequtils, strutils]
import ../build/files
import ../pkg/hash

type
  BindOptions* = object
    clangPath*: string
    includePaths*: seq[string]
    flags*: seq[string]
    cacheDir*: string
  BindDiagnostic* = object
    code*: string
    message*: string
    declaration*: string
  BindResult* = object
    source*: string
    bindingPath*: string
    hintsPath*: string
    diagnostics*: seq[BindDiagnostic]
    cached*: bool
  BindProvider* = proc(header: string; options: BindOptions): BindResult {.closure.}

var bindProvider*: BindProvider

proc setBindProvider*(provider: BindProvider) =
  ## Install a libclang/Clang AST provider. The built-in parser remains the fallback.
  bindProvider = provider

proc safeName(name: string): string =
  for character in name:
    result.add(if character.isAlphaNumeric or character == '_': character else: '_')
  if result.len == 0 or not result[0].isAlphaAscii or result in ["c", "type", "function", "constant", "mutable"]:
    result = "c_" & result

proc mapType(raw: string; diagnostics: var seq[BindDiagnostic]; declaration = ""): string =
  var value = raw.replace("const", "").replace("volatile", "").replace("restrict", "").strip()
  var pointers = 0
  while value.endsWith("*"):
    pointers.inc; value = value[0 ..< value.len - 1].strip()
  case value
  of "void": result = "nothing"
  of "_Bool", "bool": result = "boolean"
  of "char", "signed char": result = "integer 8"
  of "unsigned char": result = "byte"
  of "short", "short int": result = "integer 16"
  of "unsigned short", "unsigned short int": result = "unsigned 16"
  of "int", "signed int": result = "integer 32"
  of "unsigned", "unsigned int": result = "unsigned 32"
  of "long", "long int", "long long", "long long int": result = "integer 64"
  of "unsigned long", "unsigned long int", "unsigned long long", "unsigned long long int", "size_t": result = "unsigned 64"
  of "float": result = "decimal 32"
  of "double": result = "decimal 64"
  else:
    result = value.replace("struct ", "").replace("union ", "").replace("enum ", "")
    if result.len == 0 or result.contains({'(', ')', '[', ']', ','}):
      diagnostics.add(BindDiagnostic(code: "C_UNBINDABLE", message: "cannot represent C type '" & raw & "'", declaration: declaration))
      result = "opaque"
  for _ in 0 ..< pointers: result = "pointer to " & result

proc parseFunction(line: string; diagnostics: var seq[BindDiagnostic]): string =
  let opening = line.find('(')
  let closing = line.rfind(')')
  if opening <= 0 or closing < opening: return ""
  let head = line[0 ..< opening].strip().splitWhitespace()
  if head.len < 2: return ""
  let name = head[^1]
  let returnType = head[0 ..< head.high].join(" ")
  var params: seq[string]
  let body = line[opening + 1 ..< closing].strip()
  if body.len > 0 and body != "void":
    let rawParams = body.split(',')
    for index in 0 ..< rawParams.len:
      let rawParam = rawParams[index]
      let words = rawParam.strip().splitWhitespace()
      if words.len == 0: continue
      var paramName = if words.len > 1: words[^1] else: "arg" & $index
      var paramType = if words.len > 1: words[0 ..< words.high].join(" ") else: words[0]
      while paramName.startsWith("*"):
        paramType.add(" *"); paramName = paramName[1 .. ^1]
      params.add(safeName(paramName) & " of type " & mapType(paramType, diagnostics, paramName))
  "use \"c\" function " & safeName(name) & "(" & params.join(", ") & ") of type " & mapType(returnType, diagnostics, name) & "."

proc `bind`*(header: string; options = BindOptions()): BindResult =
  let headerPath = absolutePath(header)
  if not fileExists(headerPath): raise newException(IOError, "C header not found: " & headerPath)
  if bindProvider != nil: return bindProvider(headerPath, options)
  let content = readFile(headerPath)
  let key = sha256Hex(content & "\0" & options.includePaths.join("\0") & "\0" & options.flags.join("\0"))
  let cacheRoot = absolutePath(if options.cacheDir.len > 0: options.cacheDir else: ".artifacts" / "bindings")
  let entry = cacheRoot / key
  result.bindingPath = entry / (safeName(splitFile(headerPath).name) & ".iv")
  result.hintsPath = entry / "hints" / "bindings.iv"
  let diagnosticsPath = entry / "diagnostics.json"
  if fileExists(result.bindingPath) and fileExists(result.hintsPath) and fileExists(diagnosticsPath):
    result.source = readFile(result.bindingPath)
    result.cached = true
    return
  var declarations, hints: seq[string]
  for original in content.splitLines():
    let line = original.strip()
    if line.startsWith("#define "):
      let parts = line.splitWhitespace(maxsplit = 2)
      if parts.len == 3 and not parts[1].contains('('):
        let value = parts[2].strip(chars = {'(', ')'})
        if value.len > 0 and (value[0].isDigit or value[0] in {'-', '"'}): declarations.add("constant " & safeName(parts[1]) & " is " & value.strip(chars = {'u', 'U', 'l', 'L'}) & ".")
      elif parts.len >= 2: hints.add("-- " & line)
    elif line.endsWith(";") and line.contains('('):
      let declaration = parseFunction(line[0 ..< line.len - 1], result.diagnostics)
      if declaration.len > 0: declarations.add(declaration)
  result.source = "-- Declares generated C header bindings.\n" & declarations.join("\n") & "\n"
  write(result.bindingPath, result.source)
  write(result.hintsPath, "-- Function-like C macros have no linkable symbol.\n" & hints.join("\n") & "\n")
  var diagnosticNodes = newJArray()
  for issue in result.diagnostics: diagnosticNodes.add(%*{"code": issue.code, "message": issue.message, "declaration": issue.declaration})
  write(diagnosticsPath, pretty(diagnosticNodes) & "\n")
