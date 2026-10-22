import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { temporary } from '../location.mjs';
import { root } from '../regions.mjs';

const output = temporary();
const binary = join(output, process.platform === 'win32' ? 'tcp.exe' : 'tcp');
const compiler = process.env.FOO_CC || (process.platform === 'win32' ? 'clang' : 'cc');
const libraries = process.platform === 'win32'
  ? ['-lws2_32', '-ldnsapi', '-liphlpapi', '-ladvapi32', '-luser32']
  : ['-pthread', '-lresolv', '-ldl', '-lm'];
const args = ['-std=c11', '-O0', '-UNDEBUG', '-DFOO_SERVICE_TEST_MAIN=1',
  '-DFOO_SERVICE_TEST_NETWORK_ONLY=1', '-I', join(root, 'src/runtime/provider'),
  join(root, 'test/native/c/service.c'), join(root, 'src/runtime/provider/hosted.c'),
  ...libraries, '-o', binary];
const build = spawnSync(compiler, args, { cwd: root, encoding: 'utf8',
  windowsHide: true, timeout: 120000, maxBuffer: 4 * 1024 * 1024 });
writeFileSync(join(output, 'build.stdout'), build.stdout || '');
writeFileSync(join(output, 'build.stderr'), build.stderr || '');
assert.equal(build.status, 0, build.error?.message || build.stderr || 'TCP build failed');
const run = spawnSync(binary, [], { cwd: output, encoding: 'utf8', windowsHide: true,
  timeout: 30000, maxBuffer: 4 * 1024 * 1024 });
writeFileSync(join(output, 'run.stdout'), run.stdout || '');
writeFileSync(join(output, 'run.stderr'), run.stderr || '');
assert.equal(run.status, 0, run.error?.message || run.stderr || 'TCP check failed');
assert.match(run.stdout, /native service parity: ok/);
console.log('TCP hosted bytes, errors and cleanup: passed');
