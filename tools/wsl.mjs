import { spawn, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { connect, createServer } from 'node:net';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const self = fileURLToPath(import.meta.url);
const worker = resolve(dirname(self), 'wsl/worker.mjs');
const allowed = new Set(['FOOSIGNER', 'FOOSIGNPIPE', 'FOO_ARTIFACT_ROOT', 'FOO_OFFLINE']);

export function linux(path) {
  const absolute = resolve(path);
  if (process.platform !== 'win32') return absolute;
  const match = /^([A-Za-z]):[\\/](.*)$/.exec(absolute);
  if (!match) throw Error(`WSL requires a local Windows drive path: ${absolute}`);
  return `/mnt/${match[1].toLowerCase()}/${match[2].replaceAll('\\', '/')}`;
}

export function host(path, distro = process.env.FOOWSL || 'Ubuntu-22.04') {
  if (process.platform !== 'win32') return path;
  if (!/^[\w.-]+$/.test(distro) || !path.startsWith('/'))
    throw Error('WSL host paths require an absolute Linux path and valid distribution');
  return `\\\\wsl.localhost\\${distro}${path.replaceAll('/', '\\')}`;
}

export function run(operations, { distro = process.env.FOOWSL || 'Ubuntu-22.04' } = {}) {
  if (!Array.isArray(operations) || operations.length === 0)
    throw Error('A WSL job needs at least one operation');
  if (!/^[\w.-]+$/.test(distro)) throw Error(`Invalid WSL distribution: ${distro}`);
  const planned = operations.map(operation => {
    if (!operation || typeof operation.command !== 'string' || !operation.command ||
        !Array.isArray(operation.args) || operation.args.some(arg => typeof arg !== 'string'))
      throw Error('WSL operations require a command and string argument list');
    const env = { ...(process.env.FOO_ARTIFACT_ROOT
      ? { FOO_ARTIFACT_ROOT: process.env.FOO_ARTIFACT_ROOT } : {}), ...operation.env };
    if (Object.keys(env).some(name => !allowed.has(name)))
      throw Error('WSL operation requested an unapproved environment variable');
    if (operation.cwd !== undefined && typeof operation.cwd !== 'string' ||
        operation.input !== undefined && typeof operation.input !== 'string' ||
        operation.tools !== undefined && (!Array.isArray(operation.tools) ||
          operation.tools.some(tool => typeof tool !== 'string' || !tool)))
      throw Error('Invalid WSL operation input or tool inventory');
    const timeout = operation.timeoutMs ?? 600000;
    const limit = operation.maxOutputBytes ?? 8 * 1024 * 1024;
    if (!Number.isInteger(timeout) || timeout < 1 || timeout > 7200000 ||
        !Number.isInteger(limit) || limit < 1 || limit > 64 * 1024 * 1024)
      throw Error('Invalid WSL operation limits');
    const guest = { ...env };
    if (process.platform === 'win32' && guest.FOO_ARTIFACT_ROOT &&
        !guest.FOO_ARTIFACT_ROOT.startsWith('/'))
      guest.FOO_ARTIFACT_ROOT = linux(guest.FOO_ARTIFACT_ROOT);
    return { command: operation.command, args: operation.args,
      cwd: operation.cwd && process.platform === 'win32' && !operation.cwd.startsWith('/')
        ? linux(operation.cwd) : operation.cwd,
      env: guest, input: operation.input,
      tools: operation.tools ?? [], timeoutMs: timeout, maxOutputBytes: limit };
  });
  const session = process.env.FOO_WSL_SOCKET;
  const command = session ? process.execPath : process.platform === 'win32' ? 'wsl.exe' : process.execPath;
  const args = session ? [self, '--client'] : process.platform === 'win32'
    ? ['-d', distro, '--', 'node', linux(worker)] : [worker];
  const result = spawnSync(command, args, { input: JSON.stringify({ operations: planned, distro }),
    encoding: 'utf8', windowsHide: true,
    timeout: planned.reduce((sum, operation) => sum + operation.timeoutMs, 10000),
    maxBuffer: planned.reduce((sum, operation) => sum + operation.maxOutputBytes, 1024 * 1024) });
  if (result.error) throw result.error;
  if (result.status !== 0) throw Error(result.stderr?.trim() || `WSL gateway exited ${result.status}`);
  let response;
  try { response = JSON.parse(result.stdout); }
  catch { throw Error(`Invalid WSL gateway response: ${result.stdout?.slice(0, 200)}`); }
  if (response.error) throw Error(response.error);
  if (!Array.isArray(response.results) || response.results.length === 0)
    throw Error('WSL gateway returned no operation results');
  return response.results;
}

export async function session({ distro = process.env.FOOWSL || 'Ubuntu-22.04' } = {}) {
  if (process.env.FOO_WSL_SOCKET)
    return { socket: process.env.FOO_WSL_SOCKET, close: async () => {} };
  if (!/^[\w.-]+$/.test(distro)) throw Error(`Invalid WSL distribution: ${distro}`);
  const child = spawn(process.execPath, [self, '--serve', distro],
    { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
  let stderr = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-4096); });
  const socket = await new Promise((done, fail) => {
    let output = '';
    const timeout = setTimeout(() => fail(Error(`WSL session did not start: ${stderr}`)), 30000);
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => {
      output += chunk;
      const newline = output.indexOf('\n');
      if (newline < 0) return;
      clearTimeout(timeout);
      done(output.slice(0, newline).trim());
    });
    child.once('error', error => { clearTimeout(timeout); fail(error); });
    child.once('exit', code => { clearTimeout(timeout); fail(Error(`WSL session exited ${code}: ${stderr}`)); });
  }).catch(error => { child.kill(); throw error; });
  return { socket, close: async () => {
    if (child.exitCode !== null) return;
    child.kill();
    await new Promise(done => { child.once('exit', done); setTimeout(done, 5000).unref(); });
  } };
}

