import assert from 'node:assert/strict';
import { writeFileSync as write, readFileSync as read, rmSync as remove } from 'node:fs';
import { join } from 'node:path';
import { spawnSync as invoke } from 'node:child_process';
import { temporary } from './location.mjs';
const root=temporary();
try{
 for(const [name,source] of [['empty','process.exit(0)'],['malformed','console.log("not JSON")'],['crash','process.exit(7)'],['timeout','setInterval(()=>{},1000)'],['missing-evidence','console.log(JSON.stringify({event:"test-result",executed:true,passed:true}))']]){
  const driver=join(root,name+'.mjs');write(driver,source);
  const output=join(root,name);
  const result=invoke(process.execPath,['test/matrix.mjs','--filter','crypto.iv','--backends','qbe','--modes','dev','--jobs','1','--output',output],{env:{...process.env,FOO_TEST_DRIVER:driver,FOO_TEST_TIMEOUT:'1000'},encoding:'utf8',windowsHide:true,timeout:30000});
  assert.notEqual(result.status,0,name+' must fail');
  const report=JSON.parse(read(join(output,'report.json')));
  assert.equal(report.complete,true,`${name}: ${result.error?.message || result.stderr || result.stdout}`);assert.equal(report.passed,false);
  assert.equal(report.executedTests,0);assert(report.failedObservations>0);
 }
 for (const backend of ['c','zig']) {
  const result=invoke(process.execPath,['test/matrix.mjs','--backends',backend],{encoding:'utf8',windowsHide:true,timeout:30000});
  assert.notEqual(result.status,0);assert.match(result.stderr,/Semantic tests run only on QBE/);
 }
 console.log('7 failure/crash/count/timeout/evidence/backend-policy cases executed: passed');
}finally{remove(root,{recursive:true,force:true});}
