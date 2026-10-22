// Coverage retirement is evidence-checked.
import { readFileSync as read } from 'node:fs';
import { spawnSync as invoke } from 'node:child_process';
import { createHash as hasher } from 'node:crypto';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath as filename } from 'node:url';
import { auditWsl } from './wsl.mjs';
export const categories=['language semantics','compiler frontend/type checker','QBE IR','runtime/service','cross-target','package/CLI','release/signing','documentation/editor/registry','failure injection/crash behavior','benchmarks'];
const root=resolve(dirname(filename(import.meta.url)),'../..');
const extensions=/\.(?:nim|iv|ivc|ivl|cap|mjs|ps1|py|sh|c|h|cpp|zig|rs|yml|yaml|json|cjs|golden|ld|ir|txt|md)$/;
export function selection(source){
 if(!/\bqbe\.build\s*\(/.test(source))throw Error('QBE selection must invoke the QBE implementation');
 if([...source.matchAll(/\b([a-z]+)\.build\s*\(/g)].some(match => match[1] !== 'qbe'))
  throw Error('Unexpected backend build remains in project routing');
}
export function audit(){
 auditWsl();
 selection(read(join(root,'src/build/project.nim'),'utf8'));
 const lock=JSON.parse(read(join(root,'test/inventory.json')));
 if(lock.format!=='foo.test-inventory'||lock.version!==1||lock.hashEncoding!=='utf8-lf')throw Error('Invalid test inventory');
 const listing=invoke('rg',['--files','--no-ignore-parent','test','benchmark','tools','.github','bin','installers'],{cwd:root,encoding:'utf8',windowsHide:true});
 if(listing.status!==0)throw Error(listing.stderr||'Inventory file discovery failed');
 const actual=listing.stdout.trim().split(/\r?\n/).map(p=>p.replaceAll('\\','/')).filter(p=>extensions.test(p)&&p!=='test/inventory.json').sort();
 const expected=lock.entries.map(e=>e.path).sort();
 if(new Set(expected).size!==expected.length||JSON.stringify(actual)!==JSON.stringify(expected))throw Error('Stale inventory: run python test/support/inventory.py and review changes');
 if(JSON.stringify(lock.testBackendPolicy?.active)!=='[\"qbe\"]')throw Error('Active test backend must be QBE');
 if(lock.defaultPromotion?.backend!=='qbe')throw Error('Default promotion backend must be QBE');
 for(const e of lock.entries){
  if(!categories.includes(e.category)||!e.tags.every(t=>categories.includes(t)))throw Error(`Unknown category: ${e.path}`);
  const hash=hasher('sha256').update(read(join(root,e.path),'utf8').replaceAll('\r\n','\n')).digest('hex');
  if(hash!==e.sha256)throw Error(`Stale inventory hash: ${e.path}`);
 }
 return {entries:lock.entries.length,categories:Object.fromEntries(categories.map(c=>[c,lock.entries.filter(e=>e.tags.includes(c)).length]))};
}
if(process.argv[1]&&resolve(process.argv[1])===filename(import.meta.url))console.log(JSON.stringify(audit(),null,2));
