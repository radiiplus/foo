const vscode = require('vscode');
const { spawn } = require('child_process');

const selector = [{ language: 'foo', scheme: 'file' }, { language: 'foo', scheme: 'untitled' }];

function fooCommand() {
  return process.env.FOO_SERVER_PATH ||
    vscode.workspace.getConfiguration('foo').get('server.path', 'foo');
}

function asRange(value) {
  return new vscode.Range(
    value.start.line, value.start.character,
    value.end.line, value.end.character,
  );
}

class FooLanguageClient {
  constructor(diagnostics, output) {
    this.diagnostics = diagnostics;
    this.output = output;
    this.nextId = 0;
    this.pending = new Map();
    this.buffer = Buffer.alloc(0);
    this.ready = false;
    this.stopping = false;
  }

  start() {
    if (this.process) return;
    this.stopping = false;
    const command = fooCommand();
    const workspace = vscode.workspace.workspaceFolders?.[0];
    const active = vscode.window.activeTextEditor?.document;
    const cwd = workspace?.uri.fsPath || (active?.uri.scheme === 'file' ? require('path').dirname(active.uri.fsPath) : undefined);
    this.output.appendLine(`Starting ${command} lsp`);
    const child = spawn(command, ['lsp'], { cwd, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    this.process = child;
    child.stdout.on('data', chunk => this.receive(chunk));
    child.stderr.on('data', chunk => this.output.append(chunk.toString()));
    child.on('error', error => this.fail(`Unable to start FOO language server: ${error.message}`));
    child.on('close', code => {
      if (this.process !== child) return;
      if (!this.stopping) this.fail(`FOO language server stopped with exit code ${code}.`);
      this.process = undefined;
      this.ready = false;
    });

    const rootUri = workspace?.uri.toString() || null;
    this.request('initialize', {
      processId: process.pid,
      rootUri,
      capabilities: {},
      clientInfo: { name: 'foo.iv', version: '2.6.2' },
    }).then(() => {
      if (this.process !== child) return;
      this.ready = true;
      this.notify('initialized', {});
      this.output.appendLine('FOO language server ready.');
      for (const document of vscode.workspace.textDocuments) this.open(document);
    }).catch(error => this.fail(`FOO language server initialization failed: ${error.message}`));
  }

  stop() {
    this.stopping = true;
    this.ready = false;
    if (this.process) {
      this.process.kill();
      this.process = undefined;
    }
    for (const { reject } of this.pending.values()) reject(new Error('FOO language server stopped'));
    this.pending.clear();
    this.buffer = Buffer.alloc(0);
    this.diagnostics.clear();
  }

  restart() {
    this.stop();
    this.stopping = false;
    this.start();
  }

  fail(message) {
    this.output.appendLine(message);
    vscode.window.setStatusBarMessage(message, 5000);
  }

  send(message) {
    if (!this.process?.stdin?.writable) return false;
    const content = JSON.stringify({ jsonrpc: '2.0', ...message });
    this.process.stdin.write(`Content-Length: ${Buffer.byteLength(content)}\r\n\r\n${content}`);
    return true;
  }

  request(method, params) {
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      if (!this.send({ id, method, params })) {
        this.pending.delete(id);
        reject(new Error('FOO language server is not running'));
      }
    });
  }

  notify(method, params) {
    this.send({ method, params });
  }

  receive(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (true) {
      const marker = this.buffer.indexOf('\r\n\r\n');
      if (marker < 0) return;
      const header = this.buffer.subarray(0, marker).toString('ascii');
      const match = header.match(/content-length\s*:\s*(\d+)/i);
      if (!match) {
        this.fail('FOO language server sent an invalid response header.');
        this.buffer = Buffer.alloc(0);
        return;
      }
      const length = Number(match[1]);
      const start = marker + 4;
      if (this.buffer.length < start + length) return;
      const content = this.buffer.subarray(start, start + length).toString('utf8');
      this.buffer = this.buffer.subarray(start + length);
      try {
        this.handle(JSON.parse(content));
      } catch (error) {
        this.fail(`FOO language server response failed: ${error.message}`);
      }
    }
  }

