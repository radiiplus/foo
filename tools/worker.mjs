import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { existsSync, lstatSync, mkdirSync, unlinkSync, watch } from 'node:fs';
import { createServer, createConnection } from 'node:net';
import { homedir, tmpdir } from 'node:os';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(import.meta.url);
const repository = resolve(dirname(script), '..');
const key = createHash('sha256').update(homedir() + '\0' + repository).digest('hex').slice(0, 20);
const directory = join(tmpdir(), `foo-build-${key}`);
const endpoint = process.platform === 'win32' ? `\\\\.\\pipe\\foo-build-${key}` : join(directory, 'worker.sock');
const timeout = Number(process.env.FOO_BUILD_WORKER_IDLE_MS || 120000);
if (!Number.isInteger(timeout) || timeout < 1000 || timeout > 3600000)
  throw Error('FOO_BUILD_WORKER_IDLE_MS must be between 1000 and 3600000');

function connect() {
  return new Promise((done, fail) => {
    const socket = createConnection(endpoint);
    socket.once('connect', () => done(socket));
    socket.once('error', fail);
  });
}

function pause(milliseconds) {
  return new Promise(done => setTimeout(done, milliseconds));
}

export async function run(compiler, args, cwd, env = process.env) {
  let socket;
  try { socket = await connect(); }
  catch {
    const child = spawn(process.execPath, [script, '--serve'], {
      detached: true, stdio: 'ignore', windowsHide: true, env,
    });
    child.unref();
    for (let attempt = 0; attempt < 50; attempt++) {
      await pause(100);
      try { socket = await connect(); break; }
      catch { /* Another client may still be starting the same worker. */ }
    }
    if (!socket) throw Error('Shared FOO build worker did not start');
  }
  return new Promise((done, fail) => {
    let buffered = '';
    let completed = false;
    socket.setEncoding('utf8');
    socket.on('data', chunk => {
      buffered += chunk;
      if (buffered.length > 8 * 1024 * 1024) {
        socket.destroy(Error('Build worker response exceeded 8 MiB'));
        return;
      }
      let line;
      while ((line = buffered.indexOf('\n')) >= 0) {
        const message = JSON.parse(buffered.slice(0, line));
        buffered = buffered.slice(line + 1);
        if (message.stdout) process.stdout.write(Buffer.from(message.stdout, 'base64'));
        if (message.stderr) process.stderr.write(Buffer.from(message.stderr, 'base64'));
        if (Number.isInteger(message.exit)) {
          completed = true;
          done(message.exit);
          socket.end();
        }
      }
    });
    socket.once('error', fail);
    socket.once('close', () => { if (!completed) fail(Error('Shared FOO build worker disconnected')); });
    socket.write(JSON.stringify({ compiler, args, cwd, env }) + '\n');
  });
}

