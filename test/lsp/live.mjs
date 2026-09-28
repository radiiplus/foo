import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { resolve } from 'node:path';

const executable = process.env.FOO_BIN || resolve(
  '.artifacts/native', process.platform === 'win32' ? 'foo.exe' : 'foo');
const server = spawn(executable, ['lsp'], { stdio: ['pipe', 'pipe', 'pipe'] });
let buffer = Buffer.alloc(0);
let initialized = false;
let validated = false;

function send(message) {
  const content = JSON.stringify({ jsonrpc: '2.0', ...message });
  server.stdin.write(`Content-Length: ${Buffer.byteLength(content)}\r\n\r\n${content}`);
}

const completed = new Promise((finish, reject) => {
  const timeout = setTimeout(() => reject(Error('Timed out waiting for a live LSP response')), 5000);
  server.on('error', reject);
  server.stderr.on('data', chunk => process.stderr.write(chunk));
  server.stdout.on('data', chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    while (true) {
      const marker = buffer.indexOf('\r\n\r\n');
      if (marker < 0) return;
      const header = buffer.subarray(0, marker).toString('ascii');
      const match = header.match(/content-length\s*:\s*(\d+)/i);
      assert(match, 'LSP response needs a Content-Length header');
      const length = Number(match[1]);
      const start = marker + 4;
      if (buffer.length < start + length) return;
      const message = JSON.parse(buffer.subarray(start, start + length).toString('utf8'));
      buffer = buffer.subarray(start + length);
      if (!initialized && message.id === 1) {
        initialized = true;
        send({ method: 'textDocument/didOpen', params: { textDocument: {
          uri: 'file:///live.iv', languageId: 'foo', version: 1,
          text: [
            'function greet name text punctuation text default "!" giving text {',
            '  give name plus punctuation.',
            '}',
            'constant messages are greet "FOO".',
            'dynamic count is 0.',
            'increase count by 1.',
          ].join('\n'),
        } } });
      } else if (initialized && message.method === 'textDocument/publishDiagnostics') {
        if (!validated) {
          assert.equal(message.params.diagnostics.length, 0, 'Current sentence syntax should be valid in the live editor');
          validated = true;
          send({ method: 'textDocument/didChange', params: {
            textDocument: { uri: 'file:///live.iv', version: 2 },
            contentChanges: [{ text: 'constant answer is .' }],
          } });
          continue;
        }
        assert(message.params.diagnostics.length > 0, 'Invalid source should publish a diagnostic');
        clearTimeout(timeout);
        finish();
      }
    }
  });
});

send({ id: 1, method: 'initialize', params: { rootUri: null, capabilities: {} } });
try {
  await completed;
  console.log('live LSP streaming: ok');
} finally {
  server.kill();
}
