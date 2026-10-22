import assert from 'node:assert/strict';
import { readFileSync as read } from 'node:fs';
import { selection } from './support/audit.mjs';

selection(read(new URL('../src/build/project.nim', import.meta.url), 'utf8'));
assert.throws(() => selection('let result = other.build(module)'), /QBE implementation/);
assert.throws(() => selection('let result = qbe.build(module)\nlet fallback = other.build(module)'),
  /Unexpected backend build/);
console.log('QBE routing policy: passed');
