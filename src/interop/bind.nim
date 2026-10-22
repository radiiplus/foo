import std/[json, os, osproc, strutils, tables, sets]
import ../build/files
import ../pkg/hash

type
  Binding* = object
    compiler*: string
    target*: string
    sysroot*: string
    includes*: seq[string]
    flags*: seq[string]
    cacheDir*: string
  Issue* = object
    code*: string
    message*: string
    declaration*: string
  Outcome* = object
    source*: string
    bindingPath*: string
    hintsPath*: string
    dependencies*: seq[string]
    diagnostics*: seq[Issue]
    cached*: bool
  Provider* = proc(header: string; options: Binding): Outcome {.closure.}

var delegate*: Provider

proc provider*(provider: Provider) =
  ## Install a libclang/Clang AST provider. The built-in parser remains the fallback.
  delegate = provider

proc safe(name: string): string =
  for character in name:
    result.add(if character.isAlphaNumeric or character == '_': character else: '_')
  if result.len == 0 or not result[0].isAlphaAscii or result in ["c", "define", "type", "function", "constant", "dynamic", "mutable", "fallback", "stop", "skip"]:
    result = "c_" & result

proc map(raw: string; diagnostics: var seq[Issue]; declaration, target: string;
    aliases: Table[string, string]): string =
  var value = raw.replace("const", "").replace("volatile", "").replace("restrict", "").strip()
  var pointers = 0
  while value.endsWith("*"):
    pointers.inc; value = value[0 ..< value.len - 1].strip()
  let windows = if target.len > 0: target.contains("windows")
    else: defined(windows)
  let narrow = target.startsWith("wasm32") or target in
    ["wasm-freestanding", "wasi", "wasi-threads"] or
    target.startsWith("i386") or target.startsWith("x86-") or
    target.startsWith("armv7")
  if value in aliases:
    result = aliases[value]
    for _ in 0 ..< pointers: result = "pointer to " & result
    return
  case value
  of "void": result = "nothing"
  of "_Bool", "bool": result = "boolean"
  of "char", "signed char": result = "integer 8"
  of "unsigned char": result = "byte"
  of "short", "short int": result = "integer 16"
  of "unsigned short", "unsigned short int": result = "unsigned 16"
  of "int", "signed int": result = "integer 32"
  of "unsigned", "unsigned int": result = "unsigned 32"
  of "long", "long int":
    result = if windows or narrow: "integer 32" else: "integer"
  of "unsigned long", "unsigned long int":
    result = if windows or narrow: "unsigned 32" else: "unsigned"
  of "long long", "long long int": result = "integer"
  of "unsigned long long", "unsigned long long int": result = "unsigned"
  of "size_t": result = if narrow: "unsigned 32" else: "unsigned"
  of "ssize_t": result = if narrow: "integer 32" else: "integer"
  of "int8_t": result = "integer 8"
  of "uint8_t": result = "byte"
  of "int16_t": result = "integer 16"
  of "uint16_t": result = "unsigned 16"
  of "int32_t": result = "integer 32"
  of "uint32_t": result = "unsigned 32"
  of "int64_t": result = "integer"
  of "uint64_t": result = "unsigned"
  of "intptr_t", "ptrdiff_t": result = if narrow: "integer 32" else: "integer"
  of "uintptr_t": result = if narrow: "unsigned 32" else: "unsigned"
  of "float": result = "decimal 32"
  of "double": result = "decimal"
  else:
    result = value.replace("struct ", "").replace("union ", "").replace("enum ", "")
    if result.len == 0 or result.contains({'(', ')', '[', ']', ','}):
      diagnostics.add(Issue(code: "C_UNBINDABLE", message: "cannot represent C type '" & raw & "'", declaration: declaration))
      result = "opaque"
  for _ in 0 ..< pointers: result = "pointer to " & result