async function serve() {
  if (process.platform !== 'win32') {
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    if (lstatSync(directory).isSymbolicLink()) throw Error('Build worker directory is a link');
  }
  const queue = [];
  const watchers = new Map();
  let active;
  let timer;
  const server = createServer(socket => {
    reset();
    let buffered = '';
    let accepted = false;
    socket.setEncoding('utf8');
    socket.on('data', chunk => {
      buffered += chunk;
      if (buffered.length > 2 * 1024 * 1024) return socket.destroy();
      const line = buffered.indexOf('\n');
      if (line < 0 || accepted) return;
      accepted = true;
      let request;
      try { request = JSON.parse(buffered.slice(0, line)); }
      catch { return socket.destroy(); }
      if (!request || !['build', 'check'].includes(request.args?.[0]) ||
          !Array.isArray(request.args) || !request.args.every(item => typeof item === 'string') ||
          typeof request.compiler !== 'string' || typeof request.cwd !== 'string' ||
          !request.env || typeof request.env !== 'object') return socket.destroy();
      for (let index = queue.length - 1; index >= 0; index--)
        if (queue[index].prewarm && queue[index].cwd === request.cwd) queue.splice(index, 1);
      if (active?.prewarm && !active.canceling) {
        active.canceling = true;
        stop(active.child);
      }
      const background = queue.findIndex(item => item.prewarm);
      queue.splice(background < 0 ? queue.length : background, 0,
        { ...request, socket, prewarm: false });
      pump();
    });
    socket.on('close', () => {
      for (let index = queue.length - 1; index >= 0; index--)
        if (queue[index].socket === socket) queue.splice(index, 1);
      if (active?.socket === socket) stop(active.child);
    });
  });

  function reset() {
    clearTimeout(timer);
    timer = setTimeout(() => {
      if (active || queue.length) return reset();
      for (const pair of watchers.values()) for (const item of pair.handles) item.close();
      watchers.clear();
      server.close();
      if (process.platform !== 'win32' && existsSync(endpoint)) unlinkSync(endpoint);
    }, timeout);
  }

  function stop(child) {
    if (!child?.pid) return;
    if (process.platform === 'win32')
      spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore', windowsHide: true }).unref();
    else {
      try { process.kill(-child.pid, 'SIGTERM'); }
      catch { child.kill(); }
    }
  }

  function anticipate(job) {
    if (job.args[0] !== 'build' || watchers.has(job.cwd)) return;
    if (existsSync(join(job.cwd, 'project.ivc'))) return;
    const entry = job.args.find(arg => arg.toLowerCase().endsWith('.iv'));
    const source = entry ? dirname(entry) : '.';
    const folder = resolve(job.cwd, source);
    const path = relative(job.cwd, folder);
    if (path === '..' || path.startsWith('..' + sep) || isAbsolute(path)) return;
    const handles = [];
    const schedule = () => {
      const state = watchers.get(job.cwd);
      if (!state) return;
      clearTimeout(state.debounce);
      state.debounce = setTimeout(() => {
        if (queue.some(item => item.cwd === job.cwd) || active?.cwd === job.cwd) {
          state.dirty = true;
          return;
        }
        state.dirty = false;
        if (existsSync(join(job.cwd, 'project.ivc'))) return;
        queue.push({ ...state.job, prewarm: true, socket: null });
        pump();
      }, 350);
    };
    try {
      if (existsSync(folder)) handles.push(watch(folder, { recursive: true }, (_, file) => {
        if (!file || /\.(?:iv|c|cpp|h)$/.test(String(file)) ||
            (folder === job.cwd && String(file) === 'project.ivc')) schedule();
      }));
      if (folder !== job.cwd)
        handles.push(watch(job.cwd, (_, file) => { if (String(file) === 'project.ivc') schedule(); }));
      for (const item of handles) item.on('error', () => {
        for (const handle of handles) handle.close();
        watchers.delete(job.cwd);
      });
      watchers.set(job.cwd, { handles, job, debounce: null, dirty: false, schedule });
    } catch {
      for (const item of handles) item.close();
    }
  }

  function pump() {
    if (active || !queue.length) return;
    const job = queue.shift();
    const env = { ...job.env, FOO_BUILD_JOBS: String(Math.min(2,
      Math.max(1, Number(job.env.FOO_BUILD_JOBS) || 2))) };
    const child = spawn(job.compiler, job.args, {
      cwd: job.cwd, env, windowsHide: true, detached: process.platform !== 'win32',
      stdio: ['inherit', 'pipe', 'pipe'],
    });
    active = { ...job, child };
    const forward = (stream, name) => stream.on('data', chunk => {
      if (job.socket && !job.socket.destroyed)
        job.socket.write(JSON.stringify({ [name]: chunk.toString('base64') }) + '\n');
    });
    forward(child.stdout, 'stdout');
    forward(child.stderr, 'stderr');
    child.once('error', error => {
      if (job.socket && !job.socket.destroyed)
        job.socket.write(JSON.stringify({ stderr: Buffer.from(error.message + '\n').toString('base64') }) + '\n');
    });
    child.once('close', code => {
      if (code === 0 && !job.prewarm) {
        const state = watchers.get(job.cwd);
        if (state) state.job = { ...job, socket: null };
        else anticipate(job);
      }
      if (job.socket && !job.socket.destroyed)
        job.socket.end(JSON.stringify({ exit: code ?? 1 }) + '\n');
      active = null;
      const state = watchers.get(job.cwd);
      if (state?.dirty) {
        state.dirty = false;
        state.schedule();
      }
      reset();
      pump();
    });
  }

  try {
    await new Promise((done, fail) => {
      server.once('error', fail);
      server.listen(endpoint, done);
    });
  } catch (error) {
    if (error.code !== 'EADDRINUSE') throw error;
    if (process.platform === 'win32') return;
    try { const socket = await connect(); socket.end(); return; }
    catch {
      if (existsSync(endpoint) && !lstatSync(endpoint).isSymbolicLink()) unlinkSync(endpoint);
      await new Promise((done, fail) => {
        server.once('error', fail);
        server.listen(endpoint, done);
      });
    }
  }
  reset();
}

if (process.argv[1] && resolve(process.argv[1]) === script && process.argv[2] === '--serve')
  await serve();
