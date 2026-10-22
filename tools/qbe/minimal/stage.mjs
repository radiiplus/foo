import { createHash } from 'node:crypto';
import { copyFileSync, cpSync, existsSync, mkdirSync, readFileSync,
  readdirSync, statSync } from 'node:fs';
import { dirname, join, resolve, sep } from 'node:path';

function option(name) {
  const index = process.argv.indexOf(name);
  if (index < 0 || !process.argv[index + 1])
    throw Error(`${name} requires a directory`);
  return resolve(process.argv[index + 1]);
}

const source = option('--package');
const output = option('--output');
if (!existsSync(source) || existsSync(output) ||
    output.startsWith(source + sep) || source.startsWith(output + sep))
  throw Error('Source must exist and the output must be a new, separate directory');

const receipt = JSON.parse(readFileSync(join(source, 'toolchain/installed.json')));
if (receipt.format !== 'foo.toolchain.installation' ||
    receipt.target !== 'linux-x64' || !Array.isArray(receipt.assets) ||
    receipt.maximumUncompressedBytes !== 55_000_000)
  throw Error('Expected a Linux x64 toolchain installation receipt');

let recordedBytes = 0;
for (const asset of receipt.assets) {
  const input = resolve(source, asset.path);
  const destination = resolve(output, asset.path);
  if (!input.startsWith(source + sep) ||
      !destination.startsWith(output + sep))
    throw Error(`Unsafe asset path: ${asset.path}`);
  const content = readFileSync(input);
  if (content.length !== asset.bytes ||
      createHash('sha256').update(content).digest('hex') !== asset.sha256)
    throw Error(`Toolchain asset differs from receipt: ${asset.path}`);
  recordedBytes += content.length;
}
if (recordedBytes !== receipt.uncompressedBytes)
  throw Error('Toolchain receipt size differs from its assets');

mkdirSync(output, { recursive: true });
for (const asset of receipt.assets) {
  const destination = resolve(output, asset.path);
  mkdirSync(dirname(destination), { recursive: true });
  copyFileSync(resolve(source, asset.path), destination);
}
cpSync(join(source, 'lib'), join(output, 'lib'), { recursive: true });
for (const name of ['toolchain/assets.json', 'toolchain/installed.json',
    'bin/foo.dependencies.json', 'project.ivc', 'LICENSE', 'LICENSE-MIT',
    'LICENSE-APACHE']) {
  const destination = join(output, name);
  mkdirSync(dirname(destination), { recursive: true });
  copyFileSync(join(source, name), destination);
}

function bytes(directory) {
  let total = 0;
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isSymbolicLink()) throw Error(`Unexpected symlink: ${path}`);
    total += entry.isDirectory() ? bytes(path) : statSync(path).size;
  }
  return total;
}
const total = bytes(output);
if (total >= receipt.maximumUncompressedBytes)
  throw Error(`Minimal toolchain exceeds 55 MB: ${total} bytes`);
console.log(`Staged minimal Linux x64 toolchain: ${output} (${total} bytes)`);
