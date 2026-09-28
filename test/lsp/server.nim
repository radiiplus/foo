import std/[json, strutils]
import ../../src/lsp/server

let lsp = newServer()
let initialized = lsp.handle(%*{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
doAssert initialized.len == 1
doAssert initialized[0]["result"]["capabilities"]["hoverProvider"].getBool()
let current = lsp.handle(%*{"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": "file:///current.iv", "version": 1, "text": """define Count as integer.
function load value integer default 1 giving failable integer { give value. }
function checked() giving failable integer { give load() try. }
dynamic count is load() fallback 0.
while count less than 3 {
  increase count by 1.
  when count equals 1 { skip. }
  when count equals 2 { stop. }
}
display "Hello, world!"."""}}})
doAssert current.len == 1
doAssert current[0]["params"]["diagnostics"].len == 0,
  $current[0]["params"]["diagnostics"]
let opened = lsp.handle(%*{"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": "file:///main.iv", "version": 1, "text": "constant answer is 42.\nstart() { give answer. }"}}})
doAssert opened.len == 1
doAssert opened[0]["method"].getStr() == "textDocument/publishDiagnostics"
doAssert opened[0]["params"]["diagnostics"].len == 0
let invalid = lsp.handle(%*{"jsonrpc": "2.0", "method": "textDocument/didChange", "params": {"textDocument": {"uri": "file:///main.iv", "version": 2}, "contentChanges": [{"text": "constant answer is ."}]}})
doAssert invalid[0]["params"]["diagnostics"].len > 0
let repaired = lsp.handle(%*{"jsonrpc": "2.0", "method": "textDocument/didChange", "params": {"textDocument": {"uri": "file:///main.iv", "version": 3}, "contentChanges": [{"text": "constant answer is 42.\nstart() { give answer. }"}]}})
doAssert repaired[0]["params"]["diagnostics"].len == 0
let definition = lsp.handle(%*{"jsonrpc": "2.0", "id": 4, "method": "textDocument/definition", "params": {"textDocument": {"uri": "file:///main.iv"}, "position": {"line": 1, "character": 16}}})
doAssert definition[0]["result"].kind == JObject
doAssert definition[0]["result"]["range"]["start"]["line"].getInt() == 0
let hover = lsp.handle(%*{"jsonrpc": "2.0", "id": 5, "method": "textDocument/hover", "params": {"textDocument": {"uri": "file:///main.iv"}, "position": {"line": 1, "character": 16}}})
doAssert hover[0]["result"].kind == JObject
doAssert hover[0]["result"]["contents"]["value"].getStr().len > 0
doAssert frame(initialized[0]).startsWith("Content-Length:")
discard lsp.handle(%*{"jsonrpc": "2.0", "id": 2, "method": "shutdown"})
let rejected = lsp.handle(%*{"jsonrpc": "2.0", "id": 3, "method": "unknown"})
doAssert rejected[0]["error"]["code"].getInt() == -32600
echo "lsp server parity: ok"