  handle(message) {
    if (Object.prototype.hasOwnProperty.call(message, 'id')) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message));
      else pending.resolve(message.result);
      return;
    }
    if (message.method !== 'textDocument/publishDiagnostics') return;
    const uri = vscode.Uri.parse(message.params.uri);
    const diagnostics = (message.params.diagnostics || []).map(item => {
      const severity = item.severity === 2 ? vscode.DiagnosticSeverity.Warning
        : item.severity === 3 ? vscode.DiagnosticSeverity.Information
          : item.severity === 4 ? vscode.DiagnosticSeverity.Hint
            : vscode.DiagnosticSeverity.Error;
      const diagnostic = new vscode.Diagnostic(asRange(item.range), item.message, severity);
      diagnostic.source = item.source || 'foo';
      if (item.code !== undefined) diagnostic.code = item.code;
      return diagnostic;
    });
    this.diagnostics.set(uri, diagnostics);
  }

  open(document) {
    if (!this.ready || document.languageId !== 'foo') return;
    this.notify('textDocument/didOpen', { textDocument: {
      uri: document.uri.toString(), languageId: 'foo',
      version: document.version, text: document.getText(),
    } });
  }

  change(event) {
    if (!this.ready || event.document.languageId !== 'foo') return;
    this.notify('textDocument/didChange', {
      textDocument: { uri: event.document.uri.toString(), version: event.document.version },
      contentChanges: [{ text: event.document.getText() }],
    });
  }

  close(document) {
    if (!this.ready || document.languageId !== 'foo') return;
    this.notify('textDocument/didClose', { textDocument: { uri: document.uri.toString() } });
    this.diagnostics.delete(document.uri);
  }
}

function activate(context) {
  const diagnostics = vscode.languages.createDiagnosticCollection('foo');
  const output = vscode.window.createOutputChannel('FOO');
  const client = new FooLanguageClient(diagnostics, output);
  context.subscriptions.push(diagnostics, output, { dispose: () => client.stop() });

  if (vscode.workspace.getConfiguration('foo').get('server.enabled', true)) client.start();
  context.subscriptions.push(
    vscode.workspace.onDidOpenTextDocument(document => client.open(document)),
    vscode.workspace.onDidChangeTextDocument(event => client.change(event)),
    vscode.workspace.onDidCloseTextDocument(document => client.close(document)),
    vscode.workspace.onDidChangeConfiguration(event => {
      if (!event.affectsConfiguration('foo.server')) return;
      if (vscode.workspace.getConfiguration('foo').get('server.enabled', true)) client.restart();
      else client.stop();
    }),
    vscode.commands.registerCommand('foo.restartLanguageServer', () => client.restart()),
    vscode.commands.registerCommand('foo.startWatch', () => {
      const workspace = vscode.workspace.workspaceFolders?.[0];
      const terminal = vscode.window.createTerminal({
        name: 'FOO Watch', cwd: workspace?.uri.fsPath,
        shellPath: fooCommand(), shellArgs: ['watch'],
      });
      terminal.show();
    }),
    vscode.languages.registerDefinitionProvider(selector, {
      async provideDefinition(document, position) {
        if (!client.ready) return null;
        const result = await client.request('textDocument/definition', {
          textDocument: { uri: document.uri.toString() }, position,
        });
        return result ? new vscode.Location(vscode.Uri.parse(result.uri), asRange(result.range)) : null;
      },
    }),
    vscode.languages.registerHoverProvider(selector, {
      async provideHover(document, position) {
        if (!client.ready) return null;
        const result = await client.request('textDocument/hover', {
          textDocument: { uri: document.uri.toString() }, position,
        });
        if (!result) return null;
        const value = typeof result.contents === 'string' ? result.contents : result.contents.value;
        return new vscode.Hover(value, result.range ? asRange(result.range) : undefined);
      },
    }),
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
