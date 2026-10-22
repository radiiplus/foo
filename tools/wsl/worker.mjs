import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const allowed = new Set(['FOOSIGNER', 'FOOSIGNPIPE', 'FOO_ARTIFACT_ROOT', 'FOO_OFFLINE']);

function execute(input) {
  const results = [];
  for (const operation of input.operations) {
    const environment = { ...process.env };
    for (const [name, value] of Object.entries(operation.env ?? {})) {
      if (!allowed.has(name) || typeof value !== 'string')
        throw Error(`WSL environment variable is not allowed: ${name}`);
      environment[name] = value;
    }
    const required = new Set([operation.command, ...(operation.tools ?? [])]);
    for (const tool of required) {
      if (tool.includes('/')) continue;
      const found = spawnSync('sh', ['-c', 'command -v "$1" >/dev/null', 'sh', tool],
        { encoding: 'utf8', timeout: 10000 });
      if (found.status !== 0) throw Error(`Required WSL tool is missing: ${tool}`);
    }
    const result = spawnSync(operation.command, operation.args, {
      cwd: operation.cwd,
      env: environment,
      input: operation.input,
      encoding: 'utf8',
      timeout: operation.timeoutMs,
      maxBuffer: operation.maxOutputBytes,
    });
    results.push({ status: result.status, signal: result.signal,
      error: result.error?.message ?? '', stdout: result.stdout ?? '', stderr: result.stderr ?? '' });
    if (result.error || result.status !== 0) break;
  }
  return { results };
}

if (process.argv.includes('--session')) {
  process.stdout.write('{"ready":true}\n');
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const line of lines) {
    try { process.stdout.write(JSON.stringify(execute(JSON.parse(line))) + '\n'); }
    catch (error) { process.stdout.write(JSON.stringify({ error: error.message }) + '\n'); }
  }
} else {
  process.stdout.write(JSON.stringify(execute(JSON.parse(readFileSync(0, 'utf8')))) + '\n');
}
