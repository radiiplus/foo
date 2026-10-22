// Explicit build-time C frontend for the real dynamic-library ABI fixture.
import {spawnSync} from 'node:child_process';
import {mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {createHash} from 'node:crypto';
import {temporary} from '../location.mjs';
const output=resolve(process.argv.find(a=>a.startsWith('--output='))?.slice(9)||temporary());
mkdirSync(output,{recursive:true});
const compiler=process.env.FOO_QBE_TCC||
  (process.platform==='win32'?'tcc.exe':'cc');
function run(args){const r=spawnSync(compiler,args,{encoding:'utf8',windowsHide:true});if(r.error||r.status!==0)throw Error(r.error?.message||r.stderr||`C fixture frontend failed: ${r.status}`);return r;}
const version=run(['--version']).stdout;
const source=join(output,'increment.c');
const artifact=join(output,process.platform==='win32'?'increment.dll':'increment.so');
writeFileSync(source,'#include <stdint.h>\n#ifdef _WIN32\n__declspec(dllexport)\n#endif\nuint64_t increment(uint64_t value) { return value + 1; }\n');
const flags=['-std=c11','-shared',...(process.platform==='win32'?[]:['-fPIC']),source,'-o',artifact];
const built=run(flags);
writeFileSync(join(output,'build.stdout'),built.stdout);writeFileSync(join(output,'build.stderr'),built.stderr);
const hash=p=>createHash('sha256').update(readFileSync(p)).digest('hex');
writeFileSync(join(output,'report.json'),JSON.stringify({format:'foo.dynamic-library-fixture.v1',complete:true,passed:true,compilerRole:'foreign-call C fixture',compiler,version,flags,source,sourceSha256:hash(source),artifact,artifactSha256:hash(artifact)},null,2)+'\n');
console.log(`Prepared real dynamic-library fixture: ${artifact}`);
