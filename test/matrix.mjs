// Shared FOO semantic fixtures run on the selected QBE backend.
import { existsSync as exists, mkdirSync as mkdir, readFileSync as read, writeFileSync as write } from 'node:fs';
import { availableParallelism as concurrency, totalmem } from 'node:os';
import { resolve, join, dirname } from 'node:path';
import { fileURLToPath as filename } from 'node:url';
import { spawn, spawnSync as invoke } from 'node:child_process';
import { createHash as hasher } from 'node:crypto';
import { audit } from './support/audit.mjs';
import { environment, temporary } from './location.mjs';
const root=resolve(dirname(filename(import.meta.url)),'..');
const option=name=>{const inline=process.argv.find(arg=>arg.startsWith(name+'='));if(inline!==undefined)return inline.slice(name.length+1);const i=process.argv.indexOf(name);return i<0?'':process.argv[i+1]??'';};
const backends=(option('--backends')||'qbe').split(',');
const modes=(option('--modes')||'dev').split(',');
if(backends.length!==1 || backends[0]!=='qbe') throw Error('Semantic tests run only on QBE');
if(modes.some(m=>!['dev','release'].includes(m)) || new Set(modes).size!==modes.length) throw Error('Invalid modes');
const filter=option('--filter');
const full=!filter && modes.length===2;
if(process.argv.includes('--gate')&&!full) throw Error('Coverage promotion requires all fixtures and both QBE modes');
if(process.argv.includes('--gate')&&process.env.FOO_TEST_DRIVER)throw Error('Acceptance forbids injected test drivers');
const launcher=process.env.FOO_TEST_DRIVER||join(root,'bin/foo.mjs');
if(process.argv.includes('--gate'))audit();
const bytes=read(join(root,'test/inventory.json'));
const initial=hasher('sha256').update(bytes).digest('hex');
const inventory=JSON.parse(bytes);
const fixtures=inventory.entries.filter(e=>e.path.startsWith('test/library/')&&e.path.endsWith('.iv')&&(e.fooTestsInSource>0||/^start\s*\{/m.test(read(join(root,e.path),'utf8')))).filter(e=>!filter||e.path.includes(filter));
if(!fixtures.length) throw Error('No semantic fixtures selected');
const memory=Math.max(1,Math.floor(totalmem()/(3*1024**3)));
const requested=Number(option('--jobs')||process.env.FOO_TEST_JOBS||2);
if(!Number.isInteger(requested)||requested<1) throw Error('Invalid worker count');
const jobs=Math.min(requested,4,memory,Math.max(1,concurrency()-1));
const timeout=Number(process.env.FOO_TEST_TIMEOUT||600000);
if(!Number.isFinite(timeout)||timeout<=0) throw Error('Invalid timeout');
const directory=resolve(option('--output')||temporary());
mkdir(directory,{recursive:true});
const rows=[];
function valid(t){return typeof t.name==='string'&&Number.isInteger(t.line)&&t.line>=0&&Number.isInteger(t.exitCode)&&typeof t.stdoutHex==='string'&&typeof t.stderrHex==='string'&&/^(?:[0-9a-f]{2})*$/i.test(t.stdoutHex)&&/^(?:[0-9a-f]{2})*$/i.test(t.stderrHex)&&typeof t.executed==='boolean'&&typeof t.passed==='boolean';}
function save(complete=false){
 const failures=rows.filter(r=>!r.passed);
 const executed=rows.reduce((n,r)=>n+r.executedTests,0);
 write(join(directory,'report.json'),JSON.stringify({format:'foo.test-matrix.v1',inventoryIdentity:initial,inventoryUnchanged:hasher('sha256').update(read(join(root,'test/inventory.json'))).digest('hex')===initial,fullSuite:full,complete,passed:complete&&hasher('sha256').update(read(join(root,'test/inventory.json'))).digest('hex')===initial&&failures.length===0&&rows.length===fixtures.length*backends.length*modes.length,fixtures:fixtures.length,expectedObservations:fixtures.length*backends.length*modes.length,observations:rows.length,executedTests:executed,failedObservations:failures.length,backends,modes,rows},null,2)+'\n');
}
function execute(file,backend,mode,id){
 const temp=join(directory,'temp',id);mkdir(temp,{recursive:true});
 return new Promise(done=>{
  const buffers={stdout:[],stderr:[]};let expired=false,failure='',size=0;
  const child=spawn(process.execPath,[launcher,'test',file,'--backend',backend,'--mode',mode,'--json'],{cwd:root,env:environment(temp,{...process.env,FOO_LIB:join(root,"lib"),FOO_OFFLINE:"1",FOOTESTID:id}),windowsHide:true,detached:process.platform!=='win32',stdio:['ignore','pipe','pipe']});
  function kill(){if(process.platform==='win32'){
    const stopped=invoke('taskkill',['/pid',String(child.pid),'/t','/f'],{windowsHide:true,stdio:'ignore',timeout:5000});
    if(stopped.status!==0)child.kill('SIGKILL');
  }else try{process.kill(-child.pid,'SIGKILL');}catch{}}
  const timer=setTimeout(()=>{expired=true;kill();},timeout);
  for(const stream of ['stdout','stderr'])child[stream].on('data',b=>{size+=b.length;if(size>32*1024*1024){failure='Output limit exceeded';kill();}else buffers[stream].push(b);});
  child.once('error',e=>{failure=e.message;});
  child.once('close',code=>{clearTimeout(timer);done({code,timedOut: expired,failure,stdout:Buffer.concat(buffers.stdout),stderr:Buffer.concat(buffers.stderr)});});
 });
}
save();let next=0;
async function worker(){while(next<fixtures.length){const fixture=fixtures[next++];
 for(const mode of modes)for(const backend of backends){
  const id=`${fixture.path.replaceAll('/','-')}-${backend}-${mode}`;
  const result=await execute(fixture.path,backend,mode,id);
  write(join(directory,id+'.stdout'),result.stdout);write(join(directory,id+'.stderr'),result.stderr);
  let events=[],error='';
  try{events=result.stdout.toString('utf8').split(/\r?\n/).filter(Boolean).map(line=>JSON.parse(line));}catch(e){error='Non-JSON test report: '+e.message;}
  const tests=events.filter(e=>e.event==='test-result');
  const expected=fixture.fooTestsInSource||1;
  const errors=[];
  if(result.code!==0||result.failure||result.timedOut)errors.push(result.failure||`Exit ${result.code}${result.timedOut?' (timeout)':''}`);
  if(error)errors.push(error);
  if(tests.length!==expected)errors.push(`Expected ${expected} cases, reported ${tests.length}`);
  if(tests.some(t=>!valid(t)))errors.push('Invalid execution observation: exact streams, exit code, case identity and execution status are required');
  if(hasher('sha256').update(read(join(root,fixture.path),'utf8').replaceAll('\r\n','\n')).digest('hex')!==fixture.sha256)errors.push('Fixture changed after inventory audit');
  if(tests.some(t=>!t.executed||!t.passed))errors.push('Cases failed or did not execute');
  rows.push({file:fixture.path,sourceHash:hasher('sha256').update(read(join(root,fixture.path))).digest('hex'),backend,mode,expectedTests:expected,executedTests:tests.filter(t=>valid(t)&&t.executed).length,reportedTests:tests.length,passed:errors.length===0,errors,tests,stdout:id+'.stdout',stderr:id+'.stderr'});
  save();console.log(`${errors.length?'FAIL':'PASS'} ${fixture.path}/${mode}/${backend}: ${tests.filter(t=>t.executed).length}/${expected} executed`);
 }
}}
await Promise.all(Array.from({length:jobs},worker));save(true);
const report=JSON.parse(read(join(directory,'report.json')));
console.log(`${report.executedTests} test executions; ${report.observations}/${report.expectedObservations} observations; ${report.failedObservations} failures. Report: ${directory}`);
if(!report.passed)process.exitCode=1;