proc formal(raw: string; index: int; diagnostics: var seq[Issue];
    target: string; aliases: Table[string, string]): tuple[label, typ: string] =
  let callback = raw.find("(*")
  if callback >= 0:
    let close = raw.find(')', callback + 2)
    let opening = if close >= 0: raw.find('(', close + 1) else: -1
    let ending = raw.rfind(')')
    if callback > 0 and close > callback + 2 and opening > close and
        ending > opening and raw[ending + 1 .. ^1].strip().len == 0:
      let name = raw[callback + 2 ..< close].strip()
      let body = raw[opening + 1 ..< ending].strip()
      if body.contains("...") or body.contains("(*"):
        diagnostics.add(Issue(code: "C_UNBINDABLE",
          message: "unsupported C callback parameter: '" & raw & "'",
          declaration: raw))
        return
      var params: seq[string]
      if body.len > 0 and body != "void":
        let items = body.split(',')
        for position, item in items.pairs:
          params.add(formal(item, position, diagnostics, target, aliases).typ)
      return (safe(name), "function" &
        (if params.len > 0: " taking (" & params.join(", ") & ")" else: "") &
        " giving " & map(raw[0 ..< callback].strip(), diagnostics,
          name, target, aliases))
    diagnostics.add(Issue(code: "C_UNBINDABLE",
      message: "unsupported C callback parameter: '" & raw & "'",
      declaration: raw))
    return
  let words = raw.strip().splitWhitespace()
  if words.len == 0: return
  var label = if words.len > 1: words[^1] else: "arg" & $index
  var representation = if words.len > 1:
      words[0 ..< words.high].join(" ")
    else: words[0]
  if label.contains('[') and label.endsWith("]"):
    label = label[0 ..< label.find('[')]
    representation.add(" *")
  while label.startsWith("*"):
    representation.add(" *"); label = label[1 .. ^1]
  result = (safe(label), map(representation, diagnostics, label, target, aliases))

proc function(line: string; diagnostics: var seq[Issue]; target: string;
    aliases: Table[string, string]): string =
  let declaration = if line.startsWith("extern \"C\" "):
      line[10 .. ^1].strip()
    else: line
  if declaration.contains("..."):
    diagnostics.add(Issue(code: "C_UNBINDABLE",
      message: "C variadic declarator requires an explicit binding: '" & line & "'",
      declaration: line))
    return ""
  let opening = declaration.find('(')
  let closing = declaration.rfind(')')
  if opening <= 0 or closing < opening: return ""
  let head = declaration[0 ..< opening].strip().splitWhitespace()
  if head.len < 2: return ""
  let name = head[^1]
  let returns = head[0 ..< head.high].join(" ")
  var params: seq[string]
  let body = declaration[opening + 1 ..< closing].strip()
  if body.len > 0 and body != "void":
    var formals: seq[string]
    var start = 0
    var depth = 0
    for position, character in body:
      if character == '(': inc depth
      elif character == ')': dec depth
      elif character == ',' and depth == 0:
        formals.add(body[start ..< position]); start = position + 1
    formals.add(body[start .. ^1])
    for index in 0 ..< formals.len:
      let parameter = formal(formals[index], index, diagnostics, target, aliases)
      if parameter.label.len == 0: return ""
      params.add(parameter.label & " " & parameter.typ)
  "extern \"C\" function " & safe(name) &
    (if params.len > 0: "(" & params.join(", ") & ")" else: "") &
    " giving " & map(returns, diagnostics, name, target, aliases) & "."

proc clangtarget(target: string): string =
  case target
  of "windows-x64": "x86_64-pc-windows-msvc"
  of "windows-arm64": "aarch64-pc-windows-msvc"
  of "linux-x64": "x86_64-unknown-linux-gnu"
  of "linux-arm64": "aarch64-unknown-linux-gnu"
  of "macos-x64": "x86_64-apple-darwin"
  of "macos-arm64": "aarch64-apple-darwin"
  of "wasm-freestanding": "wasm32-unknown-unknown"
  else: target

proc conditional(content: string): bool =
  for original in content.splitLines():
    let line = original.strip()
    if line.startsWith("#if ") or line.startsWith("#if(") or
        line.startsWith("#ifdef ") or line.startsWith("#ifndef "):
      return true

