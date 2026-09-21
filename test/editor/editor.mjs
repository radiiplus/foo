import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { downloadAndUnzipVSCode } from '@vscode/test-electron';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../editors/textmate');
const cache = resolve(root, '../../.artifacts/editor');
mkdirSync(cache, { recursive: true });
const session = mkdtempSync(join(cache, 'host-'));
const evidence = join(cache, 'evidence');
mkdirSync(evidence, { recursive: true });
const report = join(session, 'report.json');
const release = join(session, 'release');
const profile = join(session, 'profile');
const theme = process.env.FOO_THEME || 'Default Dark Modern';
mkdirSync(join(profile, 'User'), { recursive: true });
// These preferences apply only to the isolated test profile.
writeFileSync(join(profile, 'User/settings.json'), JSON.stringify({ 'workbench.colorTheme': theme, 'workbench.iconTheme': 'vs-seti', 'workbench.startupEditor': 'none', 'window.commandCenter': false, 'editor.minimap.enabled': false, 'editor.fontSize': 16, 'editor.tabSize': 2, 'editor.insertSpaces': true, 'telemetry.telemetryLevel': 'off', 'window.titleBarStyle': 'custom', 'update.mode': 'none' }));
const server = createServer();
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const port = server.address().port;
await new Promise(resolve => server.close(resolve));
const executable = process.env.FOO_EDITOR || await downloadAndUnzipVSCode({ version: '1.96.4', cachePath: join(cache, 'download') });
const env = { ...process.env, FOO_REPORT: report, FOO_RELEASE: release };
delete env.ELECTRON_RUN_AS_NODE;
const child = spawn(executable, [resolve(root, '../../test/editor/cases'), `--extensionDevelopmentPath=${root}`, `--extensionTestsPath=${resolve(root, '../../test/editor/host.cjs')}`, `--user-data-dir=${profile}`, `--extensions-dir=${join(session, 'extensions')}`, `--remote-debugging-port=${port}`, '--remote-debugging-address=127.0.0.1', '--disable-extensions', '--disable-workspace-trust', '--skip-welcome', '--skip-release-notes', '--no-sandbox', '--new-window'], { env, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
let output = '', ended = false;
child.stdout.on('data', chunk => { output += chunk; });
child.stderr.on('data', chunk => { output += chunk; });
const completion = new Promise(resolve => { child.on('exit', code => { ended = true; resolve(code); }); child.on('error', error => { ended = true; output += error.stack; resolve(-1); }); });
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function connect() {
  const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page = pages.find(page => page.type === 'page' && page.url.includes('workbench'));
  assert(page, 'VS Code workbench debug page not found');
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, { once: true }); socket.addEventListener('error', reject, { once: true }); });
  let id = 0;
  const pending = new Map();
  socket.addEventListener('message', event => { const message = JSON.parse(event.data); const task = pending.get(message.id); if (task) { pending.delete(message.id); message.error ? task.reject(Error(message.error.message)) : task.resolve(message.result); } });
  return { socket, call(method, params = {}) { return new Promise((resolve, reject) => { const key = ++id; pending.set(key, { resolve, reject }); socket.send(JSON.stringify({ id: key, method, params })); }); } };
}
try {
  const deadline = Date.now() + 120000;
  while (!existsSync(report) && !ended && Date.now() < deadline) await pause(250);
  assert(existsSync(report), `Editor tests did not report completion. ${output.slice(-5000)}`);
  const result = JSON.parse(readFileSync(report, 'utf8'));
  writeFileSync(join(evidence, 'host.json'), JSON.stringify(result, null, 2));
  assert(result.success, result.error);
  const client = await connect();
  try {
    await client.call('Runtime.enable');
    await client.call('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
    await client.call('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
    await pause(750);
    const visual = await client.call('Runtime.evaluate', { expression: `JSON.stringify({lines: [...document.querySelectorAll('.view-line')].map(line => ({text:line.textContent, spans:[...line.querySelectorAll('span')].filter(span=>!span.children.length).map(span=>({text:span.textContent,color:getComputedStyle(span).color}))})), icons:[...document.querySelectorAll('.foo-lang-file-icon')].map(icon=>({label:icon.textContent,image:getComputedStyle(icon,'::before').backgroundImage,visible:!!icon.getClientRects().length,place:icon.closest('.tab')?'tab':icon.closest('.monaco-list-row')?'explorer':'other'}))})`, returnByValue: true });
    const details = JSON.parse(visual.result.value);
    writeFileSync(join(evidence, 'visual.json'), JSON.stringify(details, null, 2));
    const declaration = details.lines.find(line => line.text.includes('data') && line.text.includes('pointer'));
    assert(declaration, 'Pointer declaration not visible');
    const colors = text => declaration.spans.find(span => span.text.replace(/\u00a0/g, ' ').trim() === text)?.color;
    for (const word of ['of', 'type', 'pointer', 'to', 'byte']) assert(colors(word), `Missing color evidence for ${word}`);
    assert.equal(colors('of'), colors('to'), 'Linking words should share their operator color');
    assert.equal(colors('type'), colors('pointer'), 'Type annotation and modifier should share their storage color');
    assert.equal(new Set(['of', 'pointer', 'byte'].map(colors)).size, 3, 'Linking words, modifiers, and primitive types need three distinct colors');
    const foreground = await client.call('Runtime.evaluate', { expression: "getComputedStyle(document.querySelector('.monaco-editor')).color", returnByValue: true });
    assert.notEqual(colors('of'), foreground.result.value, 'Linking words should have a color, not the neutral foreground');
    assert.notEqual(colors('byte'), colors('pointer'), 'Primitive type must differ from pointer modifier');
    {
      for (const [word, color] of [['of', 'rgb(255, 60, 172)'], ['type', 'rgb(255, 210, 63)'], ['pointer', 'rgb(255, 210, 63)'], ['to', 'rgb(255, 60, 172)'], ['byte', 'rgb(57, 255, 136)']]) assert.equal(colors(word), color, `Ultraviolet color for ${word}`);
    }
    for (const place of ['explorer', 'tab']) assert(details.icons.some(icon => icon.place === place && icon.visible && icon.image.includes('.svg')), `Missing language SVG in ${place}`);
    const screenshot = await client.call('Page.captureScreenshot', { format: 'png' });
    writeFileSync(join(evidence, 'highlight.png'), Buffer.from(screenshot.data, 'base64'));
  } finally { client.socket.close(); }
  console.log(`VS Code ${result.version}: ${result.checks.length} editor checks, differentiated colors, and visible file icons passed.`);
} finally {
  writeFileSync(release, 'done');
  const finished = await Promise.race([completion, pause(10000).then(() => 'timeout')]);
  if (finished === 'timeout') child.kill();
  writeFileSync(join(evidence, 'editor.log'), output);
}
