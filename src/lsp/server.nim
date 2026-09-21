import std/[json, os, strutils, tables]
import ../ast/node as ast
import ../diag/engine
import ../lex/lexer
import ../parse/parser
import ../sema/[module, resolver]
import ../types/checker
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

proc newServer*(root = getCurrentDir()): Server =
  Server(root: absolutePath(root), documents: initTable[string, Document]())

proc response(id, value: JsonNode): JsonNode = %*{"jsonrpc": "2.0", "id": id, "result": value}
proc failure(id: JsonNode; code: int; message: string): JsonNode = %*{"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}

proc documentPath(root, uri: string): string =
  if uri.startsWith("file:///"):
    result = uri[8 .. ^1]
    when defined(windows): result = result.replace('/', '\\')
  elif uri.startsWith("file://"):
    result = uri[7 .. ^1]
  elif isAbsolute(uri): result = uri
  else: result = root / uri

proc analyze(root, uri, source: string; version: int): Document =
  let engine = newEngine()
  let file = documentPath(root, uri)
  engine.setSource(source, file)
  let program = newParser(newLexer(source, engine).lex(), engine).parse()
  var resolution: Resolution
  var types = initTable[pointer, semantic.Type]()
  if not engine.failed:
    resolution = newResolver(engine, root).resolve(program, file)
    let typeChecker = newChecker(engine)
    typeChecker.check(program)
    types = typeChecker.types
  var items = newJArray()
  for message in engine.messages:
    let line = max(message.span.line - 1, 0)
    let column = max(message.span.col - 1, 0)
    items.add(%*{"range": {"start": {"line": line, "character": column}, "end": {"line": line, "character": column + max(message.span.`end` - message.span.start, 1)}}, "severity": 1, "source": "foo", "message": message.text})
  Document(uri: uri, file: file, source: source, version: version, program: program,
    resolution: resolution, types: types, diagnosticItems: items)

proc diagnostics(document: Document): JsonNode =
  %*{"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": document.uri, "version": document.version, "diagnostics": document.diagnosticItems}}

proc offsetAt(source: string; line, character: int): int =
  var currentLine = 0
  while result < source.len and currentLine < line:
    if source[result] == '\n': currentLine.inc
    result.inc
  min(result + character, source.len)

proc nodeAt(document: Document; line, character: int): ast.Node =
  let offset = offsetAt(document.source, line, character)
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

proc lspRange(node: ast.Node): JsonNode =
  let line = max(node.span.line - 1, 0)
  let column = max(node.span.col - 1, 0)
  %*{"start": {"line": line, "character": column},
    "end": {"line": line, "character": column + max(node.span.`end` - node.span.start, 1)}}

proc definition(document: Document; line, character: int): JsonNode =
  let node = nodeAt(document, line, character)
  if node == nil: return newJNull()
  let key = cast[pointer](node)
  if not document.resolution.resolutions.hasKey(key): return newJNull()
  let symbol = document.resolution.resolutions[key]
  var file = document.file
  if document.resolution.units.hasKey(symbol.module): file = document.resolution.units[symbol.module].file
  let uri = "file:///" & absolutePath(file).replace('\\', '/')
  %*{"uri": uri, "range": lspRange(symbol.node)}

proc hover(document: Document; line, character: int): JsonNode =
  let node = nodeAt(document, line, character)
  if node == nil: return newJNull()
  let key = cast[pointer](node)
  if document.types.hasKey(key):
    return %*{"contents": {"kind": "plaintext", "value": typeToString(document.types[key])}, "range": lspRange(node)}
  if document.resolution.resolutions.hasKey(key):
    let symbol = document.resolution.resolutions[key]
    return %*{"contents": {"kind": "plaintext", "value": symbol.name}, "range": lspRange(node)}
  newJNull()

proc handle*(server: Server; message: JsonNode): seq[JsonNode] =
  let methodName = if message.hasKey("method"): message["method"].getStr() else: ""
  let id = if message.hasKey("id"): message["id"] else: newJNull()
  case methodName
  of "initialize":
    result.add(response(id, %*{"capabilities": {"textDocumentSync": {"openClose": true, "change": 1}, "definitionProvider": true, "hoverProvider": true}}))
  of "shutdown":
    server.stopped = true
    result.add(response(id, newJNull()))
  of "exit": discard
  else:
    if server.stopped:
      if message.hasKey("id"): result.add(failure(id, -32600, "Server has shut down"))
    elif methodName in ["textDocument/didOpen", "textDocument/didChange"]:
      let params = message["params"]
      let textDocument = params["textDocument"]
      let uri = textDocument["uri"].getStr()
      let version = textDocument.getOrDefault("version").getInt()
      let source = if methodName.endsWith("didOpen"): textDocument["text"].getStr() else: params["contentChanges"][^1]["text"].getStr()
      let previous = server.documents.getOrDefault(uri)
      if previous.uri.len == 0 or version >= previous.version:
        let document = analyze(server.root, uri, source, version)
        server.documents[uri] = document
        result.add(diagnostics(document))
    elif methodName == "textDocument/didClose":
      let uri = message["params"]["textDocument"]["uri"].getStr()
      server.documents.del(uri)
      result.add(%*{"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": uri, "diagnostics": []}})
    elif methodName in ["textDocument/definition", "textDocument/hover"]:
      let params = message["params"]
      let uri = params["textDocument"]["uri"].getStr()
      if not server.documents.hasKey(uri): result.add(response(id, newJNull()))
      else:
        let position = params["position"]
        let line = position["line"].getInt()
        let character = position["character"].getInt()
        result.add(response(id, if methodName.endsWith("definition"): definition(server.documents[uri], line, character) else: hover(server.documents[uri], line, character)))
    elif message.hasKey("id"):
      result.add(failure(id, -32601, "Method not supported"))

proc frame*(message: JsonNode): string =
  let content = $message
  "Content-Length: " & $content.len & "\r\n\r\n" & content

proc serve*(server = newServer()) =
  let input = stdin.readAll()
  var offset = 0
  while offset < input.len:
    let marker = input.find("\r\n\r\n", offset)
    if marker < 0: break
    let header = input[offset ..< marker]
    let label = "Content-Length:"
    let location = header.toLowerAscii().find(label.toLowerAscii())
    if location < 0: break
    let length = parseInt(header[location + label.len .. ^1].strip())
    let start = marker + 4
    if start + length > input.len: break
    try:
      for reply in server.handle(parseJson(input[start ..< start + length])): stdout.write(frame(reply))
    except CatchableError as error:
      stdout.write(frame(failure(newJNull(), -32700, error.msg)))
    offset = start + length

when isMainModule: serve()