proc preprocess(header: string; options: Binding; cpp: bool;
    dependencies: var seq[string]): string =
  let compiler = if options.compiler.len > 0: options.compiler else: "clang"
  var command = quoteShell(compiler) & " -E -dD -x " &
    (if cpp: "c++" else: "c")
  if options.target.len > 0:
    command.add(" -target " & quoteShell(clangTarget(options.target)))
  if options.sysroot.len > 0:
    command.add(" --sysroot=" & quoteShell(options.sysroot))
    let headers = options.sysroot / "usr" / "include"
    if dirExists(headers): command.add(" -isystem " & quoteShell(headers))
  for directory in options.includes:
    command.add(" -I " & quoteShell(directory))
  for flag in options.flags:
    command.add(" " & quoteShell(flag))
  command.add(" " & quoteShell(header))
  let run = execCmdEx(command)
  if run.exitCode != 0:
    raise newException(ValueError, "C header preprocessing failed: " & run.output.strip())
  let base = absolutePath(parentDir(header))
  var allowed = @[base]
  for directory in options.includes: allowed.add(absolutePath(directory))
  if options.sysroot.len > 0: allowed.add(absolutePath(options.sysroot))
  var active = false
  for original in run.output.splitLines():
    let line = original.strip()
    if line.startsWith("# ") and line.contains('"'):
      let opening = line.find('"')
      let closing = line.find('"', opening + 1)
      active = false
      if closing > opening:
        let marker = line[opening + 1 ..< closing].replace("\\\\", "\\")
        if fileExists(marker):
          let path = absolutePath(marker)
          for directory in allowed:
            if path == directory or path.startsWith(directory & DirSep):
              active = true
              if path notin dependencies: dependencies.add(path)
              break
      continue
    if active:
      result.add(original & "\n")

