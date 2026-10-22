// Explicit Linux release gate. Run inside a network-disabled namespace/container.
import { value as option } from '../arguments.mjs';
import { readFileSync as read, mkdirSync as mkdir, writeFileSync as write } from 'node:fs';
import { resolve, join, dirname } from 'node:path';
import { fileURLToPath as filename } from 'node:url';
import * as artifacts from '../artifacts.mjs';
import { createHash as hasher } from 'node:crypto';
import { spawnSync as invoke } from 'node:child_process';
const root = resolve(dirname(filename(import.meta.url)), '../..');
const host = `linux-${process.arch}`;
const target = option('--target') || host;
const foreign = host === 'linux-x64' && target === 'linux-arm64';
if (process.platform !== 'linux' || !['linux-x64','linux-arm64'].includes(target) ||
    target !== host && !foreign) throw Error(`Cannot verify ${target} from ${host}`);
const qemu = process.env.FOO_QEMU_AARCH64;
if (foreign && !qemu) throw Error('FOO_QEMU_AARCH64 is required to execute the Linux ARM64 vendor probe');
const output = join(root,'.artifacts/vendor',target);
const work = artifacts.create('tools');
function run(command,args) {
 const r=invoke(command,args,{cwd:root,encoding:'utf8',env:{...process.env,FOO_OFFLINE:'1'}});
 if(r.status!==0) throw Error(r.error?.message || r.stderr || r.stdout);
 return r.stdout;
}
function archives() {
 return ['libsodium/lib/libsodium.a','zlib/lib/libz.a'].map(p=>hasher('sha256').update(read(join(output,p))).digest('hex'));
}
run(process.execPath,[join(root,'tools/vendor/audit.mjs')]);
const provenance=JSON.parse(read(join(output,'provenance.json')));
const lock=hasher('sha256').update(read(join(root,'vendor/manifest.json'))).digest('hex');
if(provenance.target!==target || provenance.vendorIdentity!==lock) throw Error('Stale or wrong-target provenance');
for(const [path,digest] of Object.entries(provenance.files)) {
 if(hasher('sha256').update(read(join(output,path))).digest('hex')!==digest) throw Error(`Artifact checksum mismatch: ${path}`);
}
const before=archives();
if(process.argv.includes('--rebuild')) {
 console.log(run(process.execPath,[join(root,'tools/vendor/build.mjs'),'--target',target,'--workdir',work]));
 if(JSON.stringify(before)!==JSON.stringify(archives())) throw Error('Static archives are not byte reproducible');
 console.log('Independent staging builds produced identical static archives.');
}
const binary=join(work,'probe');
mkdir(dirname(binary),{recursive:true});
console.log(run(foreign ? 'zig' : 'cc',[...(foreign ? ['cc','-target','aarch64-linux-gnu.2.27'] : []),'-O2',join(root,'test/native/c/vendor.c'),'-I'+join(output,'libsodium/include'),'-I'+join(output,'zlib/include'),join(output,'libsodium/lib/libsodium.a'),join(output,'zlib/lib/libz.a'),'-I'+join(root,'vendor/blake3/c'),...['blake3.c','blake3_dispatch.c','blake3_portable.c'].map(p=>join(root,'vendor/blake3/c',p)),'-DBLAKE3_NO_SSE2','-DBLAKE3_NO_SSE41','-DBLAKE3_NO_AVX2','-DBLAKE3_NO_AVX512','-DBLAKE3_USE_NEON=0','-pthread','-o',binary]));
console.log(run(foreign ? qemu : binary,foreign ? [binary] : []));
const imports=run('readelf',['-h','-d',binary]);
if (!imports.includes(target === 'linux-arm64' ? 'Machine:                           AArch64' : 'Machine:                           Advanced Micro Devices X86-64'))
 throw Error(`Wrong vendor probe architecture for ${target}`);
if(/NEEDED.*(?:libsodium|libz\.so)/.test(imports)) throw Error('Unexpected shared crypto/compression requirement');
write(binary+'.dependencies.json',JSON.stringify({format:'foo.runtime-requirements',version:1,target,vendorIdentity:lock,staticArchiveHashes:archives(),inspectionTool:'readelf',inspection:imports},null,2)+'\n');
console.log(imports);
