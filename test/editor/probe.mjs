import assert from 'node:assert/strict';
import { cpSync as copy, mkdtempSync as scratch, readFileSync as read, writeFileSync as write, rmSync as remove } from 'node:fs';
import { temporary as tmpdir } from "../location.mjs";
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath as filename } from 'node:url';
import { spawnSync as invoke } from 'node:child_process';
const root = resolve(dirname(filename(import.meta.url)), '../../editors/textmate');
const directory = scratch(join(tmpdir(), 'foo-snapshots-'));
try {
  copy(resolve(root, '../../test/editor/cases'), directory, { recursive: true });
  const file = join(directory, 'declarations.json');
  const snapshot = JSON.parse(read(file, 'utf8'));
  snapshot[0].tokens[0][2] += ' invalid.illegal.foo';
  write(file, JSON.stringify(snapshot));
  const result = invoke(process.execPath, [resolve(root, '../../test/editor/snapshots.mjs'), `--cases=${directory}`], { encoding: 'utf8', timeout: 30000 });
  assert.equal(result.status, 1, `Broken assertion should fail: ${result.stderr}`);
  assert.match(result.stderr, /scope snapshot mismatch/);
  console.log('Confirmed a corrupted scope assertion causes a failing test exit.');
} finally {
  // Only the exact directory returned by mkdtemp above is removed.
  remove(directory, { recursive: true, force: true });
}