proc `bind`*(header: string; options = Binding()): Outcome =
  let location = absolutePath(header)
  if not fileExists(location): raise newException(IOError, "C header not found: " & location)
  if options.sysroot.len > 0:
    if options.target.len == 0:
      raise newException(ValueError, "C header sysroot requires an explicit target")
    if not dirExists(options.sysroot):
      raise newException(IOError, "C header sysroot not found: " & options.sysroot)
  if delegate != nil: return delegate(location, options)
  let cpp = location.endsWith(".hpp") or location.endsWith(".hh") or
    location.endsWith(".hxx")
  var seen = initHashSet[string]()
  var sources: seq[tuple[path, content: string]]
  var missing: seq[string]
  proc collect(path: string) =
    let absolute = absolutePath(path)
    if absolute in seen: return
    seen.incl(absolute)
    let content = readFile(absolute)
    if not cpp:
      for original in content.splitLines():
        let line = original.strip()
        if not line.startsWith("#include \""): continue
        let closing = line.find('"', 10)
        if closing < 0: continue
        let name = line[10 ..< closing]
        var found = ""
        for directory in @[parentDir(absolute)] & options.includes:
          let candidate = absolutePath(directory / name)
          if fileExists(candidate):
            found = candidate
            break
        if found.len > 0: collect(found)
        else: missing.add(absolute & ":" & name)
    sources.add((absolute, content))
  collect(location)
  for source in sources: result.dependencies.add(source.path)
  var identity = ""
  var content = ""
  for source in sources:
    identity.add(source.path & "\0" & source.content & "\0")
    content.add(source.content & "\n")
  for path in missing: identity.add(path & "\0absent\0")
  if conditional(content) or options.sysroot.len > 0:
    content = preprocess(location, options, cpp, result.dependencies)
    identity.add(content)
    missing.setLen(0)
  let key = digest(identity & options.compiler & "\0" & options.target & "\0" &
    options.sysroot & "\0" &
    options.includes.join("\0") & "\0" & options.flags.join("\0"))
  let root = absolutePath(if options.cacheDir.len > 0: options.cacheDir else: ".artifacts" / "bindings")
  let entry = root / key
  result.bindingPath = entry / (safe(splitFile(location).name) & ".iv")
  result.hintsPath = entry / "hints" / "bindings.iv"
  let path = entry / "diagnostics.json"
  if fileExists(result.bindingPath) and fileExists(result.hintsPath) and fileExists(path):
    result.source = readFile(result.bindingPath)
    for issue in parseFile(path):
      result.diagnostics.add(Issue(code: issue["code"].getStr(),
        message: issue["message"].getStr(),
        declaration: issue["declaration"].getStr()))
    result.cached = true
    return
  var declarations, hints: seq[string]
  var aliases = initTable[string, string]()
  for path in missing:
    result.diagnostics.add(Issue(code: "C_HEADER",
      message: "C include was not found: " & path, declaration: path))
  var linkage = false
  for original in content.splitLines():
    let line = original.strip()
    if line.startsWith("typedef ") and line.endsWith(";"):
      let declaration = line[8 ..< line.len - 1].strip()
      let words = declaration.splitWhitespace()
      let callback = declaration.find("(*")
      if callback >= 0:
        let close = declaration.find(')', callback + 2)
        let opening = if close >= 0: declaration.find('(', close + 1) else: -1
        let ending = declaration.rfind(')')
        if callback > 0 and close > callback + 2 and opening > close and ending > opening:
          let name = declaration[callback + 2 ..< close].strip()
          let body = declaration[opening + 1 ..< ending].strip()
          var params: seq[string]
          if body.len > 0 and body != "void":
            let formals = body.split(',')
            for index in 0 ..< formals.len:
              params.add(formal(formals[index], index, result.diagnostics,
                options.target, aliases).typ)
          aliases[name] = "function" &
            (if params.len > 0: " taking (" & params.join(", ") & ")" else: "") &
            " giving " & map(declaration[0 ..< callback].strip(),
              result.diagnostics, name, options.target, aliases)
        else:
          result.diagnostics.add(Issue(code: "C_UNBINDABLE",
            message: "unsupported C callback typedef: '" & line & "'",
            declaration: line))
      elif words.len >= 2 and not declaration.contains({'(', ')', '[', ']', '{', '}' }):
        aliases[words[^1]] = map(words[0 ..< words.high].join(" "),
          result.diagnostics, words[^1], options.target, aliases)
      else:
        result.diagnostics.add(Issue(code: "C_UNBINDABLE",
          message: "C typedef requires a supported scalar or pointer type: '" & line & "'",
          declaration: line))
      continue
    if line == "extern \"C\" {":
      linkage = true
    elif linkage and line == "}":
      linkage = false
    elif line.startsWith("#define "):
      let parts = line.splitWhitespace(maxsplit = 2)
      if parts.len == 3 and not parts[1].contains('('):
        let value = parts[2].strip(chars = {'(', ')'})
        if value.len > 0 and (value[0].isDigit or value[0] in {'-', '"'}): declarations.add("constant " & safe(parts[1]) & " is " & value.strip(chars = {'u', 'U', 'l', 'L'}) & ".")
      elif parts.len >= 2: hints.add("-- " & line)
    elif line.startsWith("extern \"C++\""):
      result.diagnostics.add(Issue(code: "C_UNBINDABLE",
        message: "C++ linkage requires a C wrapper for '" & line & "'",
        declaration: line))
    elif line.endsWith(";") and line.contains('('):
      if cpp and not linkage and not line.startsWith("extern \"C\" "):
        result.diagnostics.add(Issue(code: "C_UNBINDABLE",
          message: "C++ declaration requires C linkage for '" & line & "'",
          declaration: line))
      else:
        let declaration = function(line[0 ..< line.len - 1],
          result.diagnostics, options.target, aliases)
        if declaration.len > 0: declarations.add(declaration)
  result.source = "-- Declares generated C header bindings.\n" & declarations.join("\n") & "\n"
  write(result.bindingPath, result.source)
  write(result.hintsPath, "-- Function-like C macros have no linkable symbol.\n" & hints.join("\n") & "\n")
  var nodes = newJArray()
  for issue in result.diagnostics: nodes.add(%*{"code": issue.code, "message": issue.message, "declaration": issue.declaration})
  write(path, pretty(nodes) & "\n")
