import { mkdirSync, mkdtempSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as artifacts from '../tools/artifacts.mjs';

export function output() {
  const directory = process.env.FOO_TEST_ARTIFACT_DIR
    ? resolve(process.env.FOO_TEST_ARTIFACT_DIR) : artifacts.create('test');
  mkdirSync(directory, { recursive: true });
  return directory;
}

export function environment(directory, inherited = process.env) {
  const selected = resolve(directory);
  const temp = join(selected, 'temp');
  mkdirSync(temp, { recursive: true });
  return { ...inherited, FOO_TEST_ARTIFACT_DIR: selected,
    TEMP: temp, TMP: temp, TMPDIR: temp };
}

export function temporary() {
  return process.env.FOO_TEST_ARTIFACT_DIR
    ? mkdtempSync(join(output(), 'run-')) : artifacts.create('test');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url))
  console.log(temporary());