function serve(distro) {
  if (!/^[\w.-]+$/.test(distro)) throw Error(`Invalid WSL distribution: ${distro}`);
  const command = process.platform === 'win32' ? 'wsl.exe' : process.execPath;
  const args = process.platform === 'win32'
    ? ['-d', distro, '--', 'node', linux(worker), '--session'] : [worker, '--session'];
  const guest = spawn(command, args, { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
  let diagnostics = '';
  guest.stderr.setEncoding('utf8');
  guest.stderr.on('data', chunk => { diagnostics = (diagnostics + chunk).slice(-4096); });
  guest.on('error', error => { diagnostics = error.message; if (server.listening) server.close(); process.exitCode = 1; });
  const pending = [];
  let ready = false;
  let output = '';
  const server = createServer(socket => {
    let request = '';
    socket.setEncoding('utf8');
    socket.on('data', chunk => {
      request += chunk;
      if (!request.includes('\n')) return;
      try {
        const parsed = JSON.parse(request.slice(0, request.indexOf('\n')));
        if (parsed.distro !== distro) throw Error('WSL session distribution mismatch');
        pending.push(socket);
        guest.stdin.write(JSON.stringify(parsed) + '\n');
      } catch (error) { socket.end(JSON.stringify({ error: error.message }) + '\n'); }
      socket.removeAllListeners('data');
    });
  });
  guest.stdout.setEncoding('utf8');
  guest.stdout.on('data', chunk => {
    output += chunk;
    let newline;
    while ((newline = output.indexOf('\n')) >= 0) {
      const line = output.slice(0, newline);
      output = output.slice(newline + 1);
      if (!ready) {
        let handshake;
        try { handshake = JSON.parse(line); } catch {}
        if (handshake?.ready !== true) {
          console.error(`WSL worker did not start: ${line.slice(0, 200)}`);
          guest.kill();
          process.exitCode = 1;
          return;
        }
        ready = true;
        const pipe = process.platform === 'win32' ? `\\\\.\\pipe\\foo-wsl-${randomUUID()}` : null;
        server.listen(pipe ?? 0, pipe ? undefined : '127.0.0.1', () => {
          const address = pipe ?? `tcp://127.0.0.1:${server.address().port}`;
          process.stdout.write(address + '\n');
        });
      } else {
        const client = pending.shift();
        if (client) client.end(line + '\n');
      }
    }
  });
  guest.once('exit', code => {
    for (const socket of pending) socket.end(JSON.stringify({ error:
      `WSL worker exited ${code}: ${diagnostics}` }) + '\n');
    if (server.listening) server.close();
    process.exitCode = code || 1;
  });
  process.on('SIGTERM', () => { guest.stdin.end(); guest.kill(); if (server.listening) server.close(); });
}

function client() {
  const name = process.env.FOO_WSL_SOCKET;
  if (!name) throw Error('FOO_WSL_SOCKET is required for the WSL session client');
  const request = readFileSync(0, 'utf8');
  const address = name.startsWith('tcp://')
    ? { host: '127.0.0.1', port: Number(name.slice('tcp://127.0.0.1:'.length)) }
    : name;
  const socket = connect(address);
  socket.setEncoding('utf8');
  socket.on('connect', () => socket.write(request + '\n'));
  socket.on('data', chunk => process.stdout.write(chunk));
  socket.on('error', error => { console.error(error.message); process.exitCode = 1; });
}

export function checked(operations, options) {
  const results = run(operations, options);
  const failed = results.find(result => result.error || result.status !== 0);
  if (failed) throw Error(failed.error || failed.stderr.trim() || `WSL command exited ${failed.status}`);
  if (results.length !== operations.length) throw Error('WSL job stopped before all operations completed');
  return results;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv[2] === '--serve') { serve(process.argv[3] || process.env.FOOWSL || 'Ubuntu-22.04'); }
  else if (process.argv[2] === '--client') { client(); }
  else if (process.argv.includes('--exec')) {
    const index = process.argv.indexOf('--exec');
    const options = process.argv.slice(2, index);
    let distro = process.env.FOOWSL || 'Ubuntu-22.04';
    let cwd;
    for (let i = 0; i < options.length; i += 2) {
      if (options[i] === '--distro') distro = options[i + 1];
      else if (options[i] === '--cwd') cwd = options[i + 1];
      else throw Error(`Unknown WSL gateway option: ${options[i]}`);
    }
    const [command, ...args] = process.argv.slice(index + 1);
    const [result] = run([{ command, args, cwd }], { distro });
    process.stdout.write(result.stdout);
    process.stderr.write(result.stderr);
    if (result.error) console.error(result.error);
    process.exitCode = result.status ?? 1;
  }
  else {
  if (process.argv.includes('--help')) {
    console.log('Usage: node tools/wsl.mjs --json < operations.json | --exec COMMAND [ARGS...]');
    process.exit(0);
  }
  if (process.argv[2] === '--path' && process.argv.length === 4) {
    console.log(linux(process.argv[3]));
    process.exit(0);
  }
  if (process.argv[2] === '--host-path' && process.argv.length >= 4 && process.argv.length <= 5) {
    console.log(host(process.argv[3], process.argv[4]));
    process.exit(0);
  }
  if (process.argv.length !== 3 || !['--json', '--base64'].includes(process.argv[2]))
    throw Error('Use --json or --base64 with a request on stdin');
  const input = readFileSync(0, 'utf8');
  const request = JSON.parse(process.argv[2] === '--base64'
    ? Buffer.from(input.trim(), 'base64').toString('utf8') : input);
  const results = run(request.operations, { distro: request.distro });
  process.stdout.write(JSON.stringify({ results }) + '\n');
  if (results.length !== request.operations.length || results.some(result => result.error || result.status !== 0))
    process.exitCode = 1;
  }
}
