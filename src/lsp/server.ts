import { Lexer } from "../lex/lexer";
import { Parser } from "../parse/parser";
import { Resolver } from "../sema/resolver";
import { Engine } from "../diag/engine";

let buffer = "";

process.stdin.on("data", (chunk) => {
  buffer += chunk.toString("utf8");
  processBuffer();
});

function processBuffer() {
  while (true) {
    const headerEnd = buffer.indexOf("\r\n\r\n");
    if (headerEnd === -1) break;
    
    const header = buffer.substring(0, headerEnd);
    const match = header.match(/Content-Length: (\d+)/i);
    if (!match) break;
    
    const contentLength = parseInt(match[1], 10);
    const contentStart = headerEnd + 4;
    
    if (buffer.length < contentStart + contentLength) break;
    
    const content = buffer.substring(contentStart, contentStart + contentLength);
    buffer = buffer.substring(contentStart + contentLength);
    
    const msg = JSON.parse(content);
    handleMessage(msg);
  }
}

function sendMessage(msg: any) {
  const content = JSON.stringify(msg);
  const header = `Content-Length: ${Buffer.byteLength(content, "utf8")}\r\n\r\n`;
  process.stdout.write(header + content);
}

function handleMessage(msg: any) {
  if (msg.method === "initialize") {
    sendMessage({
      jsonrpc: "2.0",
      id: msg.id,
      result: {
        capabilities: {
          textDocumentSync: 1,
          definitionProvider: true,
          hoverProvider: true,
        }
      }
    });
  } else if (msg.method === "initialized") {
    // Client is ready
  } else if (msg.method === "textDocument/didOpen" || msg.method === "textDocument/didChange") {
    const doc = msg.method === "textDocument/didOpen" ? msg.params.textDocument : msg.params.textDocument;
    const src = msg.method === "textDocument/didOpen" ? doc.text : msg.params.contentChanges[0].text;
    validate(doc.uri, src);
  } else if (msg.method === "textDocument/definition") {
    sendMessage({ jsonrpc: "2.0", id: msg.id, result: null });
  } else if (msg.method === "textDocument/hover") {
    sendMessage({ jsonrpc: "2.0", id: msg.id, result: { contents: "Tratio Symbol" } });
  }
}

function validate(uri: string, src: string) {
  const diag = new Engine();
  const lexer = new Lexer(src, diag);
  const toks = lexer.lex();
  const parser = new Parser(toks, diag);
  const ast = parser.parse();
  
  const resolver = new Resolver(diag, process.cwd());
  resolver.resolve(ast, "main");
  
  const diagnostics = diag.messages.map(m => ({
    range: {
      start: { line: m.span.line - 1, character: m.span.col - 1 },
      end: { line: m.span.line - 1, character: m.span.col - 1 + (m.span.end - m.span.start) }
    },
    severity: 1,
    source: "tratio",
    message: m.text
  }));
  
  sendMessage({
    jsonrpc: "2.0",
    method: "textDocument/publishDiagnostics",
    params: { uri, diagnostics }
  });
}