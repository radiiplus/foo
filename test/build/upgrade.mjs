import assert from 'node:assert/strict';
import { compare, installer, select } from '../../tools/upgrade.mjs';

assert.equal(compare('0.8.1', '0.8.1'), 0);
assert.equal(compare('0.8.2', '0.8.1'), 1);
assert.equal(compare('0.9.0', '0.8.99'), 1);
assert.equal(compare('0.8.0', '0.8.1'), -1);
assert.throws(() => compare('latest', '0.8.1'), /Unsupported FOO version/);
assert.equal(installer('win32', 'x64'), 'foo-windows-x64.exe');
assert.equal(installer('linux', 'arm64'), 'foo-arm64.deb');
assert.throws(() => installer('darwin', 'arm64'), /No FOO installer/);

const version = '0.9.0';
const name = 'foo-windows-x64.exe';
const valid = {
  tag_name: `foo-v${version}`,
  assets: [{ name, digest: `sha256:${'a'.repeat(64)}`,
    browser_download_url: `https://github.com/radiiplus/foo/releases/download/foo-v${version}/${name}` }],
};
assert.equal(select(valid, '0.8.1', 'win32', 'x64').sha256, 'a'.repeat(64));
assert.equal(select(valid, version, 'win32', 'x64').current, true);
assert.throws(() => select({ ...valid, assets: [] }, '0.8.1', 'win32', 'x64'), /verified/);
assert.throws(() => select({ ...valid, assets: [{ ...valid.assets[0], digest: null }] }, '0.8.1', 'win32', 'x64'), /verified/);
assert.throws(() => select({ ...valid, assets: [{ ...valid.assets[0], browser_download_url: 'https://example.com/file' }] }, '0.8.1', 'win32', 'x64'), /verified/);
console.log('FOO upgrade selection and verified package gates passed.');
