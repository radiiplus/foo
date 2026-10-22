// Inspect a release binary without executing it or fetching its dependencies.
import { writeFileSync as write } from 'node:fs';
import { resolve } from 'node:path';
import { spawnSync as invoke } from 'node:child_process';
import { find as locate } from '../host/windows.mjs';
const artifact=resolve(process.argv[2] || '');
if(!process.argv[2]) throw Error('Usage: node tools/runtime/audit.mjs BINARY');
const windows=process.platform==='win32';
const macos=process.platform==='darwin';
const tool=windows?locate('dumpbin.exe', process.env.FOO_BINARY_INSPECTOR):macos?'otool':'readelf';
const args=windows?['/headers','/imports',artifact]:macos?['-hv','-L',artifact]:['-h','-d',artifact];
const result=invoke(tool,args,{encoding:'utf8',windowsHide:true});
if(result.status!==0) throw Error(`Missing inspector or invalid binary: ${tool}: ${result.error?.message || result.stderr}`);
write(artifact+'.dependencies.json',JSON.stringify({format:'foo.runtime-requirements',version:1,artifact,platform:process.platform,inspectionTool:tool,inspection:result.stdout,optionalRuntimeProviders:['OpenSSL for explicit network/package operations on non-Windows; target OS provider, not bundled'],sdkPolicy:'Target toolchain libc/platform SDK; never downloaded during builds'},null,2)+'\n');
console.log(`Recorded executable dependencies: ${artifact}.dependencies.json`);
