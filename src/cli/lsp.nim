import std/[json, os, strutils, tables, uri]
import ../ast/node as ast
import ../diag/engine
import ../diag/render
import ../build/compiler as compilation
import ../build/project as workspace
import ../sema/module
import ../types/type as semantic

type
  Document* = object
    uri*: string
    file*: string
    source*: string
    version*: int
    program*: ast.Program
    resolution*: Resolution
    types*: Table[pointer, semantic.Type]
    diagnosticItems*: JsonNode
  Server* = ref object
    root*: string
    stopped*: bool
    documents*: Table[string, Document]

proc server*(root = getCurrentDir()): Server =
  Server(root: absolutePath(root), documents: initTable[string, Document]())

proc response(id, value: JsonNode): JsonNode = %*{"jsonrpc": "2.0", "id": id, "result": value}
proc failure(id: JsonNode; code: int; message: string): JsonNode = %*{"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}

proc path(root, uri: string): string =
  if uri.startsWith("file:///"):
    let path = decodeUrl(uri[8 .. ^1])
    when defined(windows): result = path.replace('/', '\\')
    else: result = "/" & path
  elif uri.startsWith("file://"):
    result = decodeUrl(uri[7 .. ^1])
  elif isAbsolute(uri): result = uri
  else: result = root / uri

proc uri(path: string): string =
  when defined(windows): "file:///" & absolutePath(path).replace('\\', '/')
  else: "file://" & absolutePath(path)

proc analyze(root, uri, source: string; version: int): Document =
  let engine = engine()
  let file = path(root, uri)
  let project = workspace.project(root)
  let compiler = workspace.compiler(project)
  let analysis = compilation.analyze(compiler, file, source, engine)
  var items = newJArray()
  for message in engine.messages:
    items.add(diagnostic(message))
  Document(uri: uri, file: file, source: source, version: version,
    program: analysis.program, resolution: analysis.resolution,
    types: analysis.types, diagnosticItems: items)

proc diagnostics(document: Document): JsonNode =
  %*{"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": document.uri, "version": document.version, "diagnostics": document.diagnosticItems}}

proc offset(source: string; line, character: int): int =
  var current = 0
  while result < source.len and current < line:
    if source[result] == '\n': current.inc
    result.inc
  min(result + character, source.len)

proc node(document: Document; line, character: int): ast.Node =
  let offset = offset(document.source, line, character)
  var width = high(int)
  for key in document.resolution.resolutions.keys:
    let node = cast[ast.Node](key)
    if node != nil and node.span.start <= offset and offset <= node.span.`end`:
      let candidate = node.span.`end` - node.span.start
      if candidate < width: result = node; width = candidate
  for key in document.types.keys:
    let node = cast[ast.Node](key)
    if node != nil and node.span.start <= offset and offset <= node.span.`end`:
      let candidate = node.span.`end` - node.span.start
      if candidate < width: result = node; width = candidate

proc range(node: ast.Node): JsonNode =
  let line = max(node.span.line - 1, 0)
  let column = max(node.span.col - 1, 0)
  %*{"start": {"line": line, "character": column},
    "end": {"line": line, "character": column + max(node.span.`end` - node.span.start, 1)}}

proc definition(document: Document; line, character: int): JsonNode =
  let node = node(document, line, character)
  if node == nil: return newJNull()
  let key = cast[pointer](node)
  if not document.resolution.resolutions.hasKey(key): return newJNull()
  let symbol = document.resolution.resolutions[key]
  var file = document.file
  if document.resolution.units.hasKey(symbol.module): file = document.resolution.units[symbol.module].file
  let uri = uri(file)
  %*{"uri": uri, "range": range(symbol.node)}

proc hover(document: Document; line, character: int): JsonNode =
  let node = node(document, line, character)
  if node == nil: return newJNull()
  let key = cast[pointer](node)
  if document.types.hasKey(key):
    return %*{"contents": {"kind": "plaintext", "value": label(document.types[key])}, "range": range(node)}
  if document.resolution.resolutions.hasKey(key):
    let symbol = document.resolution.resolutions[key]
    return %*{"contents": {"kind": "plaintext", "value": symbol.name}, "range": range(node)}
  newJNull()

proc handle*(server: Server; message: JsonNode): seq[JsonNode] =
  let identifier = if message.hasKey("method"): message["method"].getStr() else: ""
  let id = if message.hasKey("id"): message["id"] else: newJNull()
  case identifier
  of "initialize":
    let params = message.getOrDefault("params")
    if params != nil and params.kind == JObject:
      let repository = params.getOrDefault("rootUri")
      if repository != nil and repository.kind == JString and repository.getStr().len > 0:
        server.root = absolutePath(path(server.root, repository.getStr()))
    result.add(response(id, %*{"capabilities": {"textDocumentSync": {"openClose": true, "change": 1}, "definitionProvider": true, "hoverProvider": true}}))
  of "shutdown":
    server.stopped = true
    result.add(response(id, newJNull()))
  of "exit": discard
  else:
    if server.stopped:
      if message.hasKey("id"): result.add(failure(id, -32600, "Server has shut down"))
    elif identifier in ["textDocument/didOpen", "textDocument/didChange"]:
      let params = message["params"]
      let text = params["textDocument"]
      let uri = text["uri"].getStr()
      let version = text.getOrDefault("version").getInt()
      let source = if identifier.endsWith("didOpen"): text["text"].getStr() else: params["contentChanges"][^1]["text"].getStr()
      let previous = server.documents.getOrDefault(uri)
      if previous.uri.len == 0 or version >= previous.version:
        let document = analyze(server.root, uri, source, version)
        server.documents[uri] = document
        result.add(diagnostics(document))
    elif identifier == "textDocument/didClose":
      let uri = message["params"]["textDocument"]["uri"].getStr()
      server.documents.del(uri)
      result.add(%*{"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": uri, "diagnostics": []}})
    elif identifier in ["textDocument/definition", "textDocument/hover"]:
      let params = message["params"]
      let uri = params["textDocument"]["uri"].getStr()
      if not server.documents.hasKey(uri): result.add(response(id, newJNull()))
      else:
        let position = params["position"]
        let line = position["line"].getInt()
        let character = position["character"].getInt()
        result.add(response(id, if identifier.endsWith("definition"): definition(server.documents[uri], line, character) else: hover(server.documents[uri], line, character)))
    elif message.hasKey("id"):
      result.add(failure(id, -32601, "Method not supported"))

proc frame*(message: JsonNode): string =
  let content = $message
  "Content-Length: " & $content.len & "\r\n\r\n" & content

proc frame(input: File): string =
  var length = -1
  var line: string
  while input.readLine(line):
    let header = line.strip()
    if header.len == 0: break
    let separator = header.find(':')
    if separator > 0 and
        header[0 ..< separator].strip().toLowerAscii() == "content-length":
      length = parseInt(header[separator + 1 .. ^1].strip())
  if length < 0: return ""
  result = newString(length)
  var offset = 0
  while offset < length:
    let count = input.readBuffer(addr result[offset], length - offset)
    if count <= 0: return ""
    offset += count

proc serve*(server = server()) =
  while true:
    let content = frame(stdin)
    if content.len == 0: break
    try:
      for reply in server.handle(parseJson(content)):
        stdout.write(frame(reply))
      stdout.flushFile()
    except CatchableError as error:
      stdout.write(frame(failure(newJNull(), -32700, error.msg)))
      stdout.flushFile()

when isMainModule: serve()
